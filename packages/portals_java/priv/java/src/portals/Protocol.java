package portals;

import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Frame tag registry and default limits for the Portals v1 protocol.
 *
 * <p>Mirrors {@code lib/portals/protocol.ex}. See {@code protocol/v1.md} for
 * the authoritative specification.
 */
public final class Protocol {
  private Protocol() {}

  public static final int PROTOCOL_VERSION = 1;

  public static final int HELLO = 1;
  public static final int READY = 2;
  public static final int CALL = 3;
  public static final int RETURN = 4;
  public static final int ERROR = 5;
  public static final int CANCEL = 6;
  public static final int CALLBACK = 7;
  public static final int CALLBACK_RETURN = 8;
  public static final int CALLBACK_ERROR = 9;
  public static final int MESSAGE = 10;
  public static final int STREAM_DATA = 11;
  public static final int CREDIT = 12;
  public static final int HALF_CLOSE = 13;
  public static final int PING = 14;
  public static final int PONG = 15;
  public static final int SHUTDOWN = 16;

  /** The shipped defaults, keyed by the same names READY uses on the wire. */
  public static final Map<String, Long> DEFAULT_LIMITS;

  static {
    Map<String, Long> limits = new LinkedHashMap<>();
    limits.put("max_frame_size", 16L * 1024 * 1024);
    limits.put("max_nesting_depth", 32L);
    limits.put("max_collection_length", 65536L);
    limits.put("max_metadata_size", 65536L);
    limits.put("max_callback_depth", 16L);
    limits.put("max_in_flight_callbacks", 256L);
    limits.put("max_in_flight_requests", 4096L);
    limits.put("max_stream_byte_credit", 4L * 1024 * 1024);
    limits.put("max_queued_stream_frames", 1024L);
    DEFAULT_LIMITS = Collections.unmodifiableMap(limits);
  }
}
