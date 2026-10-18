package portals;

import java.util.LinkedHashMap;
import java.util.Map;

/**
 * An immutable snapshot of the connection limits (protocol/v1.md §6): the
 * shipped defaults, overridden by whatever the BEAM sent in {@code READY}.
 */
public final class Limits {
  public static final Limits DEFAULT = new Limits(Protocol.DEFAULT_LIMITS);

  private final Map<String, Long> values;

  private Limits(Map<String, Long> values) {
    this.values = Map.copyOf(values);
  }

  /** These limits with every integer-valued entry of {@code overrides} applied. */
  public Limits merge(Map<?, ?> overrides) {
    Map<String, Long> merged = new LinkedHashMap<>(values);
    for (Map.Entry<?, ?> entry : overrides.entrySet()) {
      if (entry.getValue() instanceof Number number) {
        merged.put(String.valueOf(entry.getKey()), number.longValue());
      }
    }
    return new Limits(merged);
  }

  public long get(String name) {
    Long value = values.get(name);
    if (value == null) throw new IllegalArgumentException("unknown limit " + name);
    return value;
  }

  public long maxFrameSize() {
    return get("max_frame_size");
  }

  public long maxNestingDepth() {
    return get("max_nesting_depth");
  }

  public long maxCollectionLength() {
    return get("max_collection_length");
  }

  public long maxStreamByteCredit() {
    return get("max_stream_byte_credit");
  }

  public long maxQueuedStreamFrames() {
    return get("max_queued_stream_frames");
  }

  public Map<String, Long> asMap() {
    return values;
  }
}
