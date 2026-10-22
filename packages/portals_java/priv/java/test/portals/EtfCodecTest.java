package portals;

import static portals.TestSupport.assertEquals;
import static portals.TestSupport.assertThrows;
import static portals.TestSupport.assertTrue;

import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HexFormat;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Mirrors {@code packages/portals_python/priv/python/tests/test_etf_codec.py}
 * (same BEAM-produced bytes), so every SDK's ETF codec is held to the same
 * contract.
 */
public final class EtfCodecTest {
  private EtfCodecTest() {}

  // :erlang.term_to_binary/1 of
  //   [3, 7, "héllo", %{"k" => [1, -2, 300, 2_147_483_648, -(2**70)]},
  //    {:ok, nil, true, false}, 1.5, [], ~c"ab", [1 | 2],
  //    %Portals.Codec.Bin{data: <<0, 255>>}]
  static final byte[] BEAM_BYTES = hex(
      "836c0000000a610361076d0000000668c3a96c6c6f74000000016d000000016b6c00000005610162fffffffe"
      + "620000012c6e0400000000806e09010000000000000000406a68046400026f6b6400036e696c640004747275"
      + "6564000566616c7365463ff80000000000006a6b000261626c0000000161016102740000000264000a5f5f73"
      + "74727563745f5f640018456c697869722e506f7274616c732e436f6465632e42696e640004646174616d0000"
      + "000200ff6a");

  static final List<Object> BEAM_TERM = Arrays.asList(
      3L,
      7L,
      "héllo",
      Map.of("k", List.of(1L, -2L, 300L, 2_147_483_648L, BigInteger.TWO.pow(70).negate())),
      Tuple.of(new Atom("ok"), null, true, false),
      1.5,
      List.of(),
      List.of(97L, 98L),
      new ImproperList(List.of(1L), 2L),
      new byte[] {0, (byte) 0xff});

  // self() and make_ref() from a BEAM, as NEW_PID_EXT / NEWER_REFERENCE_EXT.
  static final byte[] PID = hex("5864000d6e6f6e6f6465406e6f686f73740000005e0000000000000000");
  static final byte[] REF = hex("5a000364000d6e6f6e6f6465406e6f686f73740000000000008033634c0004263763cf");

  static byte[] hex(String digits) {
    return HexFormat.of().parseHex(digits);
  }

  static Object roundTrip(Object envelope) throws DecodeException {
    byte[] encoded = EtfCodec.encode(envelope, Limits.DEFAULT);
    EtfCodec.Decoded decoded = EtfCodec.decode(encoded, Limits.DEFAULT);
    assertEquals(0, decoded.restLength());
    return decoded.term();
  }

  static String reason(byte[] bytes) {
    return assertThrows(DecodeException.class, () -> EtfCodec.decode(bytes, Limits.DEFAULT)).reason();
  }

  public static void testDecodesWhatTheBeamEncodes() throws Exception {
    EtfCodec.Decoded decoded = EtfCodec.decode(BEAM_BYTES);
    assertEquals(BEAM_TERM, decoded.term());
    assertEquals(0, decoded.restLength());
    assertEquals(BEAM_TERM, EtfCodec.decodeEnvelope(BEAM_BYTES, Limits.DEFAULT));
  }

  public static void testRoundTripsEveryValueType() throws Exception {
    Map<String, Object> values = new LinkedHashMap<>();
    values.put("none", null);
    values.put("bools", List.of(true, false));
    values.put("ints", List.of(0L, 255L, 256L, -1L, 1L << 31, -(1L << 31) - 1, Long.MAX_VALUE, Long.MIN_VALUE,
        BigInteger.TWO.pow(64), BigInteger.TWO.pow(2100).negate()));
    values.put("float", -0.25);
    values.put("text", "naïve ✓");
    values.put("bytes", new byte[] {0, 1, (byte) 0xfe});
    values.put("empty", new byte[0]);
    values.put("atom", new Atom("ok"));
    values.put("long_atom", new Atom("ä".repeat(200)));
    values.put("tuple", Tuple.of(1L, "two", Tuple.of(3L)));
    values.put("improper", new ImproperList(List.of(1L, 2L), "tail"));
    values.put("nested", Map.of("a", List.of(Map.of("b", List.of()))));
    values.put("pid", new Pid(PID));
    values.put("ref", new Ref(REF));
    List<Object> envelope = List.of(4L, 1L, values);
    assertEquals(envelope, roundTrip(envelope));
  }

