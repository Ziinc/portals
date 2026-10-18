# frozen_string_literal: true

require_relative 'protocol'

# Bidirectional streaming for the Ruby worker SDK (protocol/v1.md §9).
#
# A stream is opened by the BEAM as an ordinary `CALL` whose target method
# was declared with `stream_handler :name`; the call's `request_id` doubles
# as the `stream_id`. The handler receives a `Stream` as its first argument
# and runs on a dedicated stream thread pool, kept separate from the unary
# call pool so long-lived streams can never exhaust the concurrency this
# worker advertised for unary calls.
#
# Backpressure is an encoded-byte credit window, independent per direction,
# charged against the complete encoded frame size (4-byte length prefix
# included), plus a hard cap on queued-but-unconsumed frames so a flood of
# tiny frames cannot evade the byte window.
module Portals
  FRAME_PREFIX_BYTES = 4

  # Raised when sending on a cancelled/terminated stream, or on a direction
  # this side already half-closed.
  class StreamClosed < StandardError; end

  # The peer exceeded its documented byte or frame allowance.
  class StreamProtocolError < StandardError; end

  class StreamTimeout < StandardError; end

  # One open bidirectional stream. Thread-safe.
  class Stream
    attr_reader :id

    def initialize(stream_id, max_credit, max_frames, send_frame, encode)
      @id = stream_id
      @max_credit = max_credit
      @max_frames = max_frames
      @send_frame = send_frame
      @encode = encode

      @mutex = Mutex.new
      @cond = ConditionVariable.new
      @send_credit = 0
      @send_frames = 0
      @recv_credit = 0
      @recv_bytes = 0
      @inbox = []
      @outbound_open = true
      @inbound_open = true
      @cancelled = false
    end

    # -- receive side ---------------------------------------------------

    # Bytes to grant the BEAM up front; also the replenishment amount after
    # consumption. Returns 0 when nothing is owed.
    def initial_grant
      @mutex.synchronize { grant_locked }
    end

    # Account for one inbound STREAM_DATA frame. Raises
    # `StreamProtocolError` when the peer exceeded its allowance.
    def record_inbound(chunk, frame_size)
      @mutex.synchronize do
        raise StreamProtocolError, 'STREAM_DATA after HALF_CLOSE' unless @inbound_open
        raise StreamProtocolError, 'queued stream frame limit exceeded' if @inbox.length >= @max_frames
        raise StreamProtocolError, 'stream byte credit exceeded' if frame_size > @recv_credit

        @recv_credit -= frame_size
        @recv_bytes += frame_size
        @inbox.push([chunk, frame_size])
        @cond.broadcast
      end
    end

    # Next inbound chunk, or `nil` once the BEAM has half-closed its sending
    # direction (or the stream was cancelled). Consuming a chunk is what
    # replenishes the BEAM's credit.
    def recv(timeout = nil)
      grant = 0
      chunk = nil

      @mutex.synchronize do
        while @inbox.empty?
          return nil if @cancelled || !@inbound_open

          deadline_wait(timeout) { "stream #{@id} receive timed out" }
        end

        chunk, frame_size = @inbox.shift
        @recv_bytes -= frame_size
        grant = grant_locked
      end

      credit(grant, 1) if grant.positive?
      chunk
    end

    def each
      return enum_for(:each) unless block_given?

      while (chunk = recv)
        yield chunk
      end
    end

    include Enumerable

    # -- send side ------------------------------------------------------

    # Send one chunk, blocking this handler's own thread (never the socket
    # reader) until the BEAM has granted enough credit.
    def send(chunk, timeout: nil)
      payload = @encode.call([Protocol::STREAM_DATA, @id, chunk])
      frame_size = payload.bytesize + FRAME_PREFIX_BYTES

      if frame_size > @max_credit
        raise StreamProtocolError,
              "chunk of #{frame_size} bytes exceeds the stream window of #{@max_credit}"
      end

      @mutex.synchronize do
        loop do
          raise StreamClosed, "stream #{@id} was cancelled" if @cancelled
          raise StreamClosed, "stream #{@id} outbound direction is half-closed" unless @outbound_open

          if @send_frames < @max_frames && frame_size <= @send_credit
            @send_credit -= frame_size
            @send_frames += 1
            break
          end

          deadline_wait(timeout) { "stream #{@id} send timed out waiting for credit" }
        end
      end

      @send_frame.call(payload)
    end

    def send_all(chunks, timeout: nil, half_close: true)
      chunks.each { |chunk| send(chunk, timeout: timeout) }
      self.half_close if half_close
    end

    # Close only this side's sending direction. Idempotent.
    def half_close
      should_send = @mutex.synchronize do
        next false if !@outbound_open || @cancelled

        @outbound_open = false
        @cond.broadcast
        true
      end

      @send_frame.call(@encode.call([Protocol::HALF_CLOSE, @id])) if should_send
      nil
    end

    # -- peer events ----------------------------------------------------

    def add_send_credit(bytes, frames)
      @mutex.synchronize do
        @send_credit = [@send_credit + bytes, @max_credit].min
        @send_frames = [@send_frames - frames, 0].max
        @cond.broadcast
      end
    end

    def peer_half_closed
      @mutex.synchronize do
        @inbound_open = false
        @cond.broadcast
      end
    end

    # Release every piece of local state and unblock the handler.
    def cancel
      @mutex.synchronize do
        @cancelled = true
        @outbound_open = false
        @inbound_open = false
        @inbox.clear
        @cond.broadcast
      end
    end

    def cancelled?
      @mutex.synchronize { @cancelled }
    end

    private

    def grant_locked
      bytes = @max_credit - @recv_credit - @recv_bytes
      return 0 unless bytes.positive?

      @recv_credit += bytes
      bytes
    end

    # Wait on the condition variable, raising `StreamTimeout` when a finite
    # timeout elapses without progress.
    def deadline_wait(timeout)
      if timeout.nil?
        @cond.wait(@mutex)
      else
        started = monotonic
        @cond.wait(@mutex, timeout)
        raise StreamTimeout, yield if monotonic - started >= timeout
      end
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def credit(bytes, frames)
      @send_frame.call(@encode.call([Protocol::CREDIT, @id, bytes, frames]))
    end
  end
end
