package portals;

import java.math.BigInteger;
import java.util.Arrays;
import java.util.Iterator;
import java.util.List;
import java.util.Map;

/** Helpers for working with decoded Portals terms. */
public final class Values {
  private Values() {}

  /**
   * Deep structural equality across the term types: {@code byte[]} by
   * content, integers by numeric value regardless of boxing
   * ({@code Integer}/{@code Long}/{@code BigInteger}), lists and maps
   * element-wise. Used by the tests and available to callers comparing
   * decoded terms.
   */
  public static boolean termsEqual(Object a, Object b) {
    if (a == b) return true;
    if (a == null || b == null) return false;
    if (isInteger(a) && isInteger(b)) return toBigInteger(a).equals(toBigInteger(b));
    if (a instanceof byte[] x) return b instanceof byte[] y && Arrays.equals(x, y);
    if (a instanceof List<?> x) {
      if (!(b instanceof List<?> y) || x.size() != y.size()) return false;
      Iterator<?> i = x.iterator();
      Iterator<?> j = y.iterator();
      while (i.hasNext()) if (!termsEqual(i.next(), j.next())) return false;
      return true;
    }
    if (a instanceof Map<?, ?> x) {
      if (!(b instanceof Map<?, ?> y) || x.size() != y.size()) return false;
      for (Map.Entry<?, ?> entry : x.entrySet()) {
        if (!y.containsKey(entry.getKey())) return false;
        if (!termsEqual(entry.getValue(), y.get(entry.getKey()))) return false;
      }
      return true;
    }
    return a.equals(b);
  }

  static boolean isInteger(Object value) {
    return value instanceof Long
        || value instanceof Integer
        || value instanceof Short
        || value instanceof Byte
        || value instanceof BigInteger;
  }

  static BigInteger toBigInteger(Object value) {
    return value instanceof BigInteger big ? big : BigInteger.valueOf(((Number) value).longValue());
  }

  /** Narrows to a {@code Long} whenever the value fits, else {@code BigInteger}. */
  static Object normalizeInteger(BigInteger value) {
    return value.bitLength() < 64 ? (Object) value.longValue() : value;
  }
}
