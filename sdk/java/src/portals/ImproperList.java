package portals;

import java.util.Objects;

/** An Erlang improper list {@code [items | tail]}. */
public final class ImproperList {
  private final Object items;
  private final Object tail;

  public ImproperList(Object items, Object tail) {
    this.items = items;
    this.tail = tail;
  }

  /** The proper prefix (normally a {@link java.util.List}). */
  public Object items() {
    return items;
  }

  public Object tail() {
    return tail;
  }

  @Override
  public boolean equals(Object other) {
    return other instanceof ImproperList list
        && Values.termsEqual(list.items, items)
        && Values.termsEqual(list.tail, tail);
  }

  @Override
  public int hashCode() {
    return Objects.hash(items, tail);
  }

  @Override
  public String toString() {
    return "[" + items + " | " + tail + "]";
  }
}
