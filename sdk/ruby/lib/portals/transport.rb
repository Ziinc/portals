# frozen_string_literal: true

require 'socket'

# Length-framed transport for the Ruby worker side.
#
# Matches the BEAM's `{:packet, 4}` framing exactly: a 4-byte big-endian
# length prefix followed by that many bytes of MessagePack-encoded envelope.
# `FramedSocket` hides that framing so callers only ever see whole
# envelopes. `FramedStdio` is the fallback for platforms without Unix-socket
# support.
module Portals
  class ConnectionClosed < StandardError; end

  # Shared framing logic over any IO-ish object.
  module Framing
    def send_frame(payload)
      payload = payload.b
      @send_mutex.synchronize do
        write_all([payload.bytesize].pack('N') + payload)
      end
    end

    def recv_frame
      header = read_exact(4)
      return nil if header.nil?

      length = header.unpack1('N')
      payload = read_exact(length)
      raise ConnectionClosed, 'connection closed mid-frame' if payload.nil?

      payload
    end

    private

    def read_exact(count)
      buffer = +''.b
      while buffer.bytesize < count
        chunk = read_some(count - buffer.bytesize)
        if chunk.nil? || chunk.empty?
          raise ConnectionClosed, 'connection closed mid-frame' unless buffer.empty?

          return nil
        end
        buffer << chunk.b
      end
      buffer
    end
  end

  class FramedSocket
    include Framing

    def self.connect_unix(path)
      new(UNIXSocket.new(path))
    end

    def initialize(socket)
      @socket = socket
      @send_mutex = Mutex.new
    end

    def close
      @socket.close
    rescue IOError, SystemCallError
      nil
    end

    private

    def write_all(bytes) = @socket.write(bytes)

    def read_some(count)
      @socket.readpartial(count)
    rescue EOFError
      nil
    end
  end

  # Experimental fallback transport: identical framing carried over
  # stdin/stdout.
  class FramedStdio
    include Framing

    def initialize(input = $stdin, output = $stdout)
      @input = input
      @output = output
      @input.binmode
      @output.binmode
      @send_mutex = Mutex.new
    end

    def close = nil

    private

    def write_all(bytes)
      @output.write(bytes)
      @output.flush
    end

    def read_some(count) = @input.read(count)
  end

  module_function

  # `Portals.Connection` appends the socket path as the final CLI argument.
  def socket_path_from_argv
    raise 'portals worker: expected the socket path as the last argument' if ARGV.empty?

    ARGV.last
  end
end
