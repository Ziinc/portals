package portals;

import java.io.ByteArrayOutputStream;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.CharBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Pure-Java MessagePack codec implementing the exact subset used by the
 * Portals v1 wire protocol, including the Erlang-value extensions
 * (protocol/v1.md §5). Deliberately dependency-free — like the Ruby and Node
 * SDKs' codecs — so a bare JDK is all a trusted worker needs, and so the
 * ext-type semantics stay byte-for-byte identical to
 * {@code lib/portals/codec/message_pack.ex}.
 *
 * <p>Host types: {@code nil} is {@code null}; booleans are {@link Boolean};
 * integers decode to {@link Long} (or {@link BigInteger} beyond 64-bit
 * signed range); floats to {@link Double}; {@code str} to {@link String};
 * {@code bin} to {@code byte[]}; arrays to {@link List}; maps to a
 * string-keyed {@link LinkedHashMap}; and the Erlang extensions to
 * {@link Tuple}, {@link Atom}, {@link Pid}, {@link Ref} and
 * {@link ImproperList}.
 */
public final class MsgpackCodec {
  private MsgpackCodec() {}

  public static final int EXT_TUPLE = 0;
  public static final int EXT_ATOM = 1;
  public static final int EXT_PID = 2;
  public static final int EXT_REFERENCE = 3;
  public static final int EXT_BIGINT = 4;
  public static final int EXT_IMPROPER_LIST = 5;

  private static final BigInteger UINT64_LIMIT = BigInteger.ONE.shiftLeft(64);
  // Matches the reference codec: integers below -2^40 travel as bigints.
  private static final long INT_LOWER_BOUND = -1_099_511_627_776L;

  /** A decoded term plus the number of input bytes it consumed. */
  public record Decoded(Object term, int consumed, int length) {
    public int restLength() {
      return length - consumed;
    }
  }

  // -- Encoding -------------------------------------------------------------

  public static byte[] encode(Object envelope) throws DecodeException {
    return encode(envelope, Limits.DEFAULT);
  }

  public static byte[] encode(Object envelope, Limits limits) throws DecodeException {
    Encoder encoder = new Encoder(limits);
    encoder.term(envelope, 0);
    byte[] body = encoder.out.toByteArray();
    if (body.length > limits.maxFrameSize()) throw new DecodeException("max_size_exceeded", body.length);
    return body;
  }

  private static final class Encoder {
    final Limits limits;
    final Buf out = new Buf();

    Encoder(Limits limits) {
      this.limits = limits;
    }

    void term(Object term, int depth) throws DecodeException {
      checkDepth(depth, limits);

      if (term == null) {
        out.write(0xc0);
      } else if (term instanceof Boolean b) {
        out.write(b ? 0xc3 : 0xc2);
      } else if (term instanceof Long || term instanceof Integer || term instanceof Short || term instanceof Byte) {
        integer(((Number) term).longValue());
      } else if (term instanceof BigInteger big) {
        bigInteger(big);
      } else if (term instanceof Double || term instanceof Float) {
        out.write(0xcb);
        out.writeLong(Double.doubleToLongBits(((Number) term).doubleValue()));
      } else if (term instanceof String s) {
        str(s.getBytes(StandardCharsets.UTF_8));
      } else if (term instanceof byte[] bytes) {
        bin(bytes);
      } else if (term instanceof Bin bin) {
        bin(bin.dataUnsafe());
      } else if (term instanceof ByteBuffer buffer) {
        ByteBuffer copy = buffer.duplicate();
        byte[] bytes = new byte[copy.remaining()];
        copy.get(bytes);
        bin(bytes);
      } else if (term instanceof Atom atom) {
        ext(EXT_ATOM, atom.name().getBytes(StandardCharsets.UTF_8));
      } else if (term instanceof Pid pid) {
        ext(EXT_PID, pid.rawUnsafe());
      } else if (term instanceof Ref ref) {
        ext(EXT_REFERENCE, ref.rawUnsafe());
      } else if (term instanceof Tuple tuple) {
        checkLength(tuple.size(), limits);
        ext(EXT_TUPLE, nested(tuple.items(), depth + 1));
      } else if (term instanceof ImproperList list) {
        ext(EXT_IMPROPER_LIST, nested(Arrays.asList(list.items(), list.tail()), depth + 1));
      } else if (term instanceof List<?> list) {
        checkLength(list.size(), limits);
        array(list, depth + 1);
      } else if (term instanceof Object[] array) {
        checkLength(array.length, limits);
        array(Arrays.asList(array), depth + 1);
      } else if (term instanceof Map<?, ?> map) {
        checkLength(map.size(), limits);
        map(map, depth);
      } else if (term instanceof Enum<?> e) {
        // Enum constants are the closest Java analogue of atoms.
        ext(EXT_ATOM, e.name().getBytes(StandardCharsets.UTF_8));
      } else {
        throw new DecodeException("invalid_encoding", "unsupported type " + term.getClass().getName());
      }
    }

