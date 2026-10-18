package portals;

/** The peer exceeded its documented byte or frame allowance, or a chunk can never fit the window. */
public class StreamProtocolException extends PortalsException {
  public StreamProtocolException(String message) {
    super(message);
  }
}
