# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'minitest/autorun'
require 'portals'

# Mirrors `sdk/python/tests/test_streams.py`: the credit window, the
# independent queued-frame cap, per-direction half-close, and cancellation.
class StreamTest < Minitest::Test
  WINDOW = 1024
  MAX_FRAMES = 4

  def setup
    @sent = []
    @stream = Portals::Stream.new(
      7,
      WINDOW,
      MAX_FRAMES,
      ->(bytes) { @sent << bytes },
      ->(envelope) { Portals::MsgpackCodec.encode(envelope, Portals::Protocol::DEFAULT_LIMITS) }
    )
  end

  def sent_frames
    @sent.map { |bytes| Portals::MsgpackCodec.decode(bytes, Portals::Protocol::DEFAULT_LIMITS)[0] }
  end

  def test_initial_grant_offers_the_whole_window_once
    assert_equal WINDOW, @stream.initial_grant
    assert_equal 0, @stream.initial_grant
  end

  def test_inbound_beyond_the_granted_window_is_rejected
    @stream.initial_grant
    @stream.record_inbound('a', 512)

    assert_raises(Portals::StreamProtocolError) { @stream.record_inbound('b', 600) }
  end

  def test_tiny_frame_flood_hits_the_frame_limit_while_bytes_remain
    @stream.initial_grant
    MAX_FRAMES.times { |i| @stream.record_inbound(i.to_s, 8) }

    assert_raises(Portals::StreamProtocolError) { @stream.record_inbound('one too many', 8) }
  end

  def test_consuming_replenishes_exactly_what_was_consumed
    @stream.initial_grant
    @stream.record_inbound('chunk', 100)

    assert_equal 'chunk', @stream.recv
    credit = sent_frames.last
    assert_equal Portals::Protocol::CREDIT, credit[0]
    assert_equal 100, credit[2]
    assert_equal 1, credit[3]
  end

  def test_recv_returns_nil_after_the_peer_half_closes
    @stream.peer_half_closed
    assert_nil @stream.recv
  end

  def test_inbound_after_half_close_is_a_protocol_error
    @stream.initial_grant
    @stream.peer_half_closed

    assert_raises(Portals::StreamProtocolError) { @stream.record_inbound('late', 8) }
  end

  def test_send_blocks_until_credit_arrives
    thread = Thread.new { @stream.send('payload') }
    sleep 0.05
    assert_equal 0, @sent.length

    @stream.add_send_credit(WINDOW, 0)
    thread.join(2)

    assert_equal 1, @sent.length
    assert_equal [Portals::Protocol::STREAM_DATA, 7, 'payload'], sent_frames.first
  end

  def test_send_is_charged_the_full_frame_size
    payload = Portals::MsgpackCodec.encode(
      [Portals::Protocol::STREAM_DATA, 7, 'payload'],
      Portals::Protocol::DEFAULT_LIMITS
    )
    frame_size = payload.bytesize + Portals::FRAME_PREFIX_BYTES

    @stream.add_send_credit(frame_size, 0)
    @stream.send('payload')

    # Exactly one frame's worth of credit was granted, so the next send
    # parks until more arrives.
    thread = Thread.new do
      @stream.send('payload')
    rescue Portals::StreamClosed
      :unblocked
    end
    sleep 0.05
    assert_equal 1, @sent.length
    @stream.cancel
    assert_equal :unblocked, thread.join(2).value
  end

  def test_send_respects_the_unacknowledged_frame_limit
    @stream.add_send_credit(WINDOW, 0)
    MAX_FRAMES.times { @stream.send('x') }
    assert_equal MAX_FRAMES, @sent.length

    thread = Thread.new { @stream.send('x') }
    sleep 0.05
    assert_equal MAX_FRAMES, @sent.length

    @stream.add_send_credit(0, MAX_FRAMES)
    thread.join(2)
    assert_equal MAX_FRAMES + 1, @sent.length
  end

  def test_a_chunk_larger_than_the_window_can_never_be_sent
    @stream.add_send_credit(WINDOW, 0)
    assert_raises(Portals::StreamProtocolError) { @stream.send('x' * (WINDOW * 2)) }
  end

  def test_half_close_is_per_direction_and_idempotent
    @stream.initial_grant
    @stream.half_close
    @stream.half_close

    assert_equal 1, sent_frames.count { |frame| frame[0] == Portals::Protocol::HALF_CLOSE }
    assert_raises(Portals::StreamClosed) { @stream.send('late') }

    # The receiving direction is untouched.
    @stream.record_inbound('still-arriving', 32)
    assert_equal 'still-arriving', @stream.recv
  end

  def test_cancel_releases_state_and_unblocks_a_parked_sender
    @stream.initial_grant
    @stream.record_inbound('queued', 32)

    error = nil
    thread = Thread.new do
      @stream.send('parked')
    rescue Portals::StreamClosed => e
      error = e
    end

    sleep 0.05
    @stream.cancel
    thread.join(2)

    assert_instance_of Portals::StreamClosed, error
    assert @stream.cancelled?
    assert_nil @stream.recv
  end

  def test_stream_handler_marks_and_returns_the_method_name
    mod = Module.new do
      extend Portals::StreamHandlers
      stream_handler def marked(stream) = stream
      def unmarked = nil
    end

    assert mod.portals_stream_handler?('marked')
    refute mod.portals_stream_handler?('unmarked')
  end
end
