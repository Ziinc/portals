# frozen_string_literal: true

require_relative 'protocol'
require_relative 'values'

# Pure-Ruby MessagePack codec implementing the exact subset used by the
# Portals v1 wire protocol, including the Erlang-value extensions
# (protocol/v1.md §5). Deliberately dependency-free — like the Python SDK's
# `msgpack_codec.py` — so a bare trusted-worker environment needs no gems,
# and so the ext-type semantics stay byte-for-byte identical to
# `lib/portals/codec/message_pack.ex`.
module Portals
  module MsgpackCodec
    EXT_TUPLE = 0
    EXT_ATOM = 1
    EXT_PID = 2
    EXT_REFERENCE = 3
    EXT_BIGINT = 4
    EXT_IMPROPER_LIST = 5

    UINT64_LIMIT = 18_446_744_073_709_551_616
    INT_LOWER_BOUND = -1_099_511_627_776

    EXT_FIXED_BY_SIZE = { 1 => 0xD4, 2 => 0xD5, 4 => 0xD6, 8 => 0xD7, 16 => 0xD8 }.freeze
    EXT_SIZE_BY_TAG = { 0xD4 => 1, 0xD5 => 2, 0xD6 => 4, 0xD7 => 8, 0xD8 => 16 }.freeze
    KNOWN_HEADERS = [0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8,
                     0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF].freeze

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

    module_function

    # Encode a frame envelope (an Array) to bytes.
    def encode(envelope, limits = Protocol::DEFAULT_LIMITS)
      body = encode_term(envelope, 0, limits)
      raise DecodeError, [:max_size_exceeded, body.bytesize] if body.bytesize > limits['max_frame_size']

      body
    end

    # Decode bytes to `[envelope, rest]`.
    def decode(data, limits = Protocol::DEFAULT_LIMITS)
      data = data.dup.force_encoding(Encoding::BINARY)
      raise DecodeError, [:max_size_exceeded, data.bytesize] if data.bytesize > limits['max_frame_size']

      term, pos = decode_term(data, 0, 0, limits)
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

    def encode_term(term, depth, limits)
      check_depth(depth, limits)

      case term
      when nil then "\xC0".b
      when false then "\xC2".b
      when true then "\xC3".b
      when Symbol then encode_ext(EXT_ATOM, term.to_s.b)
      when Pid then encode_ext(EXT_PID, term.raw)
      when Reference then encode_ext(EXT_REFERENCE, term.raw)
      when Bin then encode_bin(term.data)
      when Float64 then "\xCB".b + [term.value].pack('G')
      when Integer then encode_int(term)
      when Float then "\xCB".b + [term].pack('G')
      when String then encode_string_or_bin(term)
      when Tuple
        check_length(term.items.length, limits)
        encode_ext(EXT_TUPLE, encode_array(term.items, depth + 1, limits))
      when ImproperList
        encode_ext(EXT_IMPROPER_LIST, encode_array([term.items, term.tail], depth + 1, limits))
      when Hash
        check_length(term.size, limits)
        encode_map(term, depth, limits)
      when Array
        check_length(term.length, limits)
        encode_array(term, depth + 1, limits)
      else
        raise DecodeError, [:invalid_encoding, "unsupported type #{term.class}"]
      end
    end

    # Text-encoded Strings become MessagePack `str`; BINARY (ASCII-8BIT)
    # Strings become `bin`, per protocol/v1.md §5.2.
    def encode_string_or_bin(string)
      if string.encoding == Encoding::BINARY
        encode_bin(string)
      else
        encode_str(string.b)
      end
    end

    def encode_str(bytes)
      n = bytes.bytesize
      if n < 32 then [0b1010_0000 | n].pack('C') + bytes
      elsif n < 256 then "\xD9".b + [n].pack('C') + bytes
      elsif n < 65_536 then "\xDA".b + [n].pack('n') + bytes
      else "\xDB".b + [n].pack('N') + bytes
      end
    end

    def encode_bin(bytes)
      bytes = bytes.b
      n = bytes.bytesize
      if n < 256 then "\xC4".b + [n].pack('C') + bytes
      elsif n < 65_536 then "\xC5".b + [n].pack('n') + bytes
      else "\xC6".b + [n].pack('N') + bytes
      end
    end

    def encode_array(items, depth, limits)
      array_header(items.length) + items.map { |item| encode_term(item, depth, limits) }.join
    end

    def array_header(n)
      if n < 16 then [0b1001_0000 | n].pack('C')
      elsif n < 65_536 then "\xDC".b + [n].pack('n')
      else "\xDD".b + [n].pack('N')
      end
    end

    def encode_map(map, depth, limits)
      body = +''.b
      map.each do |key, value|
        body << encode_str(key.to_s.b) << encode_term(value, depth + 1, limits)
      end
      map_header(map.size) + body
    end

    def map_header(n)
      if n < 16 then [0b1000_0000 | n].pack('C')
      elsif n < 65_536 then "\xDE".b + [n].pack('n')
      else "\xDF".b + [n].pack('N')
      end
    end

    def encode_int(n)
      return encode_ext(EXT_BIGINT, encode_bigint(n)) unless n >= INT_LOWER_BOUND && n < UINT64_LIMIT

      if n >= 0 && n < 128 then [n].pack('C')
      elsif n >= -32 && n.negative? then [0b1110_0000 | (n + 32)].pack('C')
      elsif n >= 0 && n < 256 then "\xCC".b + [n].pack('C')
      elsif n >= 0 && n < 65_536 then "\xCD".b + [n].pack('n')
      elsif n >= 0 && n < 4_294_967_296 then "\xCE".b + [n].pack('N')
      elsif n >= 0 then "\xCF".b + [n].pack('Q>')
      elsif n >= -128 then "\xD0".b + [n].pack('c')
      elsif n >= -32_768 then "\xD1".b + [n].pack('s>')
      elsif n >= -2_147_483_648 then "\xD2".b + [n].pack('l>')
      else "\xD3".b + [n].pack('q>')
      end
    end

    def encode_bigint(n)
      sign = n.negative? ? 1 : 0
      magnitude = n.abs
      digits = magnitude.digits(256).reverse
      digits = [0] if digits.empty?
      [sign].pack('C') + digits.pack('C*')
    end

    def encode_ext(type_code, payload)
      payload = payload.b
      n = payload.bytesize
      code = type_code & 0xFF

      if (tag = EXT_FIXED_BY_SIZE[n])
        [tag, code].pack('CC') + payload
      elsif n < 256
        "\xC7".b + [n, code].pack('CC') + payload
      elsif n < 65_536
        "\xC8".b + [n].pack('n') + [code].pack('C') + payload
      else
        "\xC9".b + [n].pack('N') + [code].pack('C') + payload
      end
    end

    # -- Decoding ---------------------------------------------------------

    # Returns `[term, next_position]`. Position-based rather than
    # slice-based so large payloads decode in linear time.
    def decode_term(data, pos, depth, limits)
      check_depth(depth, limits)
      need(data, pos, 1)
      b0 = data.getbyte(pos)

      case b0
      when 0xC0 then return [nil, pos + 1]
      when 0xC2 then return [false, pos + 1]
      when 0xC3 then return [true, pos + 1]
      when 0xCC then need(data, pos, 2) and return [data.getbyte(pos + 1), pos + 2]
      when 0xCD then need(data, pos, 3) and return [unpack(data, pos + 1, 2, 'n'), pos + 3]
      when 0xCE then need(data, pos, 5) and return [unpack(data, pos + 1, 4, 'N'), pos + 5]
      when 0xCF then need(data, pos, 9) and return [unpack(data, pos + 1, 8, 'Q>'), pos + 9]
      when 0xD0 then need(data, pos, 2) and return [unpack(data, pos + 1, 1, 'c'), pos + 2]
      when 0xD1 then need(data, pos, 3) and return [unpack(data, pos + 1, 2, 's>'), pos + 3]
      when 0xD2 then need(data, pos, 5) and return [unpack(data, pos + 1, 4, 'l>'), pos + 5]
      when 0xD3 then need(data, pos, 9) and return [unpack(data, pos + 1, 8, 'q>'), pos + 9]
      when 0xCB then need(data, pos, 9) and return [unpack(data, pos + 1, 8, 'G'), pos + 9]
      when 0xC4 then return decode_bin(data, pos, 1, 'C')
      when 0xC5 then return decode_bin(data, pos, 2, 'n')
      when 0xC6 then return decode_bin(data, pos, 4, 'N')
      when 0xD9 then return decode_str(data, pos, 1, 'C')
      when 0xDA then return decode_str(data, pos, 2, 'n')
      when 0xDB then return decode_str(data, pos, 4, 'N')
      when 0xDC
        need(data, pos, 3)
        return decode_array(unpack(data, pos + 1, 2, 'n'), data, pos + 3, depth, limits)
      when 0xDD
        need(data, pos, 5)
        return decode_array(unpack(data, pos + 1, 4, 'N'), data, pos + 5, depth, limits)
      when 0xDE
        need(data, pos, 3)
        return decode_map(unpack(data, pos + 1, 2, 'n'), data, pos + 3, depth, limits)
      when 0xDF
        need(data, pos, 5)
        return decode_map(unpack(data, pos + 1, 4, 'N'), data, pos + 5, depth, limits)
      when 0xC7
        need(data, pos, 2)
        return decode_ext_at(data, pos, data.getbyte(pos + 1), 2, depth, limits)
      when 0xC8
        need(data, pos, 3)
        return decode_ext_at(data, pos, unpack(data, pos + 1, 2, 'n'), 3, depth, limits)
      when 0xC9
        need(data, pos, 5)
        return decode_ext_at(data, pos, unpack(data, pos + 1, 4, 'N'), 5, depth, limits)
      end

      return [b0, pos + 1] if b0 < 0x80
      return [b0 - 256, pos + 1] if b0 >= 0xE0
      return decode_str_fixed(data, pos + 1, b0 & 0x1F) if b0 >= 0xA0 && b0 <= 0xBF
      return decode_array(b0 & 0x0F, data, pos + 1, depth, limits) if b0 >= 0x90 && b0 <= 0x9F
      return decode_map(b0 & 0x0F, data, pos + 1, depth, limits) if b0 >= 0x80 && b0 <= 0x8F

      if (size = EXT_SIZE_BY_TAG[b0])
        return decode_ext_at(data, pos, size, 1, depth, limits)
      end

      raise DecodeError, [:truncated, data.bytesize - pos] if KNOWN_HEADERS.include?(b0)

      raise DecodeError, [:invalid_encoding, b0]
    end

    def unpack(data, pos, size, format)
      need(data, pos - 1, size + 1)
      data.byteslice(pos, size).unpack1(format)
    end

    def need(data, pos, count)
      raise DecodeError, [:truncated, data.bytesize - pos] if data.bytesize - pos < count

      true
    end

    def decode_bin(data, pos, header_size, format)
      need(data, pos, 1 + header_size)
      n = data.byteslice(pos + 1, header_size).unpack1(format)
      start = pos + 1 + header_size
      need(data, start, n)
      [data.byteslice(start, n), start + n]
    end

    def decode_str(data, pos, header_size, format)
      need(data, pos, 1 + header_size)
      n = data.byteslice(pos + 1, header_size).unpack1(format)
      decode_str_fixed(data, pos + 1 + header_size, n)
    end

    def decode_str_fixed(data, start, n)
      need(data, start, n)
      text = data.byteslice(start, n).force_encoding(Encoding::UTF_8)
      [text, start + n]
    end

    def decode_array(count, data, pos, depth, limits)
      check_length(count, limits)
      items = Array.new(count)
      count.times do |i|
        items[i], pos = decode_term(data, pos, depth + 1, limits)
      end
      [items, pos]
    end

    def decode_map(count, data, pos, depth, limits)
      check_length(count, limits)
      result = {}
      count.times do
        key, pos = decode_term(data, pos, depth + 1, limits)
        value, pos = decode_term(data, pos, depth + 1, limits)
        result[key] = value
      end
      [result, pos]
    end

    def decode_ext_at(data, pos, payload_size, header_size, depth, limits)
      type_pos = pos + header_size
      need(data, type_pos, 1 + payload_size)
      type_code = signed8(data.getbyte(type_pos))
      payload = data.byteslice(type_pos + 1, payload_size)
      [decode_ext(type_code, payload, depth, limits), type_pos + 1 + payload_size]
    end

    def signed8(byte)
      byte >= 128 ? byte - 256 : byte
    end

    def decode_ext(type_code, payload, depth, limits)
      case type_code
      when EXT_BIGINT
        raise DecodeError, [:invalid_extension, 'bigint'] if payload.bytesize < 1

        sign = payload.getbyte(0)
        magnitude = payload.byteslice(1, payload.bytesize - 1).bytes.reduce(0) { |acc, b| (acc << 8) | b }
        sign == 1 ? -magnitude : magnitude
      when EXT_ATOM
        text = payload.dup.force_encoding(Encoding::UTF_8)
        raise DecodeError, [:invalid_extension, 'atom'] unless text.valid_encoding?

        # Ruby has no BEAM atom table, so §5.3's unsafe-atom concern does
        # not apply here; Symbols round-trip identically.
        text.to_sym
      when EXT_PID then Pid.new(payload)
      when EXT_REFERENCE then Reference.new(payload)
      when EXT_TUPLE
        items, pos = decode_term(payload, 0, depth + 1, limits)
        raise DecodeError, [:invalid_extension, 'tuple'] unless items.is_a?(Array) && pos == payload.bytesize

        Tuple.new(items)
      when EXT_IMPROPER_LIST
        pair, pos = decode_term(payload, 0, depth + 1, limits)
        unless pair.is_a?(Array) && pair.length == 2 && pos == payload.bytesize
          raise DecodeError, [:invalid_extension, 'improper_list']
        end

        ImproperList.new(pair[0], pair[1])
      else
        raise DecodeError, [:invalid_extension, type_code]
      end
    end
  end
end
