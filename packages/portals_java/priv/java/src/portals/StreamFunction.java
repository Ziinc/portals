package portals;

import java.util.List;

/** A streaming target registered directly with {@link Worker#streamFunction}. */
@FunctionalInterface
public interface StreamFunction {
  Object call(Stream stream, List<Object> args) throws Exception;
}
