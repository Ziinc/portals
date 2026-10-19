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
 * Pure-Java Erlang External Term Format codec (protocol/v1.md §5.4), the
 * Java side of {@code lib/portals/codec/etf.ex} and the default wire codec
 * (see {@link Codec}). Dependency-free like {@link MsgpackCodec}, and
 * decoding to exactly the same host types, so handlers never see which
 * codec is in use:
 *
 * <p>the atoms {@code nil}, {@code true} and {@code false} are {@code null}
 * and {@link Boolean}, other atoms {@link Atom}; integers decode to
 * {@link Long} (or {@link BigInteger} beyond 64-bit signed range); floats
 * to {@link Double}; binaries to {@link String} (strict UTF-8); a
 * {@code %Portals.Codec.Bin{}} struct to {@code byte[]}; lists to
 * {@link List}; other maps to a string-keyed {@link LinkedHashMap} (atom
 * and integer keys become their text, as under MessagePack); tuples to
 * {@link Tuple}; improper lists to {@link ImproperList}; and PIDs and
 * references to opaque {@link Pid} / {@link Ref} holding the term's own
 * bytes, which are written back verbatim.
 */
public final class EtfCodec {
  private EtfCodec() {}

  public static final int VERSION = 131;

  public static final int NEW_FLOAT_EXT = 70;
  public static final int BIT_BINARY_EXT = 77;
  public static final int NEW_PID_EXT = 88;
  public static final int NEWER_REFERENCE_EXT = 90;
  public static final int SMALL_INTEGER_EXT = 97;
  public static final int INTEGER_EXT = 98;
  public static final int ATOM_EXT = 100;
  public static final int PID_EXT = 103;
  public static final int SMALL_TUPLE_EXT = 104;
  public static final int LARGE_TUPLE_EXT = 105;
  public static final int NIL_EXT = 106;
  public static final int STRING_EXT = 107;
  public static final int LIST_EXT = 108;
  public static final int BINARY_EXT = 109;
  public static final int SMALL_BIG_EXT = 110;
  public static final int LARGE_BIG_EXT = 111;
  public static final int NEW_REFERENCE_EXT = 114;
  public static final int SMALL_ATOM_EXT = 115;
  public static final int MAP_EXT = 116;
  public static final int ATOM_UTF8_EXT = 118;
  public static final int SMALL_ATOM_UTF8_EXT = 119;

  private static final Atom STRUCT_KEY = new Atom("__struct__");
  private static final Atom DATA_KEY = new Atom("data");
  private static final Atom BIN_STRUCT = new Atom("Elixir.Portals.Codec.Bin");

  // How a byte buffer is encoded: %Portals.Codec.Bin{data: ...}, up to the
  // data binary itself.
  private static final byte[] BIN_PREFIX = binPrefix();

