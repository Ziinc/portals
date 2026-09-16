# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'minitest/autorun'
require 'portals'

# Mirrors `sdk/python/tests/test_msgpack_codec.py` so the two codecs are
# held to the same contract.
class MessagePackCodecTest < Minitest::Test
  include Portals

  L = Portals::Protocol::DEFAULT_LIMITS

  def round_trip(envelope)
    encoded = MsgpackCodec.encode(envelope, L)
    decoded, rest = MsgpackCodec.decode(encoded, L)
    assert_equal '', rest
    decoded
  end

  def test_primitives
    assert_equal [nil, true, false], round_trip([nil, true, false])
  end

  def test_ints_including_bigints
    values = [0, 1, 127, 128, 255, 256, 65_535, 65_536, -1, -32, -33, -128, -129, -32_768, -32_769]
    assert_equal values, round_trip(values)

    huge = 170_141_183_460_469_231_731_687_303_715_884_105_728
    assert_equal [huge, -huge], round_trip([huge, -huge])
  end

  def test_float
    assert_equal [1.5], round_trip([1.5])
  end

  def test_str_and_bytes_are_distinct
    decoded = round_trip(['hello', "\x00\x01\x02".b])
    assert_equal 'hello', decoded[0]
    assert_equal Encoding::UTF_8, decoded[0].encoding
    assert_equal "\x00\x01\x02".b, decoded[1]
    assert_equal Encoding::BINARY, decoded[1].encoding
  end

  def test_tuple
    assert_equal [Tuple.new([1, 'a', nil])], round_trip([Tuple.new([1, 'a', nil])])
  end

  def test_atom_round_trips_as_a_symbol
    assert_equal [:ok], round_trip([:ok])
  end

  def test_pid_and_reference_are_opaque_round_trip
    pid = Pid.new("\x83pid_bytes")
    ref = Reference.new("\x83ref_bytes")
    assert_equal [pid, ref], round_trip([pid, ref])
  end

  def test_improper_list
    value = ImproperList.new([1, 2], :tail)
    assert_equal [value], round_trip([value])
  end

  def test_nested_map
    term = { 'a' => 1, 'b' => [1, 2, 3], 'c' => { 'nested' => true } }
    assert_equal [term], round_trip([term])
  end

  def test_call_and_hello_envelope_shapes
    hello = [Protocol::HELLO, 1, 'ruby3.3', 16, 0, []]
    assert_equal hello, round_trip(hello)

    call = [Protocol::CALL, 1, 'bench_worker', 'echo', ['hello']]
    assert_equal call, round_trip(call)
  end

  def test_max_frame_size_enforced
    tight = L.merge('max_frame_size' => 4)
    assert_raises(MsgpackCodec::DecodeError) { MsgpackCodec.encode(['much too long a string'], tight) }
  end

  def test_truncated_frame_raises_decode_error
    error = assert_raises(MsgpackCodec::DecodeError) { MsgpackCodec.decode("\x91", L) }
    assert_equal :truncated, error.reason[0]
  end

  def test_unknown_leading_byte_is_invalid_encoding
    error = assert_raises(MsgpackCodec::DecodeError) { MsgpackCodec.decode("\xC1".b, L) }
    assert_equal :invalid_encoding, error.reason[0]
  end

  def test_oversized_collection_is_rejected
    error = assert_raises(MsgpackCodec::DecodeError) do
      MsgpackCodec.decode("\xDD\xFF\xFF\xFF\xFF".b, L)
    end
    assert_equal :max_length_exceeded, error.reason[0]
  end

  def test_large_binary_round_trips
    blob = ("\x00" * 70_000).b
    decoded = round_trip([Protocol::RETURN, 1, blob])
    assert_equal blob, decoded[2]
  end

  def test_return_envelope_round_trip
    envelope = [Protocol::RETURN, 42, { 'ok' => true }]
    assert_equal envelope, round_trip(envelope)
  end
end
