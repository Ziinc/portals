package portals.fixtures;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import portals.Atom;
import portals.Pid;
import portals.Portals;
import portals.Stream;
import portals.StreamHandler;
import portals.Tuple;

/**
 * Function targets used by the Elixir integration tests — the Java mirror of
 * {@code packages/portals_python/priv/python/tests/fixtures/bench_worker.py}. Wire names are
 * snake_case ({@code sleep_ms}); the worker maps them onto these camelCase
 * methods.
 */
public final class BenchWorker {
  private BenchWorker() {}

  private static final String CALLBACK_TARGET = "Elixir.Portals.Fixtures.CallbackTarget";

  public static Object echo(Object value) {
    return value;
  }

  public static long add(long a, long b) {
    return a + b;
  }

  public static Object raiseError(String message) {
    throw new IllegalStateException(message);
  }

  public static long sleepMs(long ms) throws InterruptedException {
    Thread.sleep(ms);
    return ms;
  }

  public static Object crashProcess() {
    Runtime.getRuntime().halt(1);
    return null;
  }

  /** Calls back into the BEAM to double a number: a reentrant round trip. */
  public static Object doubleViaCallback(long n) throws InterruptedException {
    return Portals.callback(CALLBACK_TARGET, "double", List.of(n));
  }

  /**
   * A callback target the Elixir side invokes; while running (still inside
   * the BEAM-side callback handler) it reports the reentrancy depth the
   * BEAM echoed back on this nested CALL.
   */
  public static Map<String, Object> nestedCallThenCallback(Object connMarker, long n) {
    Map<String, Object> result = new LinkedHashMap<>();
    result.put("depth_seen", Portals.currentCallbackDepth());
    result.put("doubled", n * 2);
    return result;
  }

  public static long callbackDepthProbe() {
    return Portals.currentCallbackDepth();
  }

  public static Long deadlineProbe() {
    return Portals.currentDeadlineMs();
  }

  public static String messageToCaller(Pid pid, Object value) {
    Portals.sendMessage(pid, value);
    return "sent";
  }

  public static Object raiseCallbackError() throws InterruptedException {
    return Portals.callback(CALLBACK_TARGET, "boom", List.of());
  }

  // -- Value-model probes: the Erlang extensions survive Java untouched. ----

  public static Object echoTerm(Object value) {
    return value;
  }

  public static String describeTerm(Object value) {
    return value == null ? "null" : value.getClass().getName();
  }

  public static Tuple makeTuple(List<Object> items) {
    return new Tuple(items);
  }

  public static Atom makeAtom(String text) {
    return new Atom(text);
  }

  /** Cooperative cancellation: polls the flag the CANCEL frame raises. */
  public static String cancellable(long ms) throws InterruptedException {
    long deadline = System.nanoTime() + ms * 1_000_000L;
    while (System.nanoTime() < deadline) {
      if (Portals.isCancelled()) return "cancelled";
      Thread.sleep(5);
    }
    return "completed";
  }

  // -- Streaming targets ----------------------------------------------------

  /** Echo every inbound chunk back out, then terminate with a count. */
  @StreamHandler
  public static long echoStream(Stream stream) throws InterruptedException {
    long count = 0;
    for (Object chunk : stream) {
      stream.send(chunk);
      count++;
    }
    return count;
  }

  /** Produce {@code count} chunks of {@code size} bytes, blocking on credit. */
  @StreamHandler
  public static long produceStream(Stream stream, long count, long size) throws InterruptedException {
    String payload = "x".repeat((int) size);
    for (long i = 0; i < count; i++) stream.send(payload, 10_000);
    stream.halfClose();
    return count;
  }

  /** Consume everything the BEAM sends, optionally slowly. */
  @StreamHandler
  public static Map<String, Object> drainStream(Stream stream) throws InterruptedException {
    return drainStream(stream, 0);
  }

  @StreamHandler
  public static Map<String, Object> drainStream(Stream stream, long delayMs) throws InterruptedException {
    long chunks = 0;
    long bytes = 0;
    for (Object chunk : stream) {
      chunks++;
      bytes += chunk instanceof byte[] raw ? raw.length : String.valueOf(chunk).getBytes(StandardCharsets.UTF_8).length;
      if (delayMs > 0) Thread.sleep(delayMs);
    }
    Map<String, Object> result = new LinkedHashMap<>();
    result.put("chunks", chunks);
    result.put("bytes", bytes);
    return result;
  }

  /**
   * Never consume inbound chunks: the BEAM's sender must block on the
   * credit window rather than grow BEAM memory.
   */
  @StreamHandler
  public static String neverConsume(Stream stream, long holdMs) throws InterruptedException {
    Thread.sleep(holdMs);
    return "held";
  }

  /**
   * Close only the worker's sending direction immediately, then keep
   * consuming — proving half-close is per-direction.
   */
  @StreamHandler
  public static long halfCloseThenDrain(Stream stream) {
    stream.halfClose();
    long chunks = 0;
    for (Object ignored : stream) chunks++;
    return chunks;
  }

  /** Keep a stream (and a stream slot) busy without doing anything. */
  @StreamHandler
  public static String holdStream(Stream stream, long holdMs) throws InterruptedException {
    Thread.sleep(holdMs);
    return "done";
  }
}
