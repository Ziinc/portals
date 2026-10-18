package portals;

/** A finite stream send/receive timeout elapsed without progress. */
public class StreamTimeoutException extends PortalsException {
  public StreamTimeoutException(String message) {
    super(message);
  }
}
