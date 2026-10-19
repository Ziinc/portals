# frozen_string_literal: true

require 'portals'

# Black-box conformance bridge (protocol/v1.md §10, FR-7).
#
# The BEAM-side conformance test drives this module as an ordinary worker:
# `echo_term` proves every golden vector survives a full decode/encode round
# trip through this SDK's codec, and `decode_reason` reports how this SDK
# classifies each malformed fixture — without the test knowing anything
# about Ruby internals.
module ConformanceWorker
  module_function

  # Decoded by the SDK on the way in, re-encoded on the way out. The BEAM
  # compares the result to the term it sent.
  def echo_term(value) = value

  # Classify raw bytes exactly as the frame reader would. Returns the
  # rejection reason name, or "ok" when the bytes are accepted.
  def decode_reason(bytes)
    term, rest = Portals::MsgpackCodec.decode(bytes.b, Portals::Protocol::DEFAULT_LIMITS)
    return 'trailing_bytes' unless rest.empty?

    _ = term
    'ok'
  rescue Portals::MsgpackCodec::DecodeError => e
    e.reason[0].to_s
  end

  # The SDK's identity: protocol version and runtime string, so version
  # diagnostics can be compared across SDKs.
  def version_info
    {
      'protocol_version' => Portals::Protocol::PROTOCOL_VERSION,
      'language' => 'ruby',
      'sdk_version' => Portals::VERSION
    }
  end
end
