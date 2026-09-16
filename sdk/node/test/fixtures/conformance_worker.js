'use strict';

// Black-box conformance bridge (protocol/v1.md §10, FR-7).
//
// The BEAM-side conformance test drives this module as an ordinary worker:
// `echo_term` proves every golden vector survives a full decode/encode round
// trip through this SDK's codec, and `decode_reason` reports how this SDK
// classifies each malformed fixture — without the test knowing anything
// about JavaScript internals.

const portals = require('../..');

// Decoded by the SDK on the way in, re-encoded on the way out. The BEAM
// compares the result to the term it sent.
const echoTerm = (value) => value;

// Classify raw bytes exactly as the frame reader would. Returns the
// rejection reason name, or "ok" when the bytes are accepted.
function decodeReason(bytes) {
  try {
    const [, rest] = portals.codec.decode(Buffer.from(bytes), portals.protocol.DEFAULT_LIMITS);
    return rest.length === 0 ? 'ok' : 'trailing_bytes';
  } catch (err) {
    if (err instanceof portals.codec.DecodeError) return err.reason;
    throw err;
  }
}

// The SDK's identity: protocol version and runtime string, so version
// diagnostics can be compared across SDKs.
const versionInfo = () => ({
  protocol_version: portals.PROTOCOL_VERSION,
  language: 'javascript',
  sdk_version: portals.VERSION,
});

module.exports = {
  echo_term: echoTerm,
  echoTerm,
  decode_reason: decodeReason,
  decodeReason,
  version_info: versionInfo,
  versionInfo,
};
