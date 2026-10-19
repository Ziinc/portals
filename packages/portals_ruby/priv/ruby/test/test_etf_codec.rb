# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path('../lib', __dir__))

require 'minitest/autorun'
require 'portals'

# Mirrors `packages/portals_python/priv/python/tests/test_etf_codec.py` so the two ETF codecs are
# held to the same contract.
class EtfCodecTest < Minitest::Test
  include Portals

  L = Portals::Protocol::DEFAULT_LIMITS

  # :erlang.term_to_binary/1 of
  #   [3, 7, "héllo", %{"k" => [1, -2, 300, 2_147_483_648, -(2**70)]},
  #    {:ok, nil, true, false}, 1.5, [], ~c"ab", [1 | 2],
  #    %Portals.Codec.Bin{data: <<0, 255>>}]
  BEAM_BYTES = [
    '836c0000000a610361076d0000000668c3a96c6c6f74000000016d000000016b6c00000005610162fffffffe' \
    '620000012c6e0400000000806e09010000000000000000406a68046400026f6b6400036e696c640004747275' \
    '6564000566616c7365463ff80000000000006a6b000261626c0000000161016102740000000264000a5f5f73' \
    '74727563745f5f640018456c697869722e506f7274616c732e436f6465632e42696e640004646174616d0000' \
    '000200ff6a'
  ].pack('H*').freeze

  BEAM_TERM = [
    3,
    7,
    'héllo',
    { 'k' => [1, -2, 300, 2_147_483_648, -(2**70)] },
    Tuple[:ok, nil, true, false],
    1.5,
    [],
    [97, 98],
    ImproperList.new([1], 2),
    "\x00\xFF".b
  ].freeze

  def hex(text) = [text].pack('H*')

  def round_trip(envelope)
    decoded, rest = EtfCodec.decode(EtfCodec.encode(envelope, L), L)
    assert_equal '', rest
    decoded
  end

  def reason_for(bytes, limits = L)
    error = assert_raises(EtfCodec::DecodeError) { EtfCodec.decode(bytes, limits) }
    error.reason[0]
  end

  def test_decodes_what_the_beam_encodes
    term, rest = EtfCodec.decode(BEAM_BYTES, L)
    assert_equal BEAM_TERM, term
    assert_equal Encoding::UTF_8, term[2].encoding
    assert_equal Encoding::BINARY, term[9].encoding
    assert_equal '', rest
  end

  def test_round_trips_every_value_type
    envelope = [
      4,
      1,
      {
        'none' => nil,
        'bools' => [true, false],
        'ints' => [0, 255, 256, -1, 2**31, -(2**31) - 1, 2**64, -(2**2100)],
        'float' => -0.25,
        'text' => 'naïve ✓',
        'bytes' => "\x00\x01\xFE".b,
        'empty' => ''.b,
        'atom' => :ok,
        'tuple' => Tuple[1, 'two', Tuple[3]],
        'improper' => ImproperList.new([1, 2], 'tail'),
        'nested' => { 'a' => [{ 'b' => [] }] }
      }
    ]
    decoded = round_trip(envelope)
    assert_equal envelope, decoded
    assert_equal Encoding::UTF_8, decoded[2]['text'].encoding
    assert_equal Encoding::BINARY, decoded[2]['bytes'].encoding
  end

  def test_explicit_bin_and_float64_wrappers
    assert_equal ["texté".b, 2.0], round_trip([Bin.new("texté"), Float64.new(2)])
  end

  def test_large_tuples_atoms_and_binaries
    tuple = Tuple.new((1..300).to_a)
    atom = ('a' * 300).to_sym
    blob = ("\x00" * 70_000).b
    assert_equal [tuple, atom, blob], round_trip([tuple, atom, blob])
  end

  def test_integer_encodings_follow_the_spec
    assert_equal hex('83610a'), EtfCodec.encode(10, L)
    assert_equal hex('8362ffffffff'), EtfCodec.encode(-1, L)
    assert_equal hex('836200000100'), EtfCodec.encode(256, L)
    # :erlang.term_to_binary(-(2**39))
    assert_equal hex('836e05010000000080'), EtfCodec.encode(-(2**39), L)
  end

  def test_pids_and_references_are_opaque_and_written_back_verbatim
    # self() and make_ref() from a BEAM, as NEW_PID_EXT / NEWER_REFERENCE_EXT.
    pid = hex('5864000d6e6f6e6f6465406e6f686f73740000005e0000000000000000')
    ref = hex('5a000364000d6e6f6e6f6465406e6f686f73740000000000008033634c0004263763cf')
    data = [131, 108, 0, 0, 0, 2].pack('C*') + pid + ref + [106].pack('C')
    term, = EtfCodec.decode(data, L)
    assert_equal [Pid.new(pid), Reference.new(ref)], term
    assert_equal data, EtfCodec.encode(term, L)
  end

  def test_a_data_key_outside_a_bin_struct_stays_text
    term, = EtfCodec.decode(EtfCodec.encode([{ data: 'x', other: 1 }], L), L)
    assert_equal [{ 'data' => 'x', 'other' => 1 }], term
    assert_equal Encoding::UTF_8, term[0]['data'].encoding

    # %{data: "x", other: 1} with real atom keys, as a BEAM sends it.
    beam = hex('837400000002640004646174616d00000001786400056f746865726101')
    term, = EtfCodec.decode(beam, L)
    assert_equal [{ 'data' => 'x', 'other' => 1 }], term
  end

  def test_the_bin_struct_is_recognised_with_keys_in_either_order
    bin = hex('7400000002640004646174616d000000020102' \
              '64000a5f5f7374727563745f5f640018456c697869722e506f7274616c732e436f6465632e42696e')
    term, = EtfCodec.decode([131].pack('C') + bin, L)
    assert_equal ["\x01\x02".b], term
  end

  def test_map_keys_become_text_as_under_messagepack
    # %{a: 1, 2 => 3, "s" => 4, nil => 5} from a BEAM.
    term, = EtfCodec.decode(hex('837400000004610261036400016161016400036e696c61056d00000001736104'), L)
    assert_equal [{ '2' => 3, 'a' => 1, 's' => 4, '' => 5 }], term

    term, = EtfCodec.decode(EtfCodec.encode([{ 1 => 'x', k: 'y' }], L), L)
    assert_equal [{ '1' => 'x', 'k' => 'y' }], term
  end

  def test_other_map_keys_are_invalid_encoding
    # %{{1} => 1} from a BEAM.
    assert_equal :invalid_encoding, reason_for(hex('837400000001680161016101'))
  end

  def test_latin1_and_long_atoms_decode_as_symbols
    # :erlang.term_to_binary(:"café") is a Latin-1 ATOM_EXT.
    assert_equal [:café], EtfCodec.decode(hex('83640004636166e9'), L)[0]
    # SMALL_ATOM_EXT "ok"
    assert_equal [:ok], EtfCodec.decode(hex('8373026f6b'), L)[0]
  end

  def test_string_ext_is_a_list_of_bytes
    term, = EtfCodec.decode(hex('836b00026162'), L)
    assert_equal [97, 98], term
  end

  def test_trailing_bytes_are_returned
    term, rest = EtfCodec.decode(hex('8361010000'), L)
    assert_equal [1], term
    assert_equal "\x00\x00".b, rest
  end

  def test_malformed_input_raises_decode_error
    [
      [''.b, :truncated],
      ["\x00".b, :invalid_encoding],
      [BEAM_BYTES.byteslice(0, BEAM_BYTES.bytesize - 3), :truncated],
      [hex('834d'), :invalid_encoding],
      [hex('836d00000001ff'), :invalid_encoding],
      [hex('836c000000036101'), :truncated],
      [hex('836d0000000a73686f7274'), :truncated],
      [hex('83c8'), :invalid_encoding],
      [hex('836cffffffff'), :max_length_exceeded],
      [hex('8358'), :truncated],
      [hex('83586100'), :invalid_encoding],
      [hex('836e0400'), :truncated],
      [hex('8377026f'), :truncated],
      [hex('837701ff'), :invalid_encoding],
      [hex('83760002c328'), :invalid_encoding]
    ].each do |bytes, reason|
      assert_equal reason, reason_for(bytes), "for #{bytes.unpack1('H*')}"
    end
  end

  def test_nesting_too_deep_is_rejected
    bytes = "\x83".b + ("\x6c\x00\x00\x00\x01".b * 40) + "\x61\x01".b + ("\x6a".b * 40)
    assert_equal :max_depth_exceeded, reason_for(bytes)
  end

  def test_enforces_limits
    limits = { 'max_frame_size' => 1024, 'max_nesting_depth' => 2, 'max_collection_length' => 3 }
    { [[[[1]]]] => :max_depth_exceeded,
      [[1, 2, 3, 4]] => :max_length_exceeded,
      [Tuple[1, 2, 3, 4]] => :max_length_exceeded,
      [{ 'a' => 1, 'b' => 2, 'c' => 3, 'd' => 4 }] => :max_length_exceeded,
      ['x' * 2000] => :max_size_exceeded }.each do |term, reason|
      error = assert_raises(EtfCodec::DecodeError) { EtfCodec.encode(term, limits) }
      assert_equal reason, error.reason[0]
    end

    assert_equal :max_size_exceeded, reason_for("\x83".b + ('x' * 2000), limits)
    assert_equal :max_length_exceeded, reason_for(EtfCodec.encode([[1, 2, 3, 4]], L), limits)
  end

  def test_unsupported_types_are_invalid_encoding
    error = assert_raises(EtfCodec::DecodeError) { EtfCodec.encode([Object.new], L) }
    assert_equal :invalid_encoding, error.reason[0]
  end
end

# The `PORTALS_CODEC` selection (protocol/v1.md §5.4).
class CodecSelectionTest < Minitest::Test
  def test_selects_by_name_and_refuses_anything_else
    assert_equal Portals::EtfCodec, Portals::Codec.for_name('etf')
    assert_equal Portals::MsgpackCodec, Portals::Codec.for_name('msgpack')
    error = assert_raises(ArgumentError) { Portals::Codec.for_name('json') }
    assert_match(/PORTALS_CODEC="json"/, error.message)
  end

  def test_defaults_to_etf
    expected = ENV.fetch('PORTALS_CODEC', 'etf')
    assert_equal expected, Portals::Codec::NAME
    assert_equal Portals::Codec.for_name(expected), Portals::Codec::IMPL
    assert_equal Portals::Codec::IMPL::DecodeError, Portals::Codec::DecodeError
  end

  def test_an_unknown_codec_fails_at_startup
    lib = File.expand_path('../lib', __dir__)
    out = IO.popen({ 'PORTALS_CODEC' => 'bogus' }, [RbConfig.ruby, '-I', lib, '-e', "require 'portals'"],
                   err: %i[child out], &:read)
    refute $?.success?
    assert_match(/not a codec this SDK speaks/, out)
  end
end
