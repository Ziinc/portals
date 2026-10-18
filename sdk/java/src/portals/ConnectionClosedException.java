package portals;

import java.io.IOException;

/** The peer closed the connection (cleanly between frames or mid-frame). */
public class ConnectionClosedException extends IOException {
  public ConnectionClosedException(String message) {
    super(message);
  }
}
