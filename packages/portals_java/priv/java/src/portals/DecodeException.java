package portals;

/**
 * Raised for every codec-level failure, on encode and decode alike: never a
 * generic exception, and never anything that escapes past the offending
 * connection. {@link #reason()} is the rejection class the conformance
 * fixtures name ({@code truncated}, {@code invalid_encoding}, ...).
 */
public final class DecodeException extends Exception {
  private final String reason;
  private final transient Object detail;

  public DecodeException(String reason, Object detail) {
    super(reason + ": " + detail);
    this.reason = reason;
    this.detail = detail;
  }

  public String reason() {
    return reason;
  }

  public Object detail() {
    return detail;
  }
}
