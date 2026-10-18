package portals;

import java.util.Arrays;

/**
 * An opaque local or distributed Erlang PID. A trusted worker may store and
 * echo it back (e.g. as a {@code MESSAGE} target) but must never attempt to
 * construct or interpret its bytes.
 */
public final class Pid {
  private final byte[] raw;

  public Pid(byte[] raw) {
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
    return other instanceof Pid pid && Arrays.equals(pid.raw, raw);
  }

  @Override
  public int hashCode() {
    return Arrays.hashCode(raw);
  }

  @Override
  public String toString() {
    return "#Pid<" + raw.length + " bytes>";
  }
}