  public static void testHostTypesEncodeAsTheirWireEquivalents() throws Exception {
    List<Object> in = List.of(7, (short) 8, (byte) 9, 1.5f, new Bin(new byte[] {1}),
        java.nio.ByteBuffer.wrap(new byte[] {2}), new Object[] {"x"}, Codec.ETF);
    List<Object> out = List.of(7L, 8L, 9L, 1.5, new byte[] {1}, new byte[] {2}, List.of("x"), new Atom("ETF"));
    assertEquals(out, roundTrip(in));
    assertEquals("invalid_encoding",
        assertThrows(DecodeException.class, () -> EtfCodec.encode(List.of(new Object()))).reason());
  }

  public static void testIntegerEncodings() throws Exception {
    assertEquals(EtfCodec.SMALL_INTEGER_EXT, EtfCodec.encode(255L)[1] & 0xff);
    assertEquals(EtfCodec.INTEGER_EXT, EtfCodec.encode(256L)[1] & 0xff);
    assertEquals(EtfCodec.INTEGER_EXT, EtfCodec.encode(-1L)[1] & 0xff);
    assertEquals(EtfCodec.INTEGER_EXT, EtfCodec.encode((long) Integer.MIN_VALUE)[1] & 0xff);
    // 2^31: sign 0, magnitude little-endian.
    assertEquals(hex("836e040000000080"), EtfCodec.encode(1L << 31));
    assertEquals(hex("836e040101000080"), EtfCodec.encode(-(1L << 31) - 1));
    assertEquals(EtfCodec.LARGE_BIG_EXT, EtfCodec.encode(BigInteger.TWO.pow(2100))[1] & 0xff);
    // Small bigints narrow back to Long, as under MessagePack.
    assertEquals(5L, EtfCodec.decode(hex("836e010005")).term());
  }

  public static void testEncodesWhatTheBeamEncodes() throws Exception {
    // [1 | 2], as the golden bytes spell it.
    assertEquals(hex("836c0000000161016102"), EtfCodec.encode(new ImproperList(List.of(1L), 2L)));
    // %Portals.Codec.Bin{data: <<0, 255>>}, with SMALL_ATOM_UTF8_EXT keys (spec 5.4).
    assertEquals(hex("837400000002" + "770a5f5f7374727563745f5f" + "7718456c697869722e506f7274616c732e436f6465632e42696e"
        + "770464617461" + "6d0000000200ff"), EtfCodec.encode(new byte[] {0, (byte) 0xff}));
    assertEquals(hex("836a"), EtfCodec.encode(List.of()));
    assertEquals(hex("8368037703616263770474727565" + "77036e696c"),
        EtfCodec.encode(Tuple.of(new Atom("abc"), true, null)));
    assertEquals(hex("837400000001" + "6d000000016b" + "6d0000000176"),
        EtfCodec.encode(Map.of("k", "v")));
  }

  public static void testPidsAndReferencesAreOpaqueAndWrittenBackVerbatim() throws Exception {
    byte[] data = new byte[6 + PID.length + REF.length + 1];
    System.arraycopy(new byte[] {(byte) 131, 108, 0, 0, 0, 2}, 0, data, 0, 6);
    System.arraycopy(PID, 0, data, 6, PID.length);
    System.arraycopy(REF, 0, data, 6 + PID.length, REF.length);
    data[data.length - 1] = 106;

    Object term = EtfCodec.decode(data).term();
    assertEquals(List.of(new Pid(PID), new Ref(REF)), term);
    assertEquals(data, EtfCodec.encode(term));
  }

  public static void testBinStructDecodesToBytesInEitherKeyOrder() throws Exception {
    // %{data: <<1>>, __struct__: Portals.Codec.Bin}, keys swapped.
    byte[] swapped = hex("837400000002" + "64000464617461" + "6d0000000101"
        + "64000a5f5f7374727563745f5f" + "640018456c697869722e506f7274616c732e436f6465632e42696e");
    assertEquals(new byte[] {1}, EtfCodec.decode(swapped).term());
  }

