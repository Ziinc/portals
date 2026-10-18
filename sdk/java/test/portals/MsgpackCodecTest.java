package portals;

import static portals.TestSupport.assertEquals;
import static portals.TestSupport.assertThrows;
import static portals.TestSupport.assertTrue;

import java.math.BigInteger;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Mirrors {@code sdk/ruby/test/test_msgpack_codec.rb} and the Python/Node
 * codec tests, so every SDK's codec is held to the same contract.
 */
public final class MsgpackCodecTest {
  private MsgpackCodecTest() {}

  static Object roundTrip(Object envelope) throws DecodeException {
    byte[] encoded = MsgpackCodec.encode(envelope, Limits.DEFAULT);
    MsgpackCodec.Decoded decoded = MsgpackCodec.decode(encoded, Limits.DEFAULT);
    assertEquals(0, decoded.restLength());
    return decoded.term();
  }

  public static void testPrimitives() throws Exception {
    assertEquals(Arrays.asList(null, true, false), roundTrip(Arrays.asList(null, true, false)));
  }

  public static void testIntsIncludingBigints() throws Exception {
    List<Object> values = List.of(0L, 1L, 127L, 128L, 255L, 256L, 65_535L, 65_536L, -1L, -32L, -33L, -128L,
        -129L, -32_768L, -32_769L, Long.MAX_VALUE, Long.MIN_VALUE);
    assertEquals(values, roundTrip(values));

    BigInteger huge = new BigInteger("170141183460469231731687303715884105728");
    assertEquals(List.of(huge, huge.negate()), roundTrip(List.of(huge, huge.negate())));

    // The full unsigned 64-bit range is a plain uint64, not a bigint.
    BigInteger maxU64 = BigInteger.ONE.shiftLeft(64).subtract(BigInteger.ONE);
    byte[] encoded = MsgpackCodec.encode(List.of(maxU64));
    assertEquals(0xcf, encoded[1] & 0xff);
    assertEquals(List.of(maxU64), roundTrip(List.of(maxU64)));
  }

  public static void testSmallestIntegerEncodings() throws Exception {
    assertEquals(1, MsgpackCodec.encode(5).length);
    assertEquals(1, MsgpackCodec.encode(-5).length);
    assertEquals(2, MsgpackCodec.encode(200).length);
    assertEquals(3, MsgpackCodec.encode(-200).length);
    // Below -2^40 the reference codec switches to the bigint extension.
    byte[] big = MsgpackCodec.encode(-(1L << 41));
    assertEquals(0xc7, big[0] & 0xff);
    assertEquals(MsgpackCodec.EXT_BIGINT, (int) big[2]);
  }

  public static void testIntegersDecodeAsLong() throws Exception {
    Object decoded = roundTrip(List.of(7));
    assertTrue(((List<?>) decoded).get(0) instanceof Long, "ints decode as Long");
  }

  public static void testFloat() throws Exception {
    assertEquals(List.of(1.5), roundTrip(List.of(1.5)));
    Object decoded = ((List<?>) roundTrip(List.of(2.0))).get(0);
    assertTrue(decoded instanceof Double, "an integral double stays a float");
  }

  public static void testStrAndBytesAreDistinct() throws Exception {
    List<?> decoded = (List<?>) roundTrip(List.of("hello", new byte[] {0, 1, 2}));
    assertEquals("hello", decoded.get(0));
    assertTrue(decoded.get(1) instanceof byte[], "bin decodes to byte[]");
    assertEquals(new byte[] {0, 1, 2}, decoded.get(1));
    assertEquals(0xc4, MsgpackCodec.encode(new Bin(new byte[] {9}))[0] & 0xff);
  }

  public static void testTuple() throws Exception {
    Tuple tuple = Tuple.of(1L, "a", null);
    assertEquals(List.of(tuple), roundTrip(List.of(tuple)));
  }

  public static void testAtomRoundTrips() throws Exception {
    assertEquals(List.of(new Atom("ok")), roundTrip(List.of(new Atom("ok"))));
  }

  public static void testPidAndReferenceAreOpaqueRoundTrip() throws Exception {
    Pid pid = new Pid("\u0083pid_bytes".getBytes());
    Ref ref = new Ref("\u0083ref_bytes".getBytes());
    assertEquals(List.of(pid, ref), roundTrip(List.of(pid, ref)));
  }

