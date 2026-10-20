# frozen_string_literal: true

require_relative 'protocol'
require_relative 'values'

# Pure-Ruby Erlang External Term Format codec (protocol/v1.md §5.4), the
# Ruby side of `Portals.Codec.ETF` and the default wire codec (see
# `Portals::Codec`). Dependency-free, like `msgpack_codec.rb`, and with the
# same API: `encode(envelope, limits)` / `decode(data, limits)` raising
# `DecodeError` with the same reasons.
#
# Values map to the same Ruby types as under MessagePack:
#
# * binaries are UTF-8 Strings, and `%Portals.Codec.Bin{}` structs are
#   BINARY (ASCII-8BIT) Strings (which, like `Bin`, encode as that struct);
# * the atoms `nil`, `true` and `false` are `nil`, `true` and `false`, and
#   other atoms are Symbols;
# * tuples are `Tuple`, improper lists are `ImproperList`, and maps are
#   Hashes with String keys (atom and integer keys become their text, as
#   the MessagePack encoders' `to_string` does, so `nil` becomes `""`);
# * PIDs and references are opaque `Pid` / `Reference` wrapping their ETF
#   bytes (tag included, no version byte), which are written back verbatim.
module Portals
  module EtfCodec
    VERSION = 131

    NEW_FLOAT = 70
    BIT_BINARY = 77
    NEW_PID = 88
    NEWER_REFERENCE = 90
    SMALL_INTEGER = 97
    INTEGER = 98
    ATOM = 100
    PID = 103
    SMALL_TUPLE = 104
    LARGE_TUPLE = 105
    NIL = 106
    STRING = 107
    LIST = 108
    BINARY = 109
    SMALL_BIG = 110
    LARGE_BIG = 111
    NEW_REFERENCE = 114
    SMALL_ATOM = 115
    MAP = 116
    ATOM_UTF8 = 118
    SMALL_ATOM_UTF8 = 119

    ATOM_TAGS = [SMALL_ATOM_UTF8, SMALL_ATOM, ATOM_UTF8, ATOM].freeze
    SPECIAL_ATOMS = { 'nil' => nil, 'true' => true, 'false' => false }.freeze
    BIN_STRUCT = :'Elixir.Portals.Codec.Bin'
    STRUCT_KEY = :__struct__
    DATA_KEY = :data
    INT32_RANGE = (-2_147_483_648..2_147_483_647)

    # How byte buffers are encoded: `%Portals.Codec.Bin{data: ...}`, up to
    # the data binary itself.
    BIN_PREFIX = [MAP, 2,
                  SMALL_ATOM_UTF8, 10, '__struct__',
                  SMALL_ATOM_UTF8, 24, 'Elixir.Portals.Codec.Bin',
                  SMALL_ATOM_UTF8, 4, 'data'].pack('CNCCa*CCa*CCa*').freeze

    # Raised for every codec-level failure, on encode and decode alike:
    # never a generic exception, and never anything that escapes past the
    # offending connection.
    class DecodeError < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super(reason.inspect)
      end
    end

    # A `data` binary kept as raw bytes until its map is known to be (or not
    # to be) a `%Portals.Codec.Bin{}` struct.
    RawBinary = Struct.new(:bytes)
    private_constant :RawBinary

    module_function

    # Encode a frame envelope (an Array) to bytes.
    def encode(envelope, limits = Protocol::DEFAULT_LIMITS)
      out = String.new(VERSION.chr, capacity: 256, encoding: Encoding::BINARY)
      encode_term(envelope, out, 0, limits)
      raise DecodeError, [:max_size_exceeded, out.bytesize] if out.bytesize > limits['max_frame_size']

      out
    end

    # Decode bytes to `[envelope, rest]`.
    def decode(data, limits = Protocol::DEFAULT_LIMITS)
      data = data.b
      raise DecodeError, [:max_size_exceeded, data.bytesize] if data.bytesize > limits['max_frame_size']
      raise DecodeError, [:truncated, 0] if data.empty?
      raise DecodeError, [:invalid_encoding, data.getbyte(0)] unless data.getbyte(0) == VERSION

      term, pos = decode_term(data, 1, 0, limits)
      term = [term] unless term.is_a?(Array)
      [term, data.byteslice(pos, data.bytesize - pos)]
    end

    # -- Encoding ---------------------------------------------------------

    def check_depth(depth, limits)
      raise DecodeError, [:max_depth_exceeded, depth] if depth > limits['max_nesting_depth']
    end

    def check_length(count, limits)
      raise DecodeError, [:max_length_exceeded, count] if count > limits['max_collection_length']
    end

    # Appends `term` to the growable BINARY buffer `out`.
    def encode_term(term, out, depth, limits)
      check_depth(depth, limits)

      case term
      when nil then encode_atom('nil', out)
      when false then encode_atom('false', out)
      when true then encode_atom('true', out)
      when Symbol then encode_atom(term.to_s, out)
      when Pid, Reference then out << term.raw
      when Bin then encode_bin(term.data, out)
      when Float64 then [NEW_FLOAT, term.value].pack('CG', buffer: out)
      when Integer then encode_int(term, out)
      when Float then [NEW_FLOAT, term].pack('CG', buffer: out)
      when String then encode_string_or_bin(term, out)
      when Tuple then encode_tuple(term.items, out, depth, limits)
      when ImproperList
        check_length(term.items.length, limits)
        [LIST, term.items.length].pack('CN', buffer: out)
        term.items.each { |item| encode_term(item, out, depth + 1, limits) }
        encode_term(term.tail, out, depth + 1, limits)
      when Hash then encode_map(term, out, depth, limits)
      when Array
        check_length(term.length, limits)
        unless term.empty?
          [LIST, term.length].pack('CN', buffer: out)
          term.each { |item| encode_term(item, out, depth + 1, limits) }
        end
        out << NIL
      else
        raise DecodeError, [:invalid_encoding, "unsupported type #{term.class}"]
      end
    end

    def encode_atom(name, out)
      n = name.bytesize
      if n < 256
        [SMALL_ATOM_UTF8, n, name].pack('CCa*', buffer: out)
      else
        [ATOM_UTF8, n, name].pack('Cna*', buffer: out)
      end
    end

    # Text-encoded Strings become `BINARY_EXT`; BINARY (ASCII-8BIT) Strings
    # become the `%Portals.Codec.Bin{}` struct, as they become MessagePack
    # `bin` (protocol/v1.md §5.2).
    def encode_string_or_bin(string, out)
      if string.encoding == Encoding::BINARY
        encode_bin(string, out)
      else
        encode_text(string, out)
      end
    end

    # `a*` packs the String's bytes whatever its encoding.
    def encode_text(string, out)
      [BINARY, string.bytesize, string].pack('CNa*', buffer: out)
    end

    def encode_bin(bytes, out)
      out << BIN_PREFIX
      encode_text(bytes, out)
    end

    def encode_tuple(items, out, depth, limits)
      check_length(items.length, limits)
      if items.length < 256
        [SMALL_TUPLE, items.length].pack('CC', buffer: out)
      else
        [LARGE_TUPLE, items.length].pack('CN', buffer: out)
      end
      items.each { |item| encode_term(item, out, depth + 1, limits) }
    end

    # Keys are sent as text, exactly as `MsgpackCodec` stringifies them.
    def encode_map(map, out, depth, limits)
      check_length(map.size, limits)
      [MAP, map.size].pack('CN', buffer: out)
      map.each do |key, value|
        encode_text(key.to_s, out)
        encode_term(value, out, depth + 1, limits)
      end
    end

    def encode_int(n, out)
      if n >= 0 && n < 256
        [SMALL_INTEGER, n].pack('CC', buffer: out)
      elsif INT32_RANGE.cover?(n)
        [INTEGER, n].pack('Cl>', buffer: out)
      else
        hex = n.abs.to_s(16)
        hex = "0#{hex}" if hex.length.odd?
        digits = [hex].pack('H*').reverse
        if digits.bytesize < 256
          [SMALL_BIG, digits.bytesize].pack('CC', buffer: out)
        else
          [LARGE_BIG, digits.bytesize].pack('CN', buffer: out)
        end
        out << (n.negative? ? 1 : 0) << digits
      end
    end

    # -- Decoding ---------------------------------------------------------

    # Returns `[term, next_position]`. Position-based rather than
    # slice-based so large payloads decode in linear time.
    def decode_term(data, pos, depth, limits)
      check_depth(depth, limits)
      need(data, pos, 1)
      tag = data.getbyte(pos)

      case tag
      when SMALL_INTEGER then need(data, pos, 2) and [data.getbyte(pos + 1), pos + 2]
      when INTEGER then [unpack(data, pos + 1, 4, 'l>'), pos + 5]
      when NEW_FLOAT then [unpack(data, pos + 1, 8, 'G'), pos + 9]
      when *ATOM_TAGS
        name, pos = decode_atom(data, pos)
        SPECIAL_ATOMS.key?(name) ? [SPECIAL_ATOMS[name], pos] : [name.to_sym, pos]
      when BINARY
        text, pos = decode_binary(data, pos)
        [utf8(text), pos]
      when NIL then [[], pos + 1]
      when LIST then decode_list(data, pos, depth, limits)
      when STRING
        n = unpack(data, pos + 1, 2, 'n')
        need(data, pos + 3, n)
        [data.unpack("C#{n}", offset: pos + 3), pos + 3 + n]
      when SMALL_TUPLE
        need(data, pos, 2)
        decode_tuple(data.getbyte(pos + 1), data, pos + 2, depth, limits)
      when LARGE_TUPLE then decode_tuple(unpack(data, pos + 1, 4, 'N'), data, pos + 5, depth, limits)
      when MAP then decode_map(data, pos, depth, limits)
      when SMALL_BIG
        need(data, pos, 2)
        decode_big(data.getbyte(pos + 1), data, pos + 2)
      when LARGE_BIG then decode_big(unpack(data, pos + 1, 4, 'N'), data, pos + 5)
      when NEW_PID, PID
        stop = skip_atom(data, pos + 1) + (tag == NEW_PID ? 12 : 9)
        need(data, pos, stop - pos)
        [Pid.new(data.byteslice(pos, stop - pos)), stop]
      when NEWER_REFERENCE, NEW_REFERENCE
        n = unpack(data, pos + 1, 2, 'n')
        stop = skip_atom(data, pos + 3) + (tag == NEWER_REFERENCE ? 4 : 1) + (4 * n)
        need(data, pos, stop - pos)
        [Reference.new(data.byteslice(pos, stop - pos)), stop]
      else
        raise DecodeError, [:invalid_encoding, tag]
      end
    end

    def unpack(data, pos, size, format)
      need(data, pos, size)
      data.unpack1(format, offset: pos)
    end

    def need(data, pos, count)
      raise DecodeError, [:truncated, data.bytesize - pos] if data.bytesize - pos < count

      true
    end

    def utf8(bytes)
      text = bytes.force_encoding(Encoding::UTF_8)
      raise DecodeError, [:invalid_encoding, 'binary is not UTF-8'] unless text.valid_encoding?

      text
    end

    # Returns `[bytes, next_position]` for the `BINARY_EXT` at `pos`, as a
    # BINARY String.
    def decode_binary(data, pos)
      n = unpack(data, pos + 1, 4, 'N')
      need(data, pos + 5, n)
      [data.byteslice(pos + 5, n), pos + 5 + n]
    end

    def decode_atom(data, pos)
      tag = data.getbyte(pos)
      if tag == SMALL_ATOM_UTF8 || tag == SMALL_ATOM
        need(data, pos, 2)
        n = data.getbyte(pos + 1)
        start = pos + 2
      else
        n = unpack(data, pos + 1, 2, 'n')
        start = pos + 3
      end
      need(data, start, n)
      name = data.byteslice(start, n)
      # Latin-1 atoms (`ATOM_EXT` / `SMALL_ATOM_EXT`) become UTF-8 text.
      name = tag == SMALL_ATOM || tag == ATOM ? name.encode(Encoding::UTF_8, Encoding::ISO_8859_1) : utf8(name)
      [name, start + n]
    end

    def skip_atom(data, pos)
      need(data, pos, 1)
      raise DecodeError, [:invalid_encoding, data.getbyte(pos)] unless ATOM_TAGS.include?(data.getbyte(pos))

      decode_atom(data, pos)[1]
    end

    def decode_list(data, pos, depth, limits)
      count = unpack(data, pos + 1, 4, 'N')
      check_length(count, limits)
      pos += 5
      items = Array.new(count)
      count.times do |i|
        items[i], pos = decode_term(data, pos, depth + 1, limits)
      end
      need(data, pos, 1)
      return [items, pos + 1] if data.getbyte(pos) == NIL

      tail, pos = decode_term(data, pos, depth + 1, limits)
      [ImproperList.new(items, tail), pos]
    end

    def decode_tuple(count, data, pos, depth, limits)
      check_length(count, limits)
      items = Array.new(count)
      count.times do |i|
        items[i], pos = decode_term(data, pos, depth + 1, limits)
      end
      [Tuple.new(items), pos]
    end

    def decode_big(count, data, pos)
      need(data, pos, 1 + count)
      sign = data.getbyte(pos)
      # Digits are little-endian; reversed, they read as one hex number.
      magnitude = count.zero? ? 0 : data.byteslice(pos + 1, count).reverse.unpack1('H*').to_i(16)
      [sign.zero? ? magnitude : -magnitude, pos + 1 + count]
    end

    # A `%Portals.Codec.Bin{}` struct (keys in either order) becomes a
    # BINARY String; any other map becomes a String-keyed Hash. The struct is
    # recognised on the raw atom keys, before they are turned into text.
    def decode_map(data, pos, depth, limits)
      count = unpack(data, pos + 1, 4, 'N')
      check_length(count, limits)
      pos += 5
      pairs = Array.new(count)
      count.times do |i|
        key, pos = decode_term(data, pos, depth + 1, limits)
        if key == DATA_KEY && data.getbyte(pos) == BINARY
          bytes, pos = decode_binary(data, pos)
          pairs[i] = [key, RawBinary.new(bytes)]
        else
          value, pos = decode_term(data, pos, depth + 1, limits)
          pairs[i] = [key, value]
        end
      end

      if count == 2
        fields = pairs.to_h
        raw = fields[DATA_KEY]
        return [raw.bytes, pos] if fields[STRUCT_KEY] == BIN_STRUCT && raw.is_a?(RawBinary)
      end

      result = {}
      pairs.each do |key, value|
        result[key_text(key)] = value.is_a?(RawBinary) ? utf8(value.bytes) : value
      end
      [result, pos]
    end

    def key_text(key)
      case key
      when String
        return key if key.encoding == Encoding::UTF_8
      when Symbol, Integer then return key.to_s
      # `to_string(nil)` on the BEAM, as its MessagePack encoder sends it.
      when nil then return ''
      when true then return 'true'
      when false then return 'false'
      end

      raise DecodeError, [:invalid_encoding, "unsupported map key #{key.inspect}"]
    end
  end
end
