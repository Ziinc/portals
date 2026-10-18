package portals;

/** A {@link Portals#callback} did not complete within its timeout. */
public class CallbackTimeoutException extends PortalsException {
  public CallbackTimeoutException(String message) {
    super(message);
  }
}
