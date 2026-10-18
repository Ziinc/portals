package portals;

import java.lang.annotation.ElementType;
import java.lang.annotation.Retention;
import java.lang.annotation.RetentionPolicy;
import java.lang.annotation.Target;

/**
 * Marks a method as a streaming target. The BEAM's {@code open_stream/5}
 * dispatches to it with a {@link Stream} as the first argument; its return
 * value becomes the stream's terminal {@code RETURN}.
 *
 * <pre>{@code
 * @StreamHandler
 * public static long echoStream(Stream stream, ...) { ... }
 * }</pre>
 */
@Retention(RetentionPolicy.RUNTIME)
@Target(ElementType.METHOD)
public @interface StreamHandler {}