    byte[] nested(List<?> items, int depth) throws DecodeException {
      Encoder inner = new Encoder(limits);
      inner.array(items, depth);
      return inner.out.toByteArray();
    }

    void array(List<?> items, int depth) throws DecodeException {
      int n = items.size();
      if (n < 16) {
        out.write(0x90 | n);
      } else if (n < 65536) {
        out.write(0xdc);
        out.writeShort(n);
      } else {
        out.write(0xdd);
        out.writeInt(n);
      }
      for (Object item : items) term(item, depth);
    }

    void map(Map<?, ?> map, int depth) throws DecodeException {
      int n = map.size();
      if (n < 16) {
        out.write(0x80 | n);
      } else if (n < 65536) {
        out.write(0xde);
        out.writeShort(n);
      } else {
        out.write(0xdf);
        out.writeInt(n);
      }
      for (Map.Entry<?, ?> entry : map.entrySet()) {
        str(String.valueOf(entry.getKey()).getBytes(StandardCharsets.UTF_8));
        term(entry.getValue(), depth + 1);
      }
    }

    void str(byte[] bytes) {
      int n = bytes.length;
      if (n < 32) {
        out.write(0xa0 | n);
      } else if (n < 256) {
        out.write(0xd9);
        out.write(n);
      } else if (n < 65536) {
        out.write(0xda);
        out.writeShort(n);
      } else {
        out.write(0xdb);
        out.writeInt(n);
      }
      out.write(bytes, 0, n);
    }

    void bin(byte[] bytes) {
      int n = bytes.length;
      if (n < 256) {
        out.write(0xc4);
        out.write(n);
      } else if (n < 65536) {
        out.write(0xc5);
        out.writeShort(n);
      } else {
        out.write(0xc6);
        out.writeInt(n);
      }
      out.write(bytes, 0, n);
    }

    void bigInteger(BigInteger n) {
      if (n.bitLength() < 64) {
        integer(n.longValue());
      } else if (n.signum() > 0 && n.compareTo(UINT64_LIMIT) < 0) {
        out.write(0xcf);
        out.writeLong(n.longValue());
      } else {
        ext(EXT_BIGINT, bigintPayload(n));
      }
    }

    void integer(long n) {
      if (n < INT_LOWER_BOUND) {
        ext(EXT_BIGINT, bigintPayload(BigInteger.valueOf(n)));
      } else if (n >= 0 && n < 128) {
        out.write((int) n);
      } else if (n >= -32 && n < 0) {
        out.write(0xe0 | (int) (n + 32));
      } else if (n >= 0 && n < 256) {
        out.write(0xcc);
        out.write((int) n);
      } else if (n >= 0 && n < 65536) {
        out.write(0xcd);
        out.writeShort((int) n);
      } else if (n >= 0 && n < 4294967296L) {
        out.write(0xce);
        out.writeInt((int) n);
      } else if (n >= 0) {
        out.write(0xcf);
        out.writeLong(n);
      } else if (n >= -128) {
        out.write(0xd0);
        out.write((int) n & 0xff);
      } else if (n >= -32768) {
        out.write(0xd1);
        out.writeShort((int) n);
      } else if (n >= -2147483648L) {
        out.write(0xd2);
        out.writeInt((int) n);
      } else {
        out.write(0xd3);
        out.writeLong(n);
      }
    }

    void ext(int typeCode, byte[] payload) {
      int n = payload.length;
      switch (n) {
        case 1 -> out.write(0xd4);
        case 2 -> out.write(0xd5);
        case 4 -> out.write(0xd6);
        case 8 -> out.write(0xd7);
        case 16 -> out.write(0xd8);
        default -> {
          if (n < 256) {
            out.write(0xc7);
            out.write(n);
          } else if (n < 65536) {
            out.write(0xc8);
            out.writeShort(n);
          } else {
            out.write(0xc9);
            out.writeInt(n);
          }
        }
      }
      out.write(typeCode & 0xff);
      out.write(payload, 0, n);
    }
  }

