package portals;

/** Thrown when sending on a cancelled/terminated stream, or on a direction this side already half-closed. */
public class StreamClosedException extends PortalsException {
  public StreamClosedException(String message) {
    super(message);
  }
}
