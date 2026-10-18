package portals;

import java.lang.reflect.InvocationTargetException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Structured remote-error mapping (FR-4). Every uncaught exception thrown by
 * a called function becomes an {@code ERROR} frame carrying language,
 * exception class, message, and a normalized, bounded stack trace — never a
 * serialized Java object. The wire shape matches {@code %Portals.Error{}}:
 * {@code kind}/{@code message}/{@code details}/{@code remote}/{@code stacktrace}.
 */
public final class Errors {
  private Errors() {}

  public static final int MAX_STACK_FRAMES = 64;
  public static final int MAX_MESSAGE_SIZE = 4096;

  public static Map<String, Object> buildErrorMap(Throwable error) {
    Throwable cause = unwrap(error);
    String message = cause.getMessage() == null ? "" : cause.getMessage();
    if (message.getBytes(StandardCharsets.UTF_8).length > MAX_MESSAGE_SIZE) {
      message = truncateUtf8(message, MAX_MESSAGE_SIZE);
    }

    List<Object> frames = new ArrayList<>();
    for (StackTraceElement frame : cause.getStackTrace()) {
      if (frames.size() >= MAX_STACK_FRAMES) break;
      frames.add(frame.toString());
    }

    Map<String, Object> remote = new LinkedHashMap<>();
    remote.put("language", "java");
    remote.put("exception_type", cause.getClass().getName());

    Map<String, Object> map = new LinkedHashMap<>();
    map.put("kind", "remote");
    map.put("message", message.isEmpty() ? cause.getClass().getName() : message);
    map.put("details", new LinkedHashMap<>());
    map.put("remote", remote);
    map.put("stacktrace", frames);
    return map;
  }

  /** A terminal {@code overload} error, used at advertised stream capacity. */
  public static Map<String, Object> overloadErrorMap(String message) {
    return simple("overload", message);
  }

  public static Map<String, Object> protocolErrorMap(String message) {
    return simple("protocol", message);
  }

  private static Map<String, Object> simple(String kind, String message) {
    Map<String, Object> map = new LinkedHashMap<>();
    map.put("kind", kind);
    map.put("message", message);
    map.put("details", new LinkedHashMap<>());
    map.put("remote", new LinkedHashMap<>(Map.of("language", "java")));
    return map;
  }

  // Reflection wraps the handler's own exception; report the real one.
  static Throwable unwrap(Throwable error) {
    Throwable current = error;
    while (current instanceof InvocationTargetException && current.getCause() != null) {
      current = current.getCause();
    }
    return current;
  }

  private static String truncateUtf8(String message, int maxBytes) {
    int bytes = 0;
    int i = 0;
    while (i < message.length()) {
      int cp = message.codePointAt(i);
      int size = cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
      if (bytes + size > maxBytes) break;
      bytes += size;
      i += Character.charCount(cp);
    }
    return message.substring(0, i);
  }
}
