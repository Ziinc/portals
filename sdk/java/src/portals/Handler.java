package portals;

import java.util.List;

/** A unary target registered directly with {@link Worker#function}. */
@FunctionalInterface
public interface Handler {
  Object call(List<Object> args) throws Exception;
}
