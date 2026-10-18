package portals;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * An Erlang tuple. A Java {@link List} encodes as an Erlang list, so tuples
 * need their own type to round-trip back to the BEAM as tuples.
 */
public final class Tuple {
  private final List<Object> items;

  public Tuple(List<?> items) {
    // Not List.copyOf: `nil` is a perfectly good tuple element.
    this.items = Collections.unmodifiableList(new ArrayList<>(items));
  }

  public static Tuple of(Object... items) {
    return new Tuple(Arrays.asList(items));
  }

  public List<Object> items() {
    return items;
  }

  public Object get(int index) {
    return items.get(index);
  }

  public int size() {
    return items.size();
  }

  @Override
  public boolean equals(Object other) {
    return other instanceof Tuple tuple && Values.termsEqual(tuple.items, items);
  }

  @Override
  public int hashCode() {
    return items.hashCode();
  }

  @Override
  public String toString() {
    StringBuilder out = new StringBuilder("{");
    for (int i = 0; i < items.size(); i++) {
      if (i > 0) out.append(", ");
      out.append(items.get(i));
    }
    return out.append('}').toString();
  }
}
