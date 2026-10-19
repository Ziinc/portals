package portals;

import java.util.List;

/**
 * The wire codec this worker speaks, chosen by the BEAM through the
 * {@code PORTALS_CODEC} environment variable (protocol/v1.md §5.4):
 * {@code etf} (the default when unset) or {@code msgpack}. Every frame in
 * both directions, {@code HELLO} included, goes through the selected codec;
 * handlers never see it, since both decode to the same Java types.
 */
public enum Codec {
  ETF("etf"),
  MSGPACK("msgpack");

  /** The environment variable the BEAM sets for every worker. */
  public static final String ENV = "PORTALS_CODEC";

  private static volatile Codec selected;

  private final String wireName;

  Codec(String wireName) {
    this.wireName = wireName;
  }

  /** The name the BEAM uses for this codec ({@code "etf"} or {@code "msgpack"}). */
  public String wireName() {
    return wireName;
  }

  /**
   * The codec named by {@code PORTALS_CODEC}, read once and then cached.
   *
   * @throws IllegalStateException when it names a codec this SDK does not speak
   */
  public static Codec selected() {
    Codec codec = selected;
    if (codec == null) {
      codec = fromName(System.getenv(ENV));
      selected = codec;
    }
    return codec;
  }

  /** The codec for a {@code PORTALS_CODEC} value; {@code null} (unset) is ETF. */
  public static Codec fromName(String name) {
    if (name == null) return ETF;
    for (Codec codec : values()) {
      if (codec.wireName.equals(name)) return codec;
    }
    throw new IllegalStateException(
        ENV + "=\"" + name + "\" is not a codec this SDK speaks (etf, msgpack)");
  }

  /** A decoded term plus the number of input bytes it consumed. */
  public record Decoded(Object term, int consumed, int length) {
    public int restLength() {
      return length - consumed;
    }
  }

  public byte[] encode(Object envelope, Limits limits) throws DecodeException {
    return this == ETF ? EtfCodec.encode(envelope, limits) : MsgpackCodec.encode(envelope, limits);
  }

  /** Decodes one term from the front of {@code data}. */
  public Decoded decode(byte[] data, Limits limits) throws DecodeException {
    if (this == ETF) {
      EtfCodec.Decoded decoded = EtfCodec.decode(data, limits);
      return new Decoded(decoded.term(), decoded.consumed(), decoded.length());
    }
    MsgpackCodec.Decoded decoded = MsgpackCodec.decode(data, limits);
    return new Decoded(decoded.term(), decoded.consumed(), decoded.length());
  }

  /** Decodes one complete frame envelope: a list with no trailing bytes. */
  public List<Object> decodeEnvelope(byte[] data, Limits limits) throws DecodeException {
    return this == ETF ? EtfCodec.decodeEnvelope(data, limits) : MsgpackCodec.decodeEnvelope(data, limits);
  }
}