  public static void testADataKeyOutsideABinStructStaysText() throws Exception {
    Map<Object, Object> map = new LinkedHashMap<>();
    map.put(new Atom("data"), "x");
    map.put(new Atom("other"), 1L);
    Map<String, Object> expected = new LinkedHashMap<>();
    expected.put("data", "x");
    expected.put("other", 1L);
    assertEquals(List.of(expected), roundTrip(List.of(map)));

    // %{data: "x"} with one key is not a Bin struct either.
    Map<Object, Object> single = Map.of(new Atom("data"), "x");
    assertEquals(List.of(Map.of("data", "x")), roundTrip(List.of(single)));
  }

  public static void testMapKeysBecomeTextAsUnderMessagePack() throws Exception {
    // %{a: 1, 2 => 3, "s" => 4, nil => 5} from a BEAM.
    byte[] beam = hex("837400000004610261036400016161016400036e696c61056d00000001736104");
    assertEquals(Map.of("2", 3L, "a", 1L, "s", 4L, "", 5L), EtfCodec.decode(beam).term());

    Map<Object, Object> map = new LinkedHashMap<>();
    map.put(1L, "x");
    map.put(new Atom("k"), "y");
    map.put(true, "z");
    assertEquals(List.of(Map.of("1", "x", "k", "y", "true", "z")), roundTrip(List.of(map)));

    // %{1.5 => 1}: no text form, as under MessagePack's decoders.
    assertEquals("invalid_encoding", reason(hex("837400000001463ff80000000000006101")));
  }

  public static void testMalformedInputIsRejectedWithAReason() throws Exception {
    assertEquals("truncated", reason(new byte[0]));
    assertEquals("invalid_encoding", reason(new byte[] {0}));
    for (int n = 1; n < BEAM_BYTES.length; n++) {
      assertEquals("truncated", reason(Arrays.copyOf(BEAM_BYTES, n)));
    }
    assertEquals("invalid_encoding", reason(new byte[] {(byte) 131, 77}));
    assertEquals("invalid_encoding", reason(new byte[] {(byte) 131, 109, 0, 0, 0, 1, (byte) 0xff}));
    assertEquals("invalid_encoding", reason(new byte[] {(byte) 131, 119, 1, (byte) 0xff}));
    assertEquals("invalid_encoding", reason(new byte[] {(byte) 131, 118, 0, 2, (byte) 0xc3, 0x28}));
    // Latin-1 atoms have no invalid bytes.
    assertEquals(new Atom("é"), EtfCodec.decode(new byte[] {(byte) 131, 115, 1, (byte) 0xe9}).term());
    assertEquals("invalid_encoding", reason(new byte[] {(byte) 131, (byte) 200}));
    // A PID whose node is not an atom.
    assertEquals("invalid_encoding", reason(new byte[] {(byte) 131, 88, 97, 1}));
  }

  public static void testMalformedFixturesAreClassifiedLikeEverySdk() throws Exception {
    // protocol/malformed/etf_fixtures.exs with SDKSuite.expected_reasons(:etf).
    assertEquals("truncated", reason(new byte[0]));
    assertEquals("invalid_encoding", reason(new byte[] {108, 0, 0, 0, 1, 97, 1, 106}));
    assertEquals("truncated", reason(new byte[] {(byte) 131, 108, 0, 0, 0, 3, 97, 1}));
    assertEquals("truncated", reason(hex("836d0000000a73686f7274")));
    assertEquals("max_length_exceeded", reason(hex("836cffffffff")));
    assertEquals(new Atom("not_a_real_atom_xyzq"),
        EtfCodec.decode(concat(hex("837714"), "not_a_real_atom_xyzq".getBytes(StandardCharsets.UTF_8))).term());
    assertEquals(1, EtfCodec.decode(new byte[] {(byte) 131, 97, 1, 0}).restLength());
    assertEquals("trailing_bytes", assertThrows(DecodeException.class,
        () -> EtfCodec.decodeEnvelope(hex("836c00000001610161016a00"), Limits.DEFAULT)).reason());
    assertEquals("invalid_encoding", reason(hex("836d00000002c328")));
    assertEquals("invalid_encoding", reason(hex("834d0000000103e0")));

    byte[] deep = new byte[1 + 40 * 5 + 2 + 40];
    deep[0] = (byte) 131;
    for (int i = 0; i < 40; i++) System.arraycopy(new byte[] {108, 0, 0, 0, 1}, 0, deep, 1 + 5 * i, 5);
    deep[201] = 97;
    deep[202] = 1;
    Arrays.fill(deep, 203, deep.length, (byte) 106);
    assertEquals("max_depth_exceeded", reason(deep));

    assertEquals("truncated", reason(concat(hex("836c00000003610b61076d00000010"), "short".getBytes(StandardCharsets.UTF_8))));
  }

