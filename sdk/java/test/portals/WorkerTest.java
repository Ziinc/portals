package portals;

import static portals.TestSupport.assertEquals;
import static portals.TestSupport.assertThrows;
import static portals.TestSupport.assertTrue;

import java.math.BigInteger;
import java.util.List;
import java.util.Map;

/** Target resolution, argument coercion and error mapping. */
public final class WorkerTest {
  private WorkerTest() {}

  public static final class Handlers {
    public static long add(long a, long b) {
      return a + b;
    }

    public static String greet(String name) {
      return "hi " + name;
    }

    public static String greet(String name, String greeting) {
      return greeting + " " + name;
    }

    public static Object fail(String message) {
      throw new IllegalStateException(message);
    }

    @StreamHandler
    public static long count(Stream stream) {
      return 0;
    }
  }

  public static void testWireNamesMapOntoCamelCaseMethods() throws Exception {
    assertEquals("sleepMs", Worker.camelCase("sleep_ms"));
    assertEquals("BenchWorker", Worker.pascalCase("bench_worker"));

    Worker worker = new Worker().register("handlers", Handlers.class);
    assertEquals(3L, worker.resolveTarget("handlers", "add").invoke(null, List.of(1L, 2L)));
  }

  public static void testOverloadsAreChosenByArity() throws Exception {
    Worker worker = new Worker().register("handlers", Handlers.class);
    Worker.Target greet = worker.resolveTarget("handlers", "greet");
    assertEquals("hi bob", greet.invoke(null, List.of("bob")));
    assertEquals("yo bob", greet.invoke(null, List.of("bob", "yo")));
    assertThrows(IllegalArgumentException.class, () -> greet.invoke(null, List.of()));
  }

  public static void testStreamHandlersAreDetected() throws Exception {
    Worker worker = new Worker().register("handlers", Handlers.class);
    assertTrue(worker.resolveTarget("handlers", "count").isStream(), "@StreamHandler is a stream target");
    assertTrue(!worker.resolveTarget("handlers", "add").isStream(), "plain methods are unary");
  }

  public static void testUnknownTargetsFail() {
    Worker worker = new Worker().register("handlers", Handlers.class);
    assertThrows(NoSuchMethodException.class, () -> worker.resolveTarget("handlers", "nope"));
    assertThrows(ClassNotFoundException.class, () -> worker.resolveTarget("no_such_module", "nope"));
  }

  public static void testModulesResolveFromPackages() throws Exception {
    Worker worker = new Worker().modulePackage("portals");
    assertEquals("portals_worker_test",
        worker.resolveTarget("worker_test", "probe").invoke(null, List.of()));
  }

  public static String probe() {
    return "portals_worker_test";
  }

  public static void testLambdaRegistration() throws Exception {
    Worker worker = new Worker()
        .function("m", "f", args -> args.size())
        .streamFunction("m", "s", (stream, args) -> "streamed");
    assertEquals(2, worker.resolveTarget("m", "f").invoke(null, List.of(1L, 2L)));
    assertTrue(worker.resolveTarget("m", "s").isStream(), "streamFunction is a stream target");
  }

  public static void testCoercion() {
    assertEquals(5, Worker.coerce(5L, int.class, 0));
    assertEquals(5.0, Worker.coerce(5L, double.class, 0));
    assertEquals(BigInteger.TEN, Worker.coerce(10L, BigInteger.class, 0));
    assertEquals("ok", Worker.coerce(new Atom("ok"), String.class, 0));
    assertThrows(IllegalArgumentException.class, () -> Worker.coerce(1L << 40, int.class, 0));
    assertThrows(IllegalArgumentException.class, () -> Worker.coerce("x", long.class, 0));
    assertThrows(IllegalArgumentException.class, () -> Worker.coerce(null, long.class, 0));
  }

  public static void testErrorMapShape() throws Exception {
    Worker worker = new Worker().register("handlers", Handlers.class);
    Throwable thrown = assertThrows(Exception.class,
        () -> worker.resolveTarget("handlers", "fail").invoke(null, List.of("boom")));
    Map<String, Object> error = Errors.buildErrorMap(thrown);
    assertEquals("remote", error.get("kind"));
    assertEquals("boom", error.get("message"));
    Map<?, ?> remote = (Map<?, ?>) error.get("remote");
    assertEquals("java", remote.get("language"));
    assertEquals("java.lang.IllegalStateException", remote.get("exception_type"));
    assertTrue(((List<?>) error.get("stacktrace")).size() <= Errors.MAX_STACK_FRAMES, "bounded stacktrace");
    // The whole map is encodable as an ERROR frame.
    MsgpackCodec.encode(List.of(Protocol.ERROR, 1L, error));
  }

  public static void testErrorMessagesAreBounded() {
    Map<String, Object> error = Errors.buildErrorMap(new RuntimeException("é".repeat(5000)));
    assertTrue(((String) error.get("message")).getBytes(java.nio.charset.StandardCharsets.UTF_8).length
        <= Errors.MAX_MESSAGE_SIZE, "message is truncated on a character boundary");
  }
}
