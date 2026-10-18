package portals.fixtures;

import java.util.LinkedHashMap;
import java.util.Map;
import portals.DecodeException;
import portals.Limits;
import portals.MsgpackCodec;
import portals.Portals;

/**
 * Black-box conformance bridge (protocol/v1.md §10, FR-7).
 *
 * <p>The BEAM-side conformance test drives this module as an ordinary
 * worker: {@code echo_term} proves every golden vector survives a full
 * decode/encode round trip through this SDK's codec, and
 * {@code decode_reason} reports how this SDK classifies each malformed
 * fixture — without the test knowing anything about Java internals.
 */
public final class ConformanceWorker {
  private ConformanceWorker() {}

  /** Decoded by the SDK on the way in, re-encoded on the way out. */
  public static Object echoTerm(Object value) {
    return value;
  }

  /**
   * Classifies raw bytes exactly as the frame reader would. Returns the
   * rejection reason name, or "ok" when the bytes are accepted.
   */
  public static String decodeReason(byte[] bytes) {
    try {
      MsgpackCodec.Decoded decoded = MsgpackCodec.decode(bytes, Limits.DEFAULT);
      return decoded.restLength() == 0 ? "ok" : "trailing_bytes";
    } catch (DecodeException e) {
      return e.reason();
    }
  }

  /** The SDK's identity, so version diagnostics can be compared across SDKs. */
  public static Map<String, Object> versionInfo() {
    Map<String, Object> info = new LinkedHashMap<>();
    info.put("protocol_version", Portals.PROTOCOL_VERSION);
    info.put("language", "java");
    info.put("sdk_version", Portals.VERSION);
    return info;
  }
}
