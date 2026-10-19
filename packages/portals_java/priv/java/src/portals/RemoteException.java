package portals;

import java.util.Map;

/** Thrown by {@link Portals#callback} when the BEAM-side handler fails. */
public class RemoteException extends PortalsException {
  private final transient Map<?, ?> errorMap;

  public RemoteException(Map<?, ?> errorMap) {
    super(errorMap != null && errorMap.get("message") != null
        ? String.valueOf(errorMap.get("message"))
        : "callback failed");
    this.errorMap = errorMap;
  }

  /** The {@code CALLBACK_ERROR} error map as the BEAM sent it. */
  public Map<?, ?> errorMap() {
    return errorMap;
  }
}