  public static void testImproperList() throws Exception {
    ImproperList value = new ImproperList(List.of(1L, 2L), new Atom("tail"));
    assertEquals(List.of(value), roundTrip(List.of(value)));
  }

  public static void testNestedMap() throws Exception {
    Map<String, Object> term = new LinkedHashMap<>();
    term.put("a", 1L);
    term.put("b", List.of(1L, 2L, 3L));
    term.put("c", Map.of("nested", true));
    assertEquals(List.of(term), roundTrip(List.of(term)));
  }

  public static void testCallAndHelloEnvelopeShapes() throws Exception {
    List<Object> hello = List.of((long) Protocol.HELLO, 1L, "java21", 16L, 0L, List.of());
    assertEquals(hello, roundTrip(hello));

    List<Object> call = List.of((long) Protocol.CALL, 1L, "bench_worker", "echo", List.of("hello"));
    assertEquals(call, roundTrip(call));
  }

  public static void testMaxFrameSizeEnforced() {
    Limits tight = Limits.DEFAULT.merge(Map.of("max_frame_size", 4));
    DecodeException error = assertThrows(DecodeException.class,
        () -> MsgpackCodec.encode(List.of("much too long a string"), tight));
    assertEquals("max_size_exceeded", error.reason());
  }

  public static void testNestingDepthEnforced() {
    Limits tight = Limits.DEFAULT.merge(Map.of("max_nesting_depth", 2));
    Object deep = List.of(List.of(List.of(List.of(1))));
    assertEquals("max_depth_exceeded",
        assertThrows(DecodeException.class, () -> MsgpackCodec.encode(deep, tight)).reason());
  }

  public static void testTruncatedFrameRaisesDecodeError() {
    DecodeException error = assertThrows(DecodeException.class,
        () -> MsgpackCodec.decode(new byte[] {(byte) 0x91}, Limits.DEFAULT));
    assertEquals("truncated", error.reason());
  }

  public static void testUnknownLeadingByteIsInvalidEncoding() {
    DecodeException error = assertThrows(DecodeException.class,
        () -> MsgpackCodec.decode(new byte[] {(byte) 0xc1}, Limits.DEFAULT));
    assertEquals("invalid_encoding", error.reason());
  }

  public static void testOversizedCollectionIsRejected() {
    byte[] bytes = {(byte) 0xdd, (byte) 0xff, (byte) 0xff, (byte) 0xff, (byte) 0xff};
    DecodeException error = assertThrows(DecodeException.class, () -> MsgpackCodec.decode(bytes, Limits.DEFAULT));
    assertEquals("max_length_exceeded", error.reason());
  }

  public static void testInvalidExtensions() {
    byte[] unknownType = {(byte) 0xd4, 99, 0};
    assertEquals("invalid_extension",
        assertThrows(DecodeException.class, () -> MsgpackCodec.decode(unknownType)).reason());

    byte[] tupleTrailing = {(byte) 0xc7, 2, 0, (byte) 0x90, 0x01};
    assertEquals("invalid_extension",
        assertThrows(DecodeException.class, () -> MsgpackCodec.decode(tupleTrailing)).reason());

    byte[] badUtf8Atom = {(byte) 0xd4, 1, (byte) 0xff};
    assertEquals("invalid_extension",
        assertThrows(DecodeException.class, () -> MsgpackCodec.decode(badUtf8Atom)).reason());
  }

  public static void testLargeBinaryRoundTrips() throws Exception {
    byte[] blob = new byte[70_000];
    List<?> decoded = (List<?>) roundTrip(List.of((long) Protocol.RETURN, 1L, blob));
    assertEquals(blob, decoded.get(2));
  }

  public static void testReturnEnvelopeRoundTrip() throws Exception {
    List<Object> envelope = List.of((long) Protocol.RETURN, 42L, Map.of("ok", true));
    assertEquals(envelope, roundTrip(envelope));
  }

  public static void testDecodeEnvelopeRejectsTrailingBytes() {
    byte[] bytes = {(byte) 0x91, 0x01, 0x02};
    assertEquals("trailing_bytes",
        assertThrows(DecodeException.class, () -> MsgpackCodec.decodeEnvelope(bytes, Limits.DEFAULT)).reason());
  }
}
