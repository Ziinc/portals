package portals;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.Objects;

/**
 * A deliberately tiny test harness, so the SDK's unit tests need nothing
 * beyond the JDK: every public static no-argument method whose name starts
 * with {@code test} is run, and a failure is any exception it throws.
 */
public final class TestSupport {
  private TestSupport() {}

  @FunctionalInterface
  public interface Body {
    void run() throws Exception;
  }

  public static void main(String[] args) throws Exception {
    Class<?>[] suites = {EtfCodecTest.class, MsgpackCodecTest.class, StreamTest.class, WorkerTest.class};
    int passed = 0;
    int failed = 0;
    for (Class<?> suite : suites) {
      for (Method method : suite.getDeclaredMethods()) {
        if (!method.getName().startsWith("test") || method.getParameterCount() != 0) continue;
        if (!Modifier.isStatic(method.getModifiers())) continue;
        String name = suite.getSimpleName() + "." + method.getName();
        try {
          method.invoke(null);
          passed++;
          System.out.println("ok   " + name);
        } catch (InvocationTargetException e) {
          failed++;
          System.out.println("FAIL " + name + ": " + e.getCause());
          e.getCause().printStackTrace(System.out);
        }
      }
    }
    System.out.println();
    System.out.println(passed + " passed, " + failed + " failed");
    System.exit(failed == 0 ? 0 : 1);
  }

  public static void assertTrue(boolean condition, String message) {
    if (!condition) throw new AssertionError(message);
  }

  public static void assertEquals(Object expected, Object actual) {
    if (!Values.termsEqual(expected, actual) && !Objects.equals(expected, actual)) {
      throw new AssertionError("expected " + expected + " but was " + actual);
    }
  }

  public static <T extends Throwable> T assertThrows(Class<T> type, Body body) {
    try {
      body.run();
    } catch (Throwable e) {
      if (type.isInstance(e)) return type.cast(e);
      throw new AssertionError("expected " + type.getSimpleName() + " but got " + e, e);
    }
    throw new AssertionError("expected " + type.getSimpleName() + " to be thrown");
  }
}
