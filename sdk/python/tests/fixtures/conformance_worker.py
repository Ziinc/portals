"""Black-box conformance bridge (protocol/v1.md section 10, FR-7).

The BEAM-side conformance test drives this module as an ordinary worker:
`echo_term` proves every golden vector survives a full decode/encode round
trip through this SDK's codec, and `decode_reason` reports how this SDK
classifies each malformed fixture — without the test knowing anything about
Python internals.

This is a test fixture, not part of the `portals` package: it uses only the
SDK's public codec surface, exactly as the Ruby and Node bridges do.
"""

from portals.msgpack_codec import DecodeError, decode
from portals.protocol import DEFAULT_LIMITS, PROTOCOL_VERSION

# The Python SDK ships as part of this repo and has no independent release
# cadence; the Ruby and Node SDKs report the same value.
SDK_VERSION = "1.0.0"


def echo_term(value):
    """Decoded by the SDK on the way in, re-encoded on the way out. The BEAM
    compares the result to the term it sent."""

    return value


def decode_reason(data):
    """Classify raw bytes exactly as the frame reader would. Returns the
    rejection reason name, or "ok" when the bytes are accepted."""

    try:
        _term, rest = decode(bytes(data), DEFAULT_LIMITS)
    except DecodeError as exc:
        return exc.reason[0]

    return "ok" if rest == b"" else "trailing_bytes"


def version_info():
    """The SDK's identity: protocol version and runtime string, so version
    diagnostics can be compared across SDKs."""

    return {
        "protocol_version": PROTOCOL_VERSION,
        "language": "python",
        "sdk_version": SDK_VERSION,
    }
