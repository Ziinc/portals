package main

import (
	"errors"

	portals "github.com/Ziinc/portals/sdk/go"
)

// registerConformanceWorker registers the black-box conformance bridge
// (protocol/v1.md section 10, FR-7).
//
// The BEAM-side conformance test drives it as an ordinary worker:
// echo_term proves every golden vector survives a full decode/encode round
// trip through this SDK's codec, and decode_reason reports how this SDK
// classifies each malformed fixture — without the test knowing anything
// about Go internals.
func registerConformanceWorker(w *portals.Worker) {
	const m = "conformance_worker"

	// Decoded by the SDK on the way in, re-encoded on the way out. The
	// BEAM compares the result to the term it sent.
	w.Handle(m, "echo_term", func(c *portals.Call, args portals.Args) (any, error) {
		return args.Get(0), nil
	})

	// Classify raw bytes exactly as the frame reader would, with the codec
	// PORTALS_CODEC selected. Returns the rejection reason name, or "ok"
	// when the bytes are accepted.
	w.Handle(m, "decode_reason", func(c *portals.Call, args portals.Args) (any, error) {
		data, err := args.Bytes(0)
		if err != nil {
			return nil, err
		}
		_, rest, err := portals.Decode(data, portals.DefaultLimits)
		var codecErr *portals.CodecError
		switch {
		case errors.As(err, &codecErr):
			return codecErr.Reason, nil
		case err != nil:
			return nil, err
		case len(rest) != 0:
			return "trailing_bytes", nil
		default:
			return "ok", nil
		}
	})

	// The SDK's identity: protocol version and runtime string, so version
	// diagnostics can be compared across SDKs.
	w.Handle(m, "version_info", func(c *portals.Call, args portals.Args) (any, error) {
		return map[string]any{
			"protocol_version": portals.ProtocolVersion,
			"language":         "go",
			"sdk_version":      portals.Version,
		}, nil
	})
}