  static byte[] bigintPayload(BigInteger n) {
    byte[] magnitude = n.abs().toByteArray();
    // BigInteger.toByteArray is two's complement: drop a leading sign byte.
    int start = magnitude.length > 1 && magnitude[0] == 0 ? 1 : 0;
    byte[] payload = new byte[1 + magnitude.length - start];
    payload[0] = (byte) (n.signum() < 0 ? 1 : 0);
    System.arraycopy(magnitude, start, payload, 1, magnitude.length - start);
    return payload;
  }

  private static final class Buf extends ByteArrayOutputStream {
    Buf() {
      super(64);
    }

    void writeShort(int v) {
      write((v >>> 8) & 0xff);
      write(v & 0xff);
    }

    void writeInt(int v) {
      writeShort(v >>> 16);
      writeShort(v);
    }

    void writeLong(long v) {
      writeInt((int) (v >>> 32));
      writeInt((int) v);
    }
  }

  // -- Decoding -------------------------------------------------------------

  /** Decodes one term from the front of {@code data}. */
  public static Decoded decode(byte[] data) throws DecodeException {
    return decode(data, Limits.DEFAULT);
  }

  public static Decoded decode(byte[] data, Limits limits) throws DecodeException {
    if (data.length > limits.maxFrameSize()) throw new DecodeException("max_size_exceeded", data.length);
    Decoder decoder = new Decoder(data, 0, data.length, limits);
    Object term = decoder.term(0);
    return new Decoded(term, decoder.pos, data.length);
  }

  /** Decodes one complete frame envelope: an array with no trailing bytes. */
  public static List<Object> decodeEnvelope(byte[] data, Limits limits) throws DecodeException {
    Decoded decoded = decode(data, limits);
    if (decoded.restLength() != 0) throw new DecodeException("trailing_bytes", decoded.restLength());
    if (!(decoded.term() instanceof List<?> list) || list.isEmpty()) {
      throw new DecodeException("invalid_envelope", decoded.term());
    }
    @SuppressWarnings("unchecked")
    List<Object> envelope = (List<Object>) list;
    return envelope;
  }

  private static final class Decoder {
    final byte[] data;
    final int end;
    final Limits limits;
    int pos;

    Decoder(byte[] data, int start, int end, Limits limits) {
      this.data = data;
      this.pos = start;
      this.end = end;
      this.limits = limits;
    }

    void need(long count) throws DecodeException {
      if (end - pos < count) throw new DecodeException("truncated", Math.max(end - pos, 0));
    }

    int u8() {
      return data[pos++] & 0xff;
    }

    int u16() {
      return (u8() << 8) | u8();
    }

    long u32() {
      return ((long) u16() << 16) | u16();
    }

    long i64() {
      return (u32() << 32) | u32();
    }

    Object term(int depth) throws DecodeException {
      checkDepth(depth, limits);
      need(1);
      int b0 = u8();

      switch (b0) {
        case 0xc0: return null;
        case 0xc2: return Boolean.FALSE;
        case 0xc3: return Boolean.TRUE;
        case 0xcc: need(1); return (long) u8();
        case 0xcd: need(2); return (long) u16();
        case 0xce: need(4); return u32();
        case 0xcf: {
          need(8);
          long raw = i64();
          return raw >= 0 ? (Object) raw : new BigInteger(Long.toUnsignedString(raw));
        }
        case 0xd0: need(1); return (long) (byte) u8();
        case 0xd1: need(2); return (long) (short) u16();
        case 0xd2: need(4); return (long) (int) u32();
        case 0xd3: need(8); return i64();
        case 0xca: need(4); return (double) Float.intBitsToFloat((int) u32());
        case 0xcb: need(8); return Double.longBitsToDouble(i64());
        case 0xc4: need(1); return bin(u8());
        case 0xc5: need(2); return bin(u16());
        case 0xc6: need(4); return bin(u32());
        case 0xd9: need(1); return str(u8());
        case 0xda: need(2); return str(u16());
        case 0xdb: need(4); return str(u32());
        case 0xdc: need(2); return array(u16(), depth);
        case 0xdd: need(4); return array(u32(), depth);
        case 0xde: need(2); return map(u16(), depth);
        case 0xdf: need(4); return map(u32(), depth);
        case 0xc7: need(1); return ext(u8(), depth);
        case 0xc8: need(2); return ext(u16(), depth);
        case 0xc9: need(4); return ext(u32(), depth);
        case 0xd4: return ext(1, depth);
        case 0xd5: return ext(2, depth);
        case 0xd6: return ext(4, depth);
        case 0xd7: return ext(8, depth);
        case 0xd8: return ext(16, depth);
        default: break;
      }

      if (b0 < 0x80) return (long) b0;
      if (b0 >= 0xe0) return (long) (b0 - 256);
      if (b0 >= 0xa0 && b0 <= 0xbf) return str(b0 & 0x1f);
      if (b0 >= 0x90 && b0 <= 0x9f) return array(b0 & 0x0f, depth);
      if (b0 >= 0x80 && b0 <= 0x8f) return map(b0 & 0x0f, depth);
      throw new DecodeException("invalid_encoding", b0);
    }