  private static byte[] binPrefix() {
    Buf out = new Buf();
    out.write(MAP_EXT);
    out.writeInt(2);
    for (String name : new String[] {"__struct__", "Elixir.Portals.Codec.Bin", "data"}) {
      byte[] text = name.getBytes(StandardCharsets.UTF_8);
      out.write(SMALL_ATOM_UTF8_EXT);
      out.write(text.length);
      out.write(text, 0, text.length);
    }
    return out.toByteArray();
  }

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
    encoder.out.write(VERSION);
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
        atom("nil");
      } else if (term instanceof Boolean b) {
        atom(b ? "true" : "false");
      } else if (term instanceof Long || term instanceof Integer || term instanceof Short || term instanceof Byte) {
        integer(((Number) term).longValue());
      } else if (term instanceof BigInteger big) {
        integer(big);
      } else if (term instanceof Double || term instanceof Float) {
        out.write(NEW_FLOAT_EXT);
        out.writeLong(Double.doubleToLongBits(((Number) term).doubleValue()));
      } else if (term instanceof String s) {
        binary(s.getBytes(StandardCharsets.UTF_8));
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
        atom(atom.name());
      } else if (term instanceof Pid pid) {
        byte[] raw = pid.rawUnsafe();
        out.write(raw, 0, raw.length);
      } else if (term instanceof Ref ref) {
        byte[] raw = ref.rawUnsafe();
        out.write(raw, 0, raw.length);
      } else if (term instanceof Tuple tuple) {
        int n = tuple.size();
        checkLength(n, limits);
        if (n < 256) {
          out.write(SMALL_TUPLE_EXT);
          out.write(n);
        } else {
          out.write(LARGE_TUPLE_EXT);
          out.writeInt(n);
        }
        for (Object item : tuple.items()) term(item, depth + 1);
      } else if (term instanceof ImproperList list) {
        List<?> items = asList(list.items());
        if (items == null) {
          throw new DecodeException("invalid_encoding", "improper list items must be a list");
        }
        checkLength(items.size(), limits);
        out.write(LIST_EXT);
        out.writeInt(items.size());
        for (Object item : items) term(item, depth + 1);
        term(list.tail(), depth + 1);
      } else if (term instanceof List<?> || term instanceof Object[]) {
        List<?> items = asList(term);
        checkLength(items.size(), limits);
        if (!items.isEmpty()) {
          out.write(LIST_EXT);
          out.writeInt(items.size());
          for (Object item : items) term(item, depth + 1);
        }
        out.write(NIL_EXT);
      } else if (term instanceof Map<?, ?> map) {
        checkLength(map.size(), limits);
        out.write(MAP_EXT);
        out.writeInt(map.size());
        for (Map.Entry<?, ?> entry : map.entrySet()) {
          // Keys are sent as text, as under MessagePack.
          Object key = entry.getKey();
          binary((key instanceof Atom atom ? atom.name() : String.valueOf(key)).getBytes(StandardCharsets.UTF_8));
          term(entry.getValue(), depth + 1);
        }
      } else if (term instanceof Enum<?> e) {
        // Enum constants are the closest Java analogue of atoms.
        atom(e.name());
      } else {
        throw new DecodeException("invalid_encoding", "unsupported type " + term.getClass().getName());
      }
    }

    void atom(String name) throws DecodeException {
      byte[] text = name.getBytes(StandardCharsets.UTF_8);
      int n = text.length;
      if (n < 256) {
        out.write(SMALL_ATOM_UTF8_EXT);
        out.write(n);
      } else if (n < 65536) {
        out.write(ATOM_UTF8_EXT);
        out.writeShort(n);
      } else {
        throw new DecodeException("invalid_encoding", "atom too long");
      }
      out.write(text, 0, n);
    }

    void binary(byte[] bytes) {
      out.write(BINARY_EXT);
      out.writeInt(bytes.length);
      out.write(bytes, 0, bytes.length);
    }

    void bin(byte[] bytes) {
      out.write(BIN_PREFIX, 0, BIN_PREFIX.length);
      binary(bytes);
    }

    void integer(long n) {
      if (n >= 0 && n < 256) {
        out.write(SMALL_INTEGER_EXT);
        out.write((int) n);
      } else if (n >= Integer.MIN_VALUE && n <= Integer.MAX_VALUE) {
        out.write(INTEGER_EXT);
        out.writeInt((int) n);
      } else {
        integer(BigInteger.valueOf(n));
      }
    }

    void integer(BigInteger n) {
      if (n.bitLength() < 32) {
        integer(n.longValue());
      } else {
        byte[] digits = littleEndianMagnitude(n);
        if (digits.length < 256) {
          out.write(SMALL_BIG_EXT);
          out.write(digits.length);
        } else {
          out.write(LARGE_BIG_EXT);
          out.writeInt(digits.length);
        }
        out.write(n.signum() < 0 ? 1 : 0);
        out.write(digits, 0, digits.length);
      }
    }
  }

  private static List<?> asList(Object items) {
    if (items instanceof List<?> list) return list;
    if (items instanceof Object[] array) return Arrays.asList(array);
    return null;
  }

  static byte[] littleEndianMagnitude(BigInteger n) {
    byte[] magnitude = n.abs().toByteArray();
    // BigInteger.toByteArray is big-endian two's complement: drop a leading
    // sign byte, then reverse.
    int start = magnitude.length > 1 && magnitude[0] == 0 ? 1 : 0;
    byte[] digits = new byte[magnitude.length - start];
    for (int i = 0; i < digits.length; i++) digits[i] = magnitude[magnitude.length - 1 - i];
    return digits;
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

  /** Decodes one term (version byte included) from the front of {@code data}. */
  public static Decoded decode(byte[] data) throws DecodeException {
    return decode(data, Limits.DEFAULT);
  }

  public static Decoded decode(byte[] data, Limits limits) throws DecodeException {
    if (data.length > limits.maxFrameSize()) throw new DecodeException("max_size_exceeded", data.length);
    if (data.length == 0) throw new DecodeException("truncated", 0);
    if ((data[0] & 0xff) != VERSION) throw new DecodeException("invalid_encoding", data[0] & 0xff);
    Decoder decoder = new Decoder(data, 1, data.length, limits);
    Object term = decoder.term(0);
    return new Decoded(term, decoder.pos, data.length);
  }

  /** Decodes one complete frame envelope: a list with no trailing bytes. */
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

  /** A map's {@code data} binary, kept raw until we know whether the map is a Bin struct. */
  private record RawBinary(byte[] data) {}

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
      int start = pos;
      int tag = u8();

      switch (tag) {
        case SMALL_INTEGER_EXT: need(1); return (long) u8();
        case INTEGER_EXT: need(4); return (long) (int) u32();
        case NEW_FLOAT_EXT: need(8); return Double.longBitsToDouble(i64());
        case SMALL_ATOM_UTF8_EXT: case SMALL_ATOM_EXT: need(1); return atom(tag, u8());
        case ATOM_UTF8_EXT: case ATOM_EXT: need(2); return atom(tag, u16());
        case BINARY_EXT: need(4); return text(bytes(u32()));
        case NIL_EXT: return new ArrayList<>();
        case LIST_EXT: need(4); return list(u32(), depth);
        case STRING_EXT: {
          need(2);
          int n = u16();
          checkLength(n, limits);
          need(n);
          List<Object> items = new ArrayList<>(n);
          for (int i = 0; i < n; i++) items.add((long) u8());
          return items;
        }
        case SMALL_TUPLE_EXT: need(1); return tuple(u8(), depth);
        case LARGE_TUPLE_EXT: need(4); return tuple(u32(), depth);
        case MAP_EXT: need(4); return map(u32(), depth);
        case SMALL_BIG_EXT: need(1); return big(u8());
        case LARGE_BIG_EXT: need(4); return big(u32());
        case NEW_PID_EXT: skipAtom(); need(12); pos += 12; return new Pid(Arrays.copyOfRange(data, start, pos));
        case PID_EXT: skipAtom(); need(9); pos += 9; return new Pid(Arrays.copyOfRange(data, start, pos));
        case NEWER_REFERENCE_EXT: case NEW_REFERENCE_EXT: {
          need(2);
          int words = u16();
          skipAtom();
          long size = (tag == NEWER_REFERENCE_EXT ? 4 : 1) + 4L * words;
          need(size);
          pos += (int) size;
          return new Ref(Arrays.copyOfRange(data, start, pos));
        }
        default:
          throw new DecodeException("invalid_encoding", tag);
      }
    }

    byte[] bytes(long n) throws DecodeException {
      need(n);
      byte[] out = Arrays.copyOfRange(data, pos, pos + (int) n);
      pos += (int) n;
      return out;
    }

    Object atom(int tag, int n) throws DecodeException {
      byte[] raw = bytes(n);
      String name = tag == SMALL_ATOM_EXT || tag == ATOM_EXT
          ? new String(raw, StandardCharsets.ISO_8859_1)
          : text(raw);
      switch (name) {
        case "nil": return null;
        case "true": return Boolean.TRUE;
        case "false": return Boolean.FALSE;
        default: return new Atom(name);
      }
    }

    void skipAtom() throws DecodeException {
      need(1);
      int tag = u8();
      switch (tag) {
        case SMALL_ATOM_UTF8_EXT: case SMALL_ATOM_EXT: need(1); bytes(u8()); return;
        case ATOM_UTF8_EXT: case ATOM_EXT: need(2); bytes(u16()); return;
        default: throw new DecodeException("invalid_encoding", tag);
      }
    }

    Object list(long count, int depth) throws DecodeException {
      checkLength(count, limits);
      List<Object> items = new ArrayList<>((int) Math.min(count, end - pos));
      for (long i = 0; i < count; i++) items.add(term(depth + 1));
      need(1);
      if ((data[pos] & 0xff) == NIL_EXT) {
        pos++;
        return items;
      }
      return new ImproperList(items, term(depth + 1));
    }

    Tuple tuple(long count, int depth) throws DecodeException {
      checkLength(count, limits);
      List<Object> items = new ArrayList<>((int) Math.min(count, end - pos));
      for (long i = 0; i < count; i++) items.add(term(depth + 1));
      return new Tuple(items);
    }

    Object big(long n) throws DecodeException {
      need(1 + n);
      int sign = u8();
      byte[] digits = bytes(n);
      byte[] magnitude = new byte[digits.length];
      for (int i = 0; i < digits.length; i++) magnitude[i] = digits[digits.length - 1 - i];
      BigInteger value = new BigInteger(1, magnitude);
      return Values.normalizeInteger(sign != 0 ? value.negate() : value);
    }

    Object map(long count, int depth) throws DecodeException {
      checkLength(count, limits);
      List<Object> keys = new ArrayList<>();
      List<Object> values = new ArrayList<>();
      for (long i = 0; i < count; i++) {
        Object key = term(depth + 1);
        keys.add(key);
        if (DATA_KEY.equals(key) && pos < end && (data[pos] & 0xff) == BINARY_EXT) {
          pos++;
          need(4);
          values.add(new RawBinary(bytes(u32())));
        } else {
          values.add(term(depth + 1));
        }
      }

      // A %Portals.Codec.Bin{} struct comes back as byte[], whatever its key order.
      if (count == 2) {
        int structAt = keys.indexOf(STRUCT_KEY);
        int dataAt = keys.indexOf(DATA_KEY);
        if (structAt >= 0 && dataAt >= 0 && BIN_STRUCT.equals(values.get(structAt))
            && values.get(dataAt) instanceof RawBinary raw) {
          return raw.data();
        }
      }

      // Keys become text, as under MessagePack.
      Map<String, Object> result = new LinkedHashMap<>();
      for (int i = 0; i < keys.size(); i++) {
        Object value = values.get(i);
        if (value instanceof RawBinary raw) {
          checkDepth(depth + 1, limits);
          value = text(raw.data());
        }
        result.put(keyText(keys.get(i)), value);
      }
      return result;
    }
  }

  private static String keyText(Object key) throws DecodeException {
    if (key instanceof String s) return s;
    if (key instanceof Atom atom) return atom.name();
    if (key instanceof Long || key instanceof BigInteger) return key.toString();
    // nil/true/false decoded as null/Boolean: their to_string/1 text, as
    // the BEAM's MessagePack encoder sends them.
    if (key == null) return "";
    if (key instanceof Boolean b) return b.toString();
    throw new DecodeException("invalid_encoding", "unsupported map key " + key);
  }

  private static String text(byte[] payload) throws DecodeException {
    try {
      return strictUtf8(payload);
    } catch (CharacterCodingException e) {
      throw new DecodeException("invalid_encoding", "binary is not UTF-8");
    }
  }

  private static String strictUtf8(byte[] payload) throws CharacterCodingException {
    CharBuffer chars = StandardCharsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(payload));
    return chars.toString();
  }

  private static void checkDepth(int depth, Limits limits) throws DecodeException {
    if (depth > limits.maxNestingDepth()) throw new DecodeException("max_depth_exceeded", depth);
  }

  private static void checkLength(long count, Limits limits) throws DecodeException {
    if (count > limits.maxCollectionLength()) throw new DecodeException("max_length_exceeded", count);
  }
}
