package portals;

/** The peer violated the wire protocol (e.g. a bad or mismatched handshake). */
public class ProtocolException extends PortalsException {
  public ProtocolException(String message) {
    super(message);
  }
}
