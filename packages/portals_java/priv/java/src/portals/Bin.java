package portals;

/**
 * Forces byte-buffer encoding: MessagePack {@code bin} (protocol/v1.md
 * §5.2), or a {@code %Portals.Codec.Bin{}} struct under ETF (§5.4). A plain
 * {@code byte[]} already encodes that way and decoded byte buffers always
 * come back as {@code byte[]}; this wrapper exists for callers that want an
 * immutable, value-comparable binary.
 */
public final class Bin {
  private final byte[] data;

  public Bin(byte[] data) {
    this.data = data.clone();
  }

  public byte[] data() {
    return data.clone();
  }

  byte[] dataUnsafe() {
    return data;
  }

  @Override
  public boolean equals(Object other) {
    return other instanceof Bin bin && java.util.Arrays.equals(bin.data, data);
  }

  @Override
  public int hashCode() {
    return java.util.Arrays.hashCode(data);
  }
}
