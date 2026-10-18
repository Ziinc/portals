package portals;

import java.util.Arrays;

/** An opaque Erlang reference. Same opacity rules as {@link Pid}. */
public final class Ref {
  private final byte[] raw;

  public Ref(byte[] raw) {
    this.raw = raw.clone();
  }

  public byte[] raw() {
    return raw.clone();
  }

  byte[] rawUnsafe() {
    return raw;
  }

  @Override
  public boolean equals(Object other) {
    return other instanceof Ref ref && Arrays.equals(ref.raw, raw);
  }

  @Override
  public int hashCode() {
    return Arrays.hashCode(raw);
  }

  @Override
  public String toString() {
    return "#Reference<" + raw.length + " bytes>";
  }
}
