package portals;

import java.util.Objects;

/**
 * An Erlang atom (protocol/v1.md §5.1). Java has no atom table, so §5.3's
 * unsafe-atom concern does not apply here: atom text round-trips as an
 * opaque value that re-encodes identically.
 */
public final class Atom {
  private final String name;

  public Atom(String name) {
    this.name = Objects.requireNonNull(name, "name");
  }

  public static Atom of(String name) {
    return new Atom(name);
  }

  public String name() {
    return name;
  }

  @Override
  public boolean equals(Object other) {
    return other instanceof Atom atom && atom.name.equals(name);
  }

  @Override
  public int hashCode() {
    return name.hashCode();
  }

  @Override
  public String toString() {
    return ":" + name;
  }
}