    byte[] bytes(long n) throws DecodeException {
      need(n);
      byte[] out = Arrays.copyOfRange(data, pos, pos + (int) n);
      pos += (int) n;
      return out;
    }

    byte[] bin(long n) throws DecodeException {
      return bytes(n);
    }

    String str(long n) throws DecodeException {
      need(n);
      String s = new String(data, pos, (int) n, StandardCharsets.UTF_8);
      pos += (int) n;
      return s;
    }

    List<Object> array(long count, int depth) throws DecodeException {
      checkLength(count, limits);
      List<Object> items = new ArrayList<>((int) Math.min(count, end - pos));
      for (long i = 0; i < count; i++) items.add(term(depth + 1));
      return items;
    }

    Map<String, Object> map(long count, int depth) throws DecodeException {
      checkLength(count, limits);
      Map<String, Object> result = new LinkedHashMap<>();
      for (long i = 0; i < count; i++) {
        Object key = term(depth + 1);
        Object value = term(depth + 1);
        String name = key instanceof byte[] raw ? new String(raw, StandardCharsets.UTF_8) : String.valueOf(key);
        result.put(name, value);
      }
      return result;
    }

    Object ext(long payloadSize, int depth) throws DecodeException {
      need(1 + payloadSize);
      int typeCode = (byte) u8();
      byte[] payload = bytes(payloadSize);
      return decodeExt(typeCode, payload, depth);
    }

    Object decodeExt(int typeCode, byte[] payload, int depth) throws DecodeException {
      switch (typeCode) {
        case EXT_BIGINT: {
          if (payload.length < 1) throw new DecodeException("invalid_extension", "bigint");
          BigInteger magnitude = new BigInteger(1, Arrays.copyOfRange(payload, 1, payload.length));
          return Values.normalizeInteger(payload[0] == 1 ? magnitude.negate() : magnitude);
        }
        case EXT_ATOM:
          return new Atom(strictUtf8(payload));
        case EXT_PID:
          return new Pid(payload);
        case EXT_REFERENCE:
          return new Ref(payload);
        case EXT_TUPLE: {
          Decoder inner = new Decoder(payload, 0, payload.length, limits);
          Object items = inner.term(depth + 1);
          if (!(items instanceof List<?> list) || inner.pos != payload.length) {
            throw new DecodeException("invalid_extension", "tuple");
          }
          return new Tuple(list);
        }
        case EXT_IMPROPER_LIST: {
          Decoder inner = new Decoder(payload, 0, payload.length, limits);
          Object pair = inner.term(depth + 1);
          if (!(pair instanceof List<?> list) || list.size() != 2 || inner.pos != payload.length) {
            throw new DecodeException("invalid_extension", "improper_list");
          }
          return new ImproperList(list.get(0), list.get(1));
        }
        default:
          throw new DecodeException("invalid_extension", typeCode);
      }
    }
  }

  private static String strictUtf8(byte[] payload) throws DecodeException {
    try {
      CharBuffer chars = StandardCharsets.UTF_8.newDecoder()
          .onMalformedInput(CodingErrorAction.REPORT)
          .onUnmappableCharacter(CodingErrorAction.REPORT)
          .decode(ByteBuffer.wrap(payload));
      return chars.toString();
    } catch (CharacterCodingException e) {
      throw new DecodeException("invalid_extension", "atom");
    }
  }

  private static void checkDepth(int depth, Limits limits) throws DecodeException {
    if (depth > limits.maxNestingDepth()) throw new DecodeException("max_depth_exceeded", depth);
  }

  private static void checkLength(long count, Limits limits) throws DecodeException {
    if (count > limits.maxCollectionLength()) throw new DecodeException("max_length_exceeded", count);
  }
}
