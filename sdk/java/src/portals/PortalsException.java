package portals;

/** Base class of the SDK's own runtime exceptions. */
public class PortalsException extends RuntimeException {
  public PortalsException(String message) {
    super(message);
  }

  public PortalsException(String message, Throwable cause) {
    super(message, cause);
  }
}
