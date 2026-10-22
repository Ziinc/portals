package portals;

import java.util.List;

/**
 * Portals Java worker SDK: the helpers a handler calls from inside a
 * {@code CALL}.
 *
 * <p>Full parity with the Python, Ruby and Node SDKs: Unix-socket transport
 * with a framed stdio fallback, dependency-free Erlang External Term Format
 * (the default) and MessagePack codecs selected by {@code PORTALS_CODEC},
 * the exact-version HELLO/READY
 * handshake, concurrent arbitrary module/function dispatch, structured
 * error frames, reentrant callbacks, PID messaging, cooperative
 * cancellation, and bidirectional streaming with byte-credit windows,
 * frame-count caps and per-direction half-close. See {@code protocol/v1.md}.
 */
public final class Portals {
  private Portals() {}

  public static final String VERSION = "0.1.0";
  public static final int PROTOCOL_VERSION = Protocol.PROTOCOL_VERSION;

  /**
   * Invokes a BEAM callback from within a {@code CALL} handler and blocks
   * this handler's thread (never the socket reader) for its result.
   *
   * @throws RemoteException when the BEAM-side handler fails
   */
  public static Object callback(String module, String function, List<?> args) throws InterruptedException {
    return callback(module, function, args, -1);
  }

  /** Like {@link #callback(String, String, List)}, giving up after {@code timeoutMs}. */
  public static Object callback(String module, String function, List<?> args, long timeoutMs)
      throws InterruptedException {
    return requireWorker("callback").callCallback(module, function, args, timeoutMs);
  }

  /**
   * Sends a value to a BEAM PID (typically one received as a {@code CALL}
   * argument). Fire-and-forget.
   */
  public static void sendMessage(Pid target, Object value) {
    requireWorker("sendMessage").sendMessage(target, value);
  }

  /** The reentrancy depth of the {@code CALL} executing on this thread. */
  public static long currentCallbackDepth() {
    return Worker.currentCallbackDepth();
  }

  /** The deadline (ms) the BEAM attached to the current {@code CALL}, or null. */
  public static Long currentDeadlineMs() {
    Worker.CallContext context = Worker.CONTEXT.get();
    return context == null ? null : context.deadlineMs;
  }

  /**
   * Cooperative cancellation: true once the BEAM sent {@code CANCEL} for the
   * call executing on this thread. Portals never force-kills a handler.
   */
  public static boolean isCancelled() {
    Worker.CallContext context = Worker.CONTEXT.get();
    return context != null && context.cancelled.get();
  }

  private static Worker requireWorker(String name) {
    Worker worker = Worker.active();
    if (worker == null) throw new IllegalStateException("Portals." + name + " called with no active Worker in this process");
    return worker;
  }
}