  static byte[] concat(byte[] a, byte[] b) {
    byte[] out = Arrays.copyOf(a, a.length + b.length);
    System.arraycopy(b, 0, out, a.length, b.length);
    return out;
  }

  public static void testDecodeEnvelopeRejectsNonLists() {
    assertEquals("invalid_envelope", assertThrows(DecodeException.class,
        () -> EtfCodec.decodeEnvelope(new byte[] {(byte) 131, 97, 1}, Limits.DEFAULT)).reason());
    assertEquals("invalid_envelope", assertThrows(DecodeException.class,
        () -> EtfCodec.decodeEnvelope(new byte[] {(byte) 131, 106}, Limits.DEFAULT)).reason());
  }

  public static void testEnforcesLimits() throws Exception {
    Limits tight = Limits.DEFAULT.merge(Map.of(
        "max_frame_size", 1024, "max_nesting_depth", 2, "max_collection_length", 3));

    assertEquals("max_depth_exceeded", assertThrows(DecodeException.class,
        () -> EtfCodec.encode(List.of(List.of(List.of(List.of(1L)))), tight)).reason());
    assertEquals("max_length_exceeded", assertThrows(DecodeException.class,
        () -> EtfCodec.encode(List.of(List.of(1L, 2L, 3L, 4L)), tight)).reason());
    assertEquals("max_length_exceeded", assertThrows(DecodeException.class,
        () -> EtfCodec.encode(Tuple.of(1L, 2L, 3L, 4L), tight)).reason());
    assertEquals("max_size_exceeded", assertThrows(DecodeException.class,
        () -> EtfCodec.encode(List.of("x".repeat(2000)), tight)).reason());

    byte[] deep = EtfCodec.encode(List.of(List.of(List.of(List.of(1L)))));
    assertEquals("max_depth_exceeded", assertThrows(DecodeException.class,
        () -> EtfCodec.decode(deep, tight)).reason());
    byte[] wide = EtfCodec.encode(Map.of("a", 1L, "b", 2L, "c", 3L, "d", 4L));
    assertEquals("max_length_exceeded", assertThrows(DecodeException.class,
        () -> EtfCodec.decode(wide, tight)).reason());
    byte[] large = EtfCodec.encode(List.of("x".repeat(2000)));
    assertEquals("max_size_exceeded", assertThrows(DecodeException.class,
        () -> EtfCodec.decode(large, tight)).reason());
    assertTrue(EtfCodec.decode(EtfCodec.encode(List.of(List.of(1L)), tight), tight).term() instanceof List<?>,
        "within limits decodes");
  }

  public static void testLargeBinaryRoundTrips() throws Exception {
    byte[] blob = new byte[70_000];
    List<?> decoded = (List<?>) roundTrip(List.of((long) Protocol.RETURN, 1L, blob));
    assertEquals(blob, decoded.get(2));
  }

  public static void testCodecSelection() throws Exception {
    assertEquals(Codec.ETF, Codec.fromName(null));
    assertEquals(Codec.ETF, Codec.fromName("etf"));
    assertEquals(Codec.MSGPACK, Codec.fromName("msgpack"));
    IllegalStateException error = assertThrows(IllegalStateException.class, () -> Codec.fromName("json"));
    assertTrue(error.getMessage().contains("PORTALS_CODEC=\"json\""), error.getMessage());
    assertThrows(IllegalStateException.class, () -> Codec.fromName(""));

    List<Object> envelope = List.of((long) Protocol.CALL, 1L, "m", "f", List.of(new byte[] {1}, new Atom("a")));
    for (Codec codec : Codec.values()) {
      byte[] bytes = codec.encode(envelope, Limits.DEFAULT);
      assertEquals(envelope, codec.decodeEnvelope(bytes, Limits.DEFAULT));
      assertEquals(0, codec.decode(bytes, Limits.DEFAULT).restLength());
    }
    assertEquals(EtfCodec.VERSION, Codec.ETF.encode(envelope, Limits.DEFAULT)[0] & 0xff);
  }
}
