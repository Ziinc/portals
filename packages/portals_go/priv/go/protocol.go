// Package portals is the Go worker SDK for Portals.
//
// Full parity with the reference Python SDK: Unix-socket transport with a
// framed stdio fallback, a dependency-free MessagePack codec including the
// Erlang value extensions, the exact-version HELLO/READY handshake,
// concurrent dispatch of registered module/function handlers, structured
// error frames, reentrant callbacks, PID messaging, cooperative
// cancellation, and bidirectional streaming with byte-credit windows,
// frame-count caps and per-direction half-close.
//
// See protocol/v1.md for the wire protocol.
package portals

// Version is the SDK version, reported by the conformance bridge.
const Version = "0.1.0"

// ProtocolVersion is the wire protocol version this SDK speaks. It must
// match the BEAM's exactly (protocol/v1.md section 4).
const ProtocolVersion = 1

// Frame tags. Mirrors lib/portals/protocol.ex.
const (
	TagHello          = 1
	TagReady          = 2
	TagCall           = 3
	TagReturn         = 4
	TagError          = 5
	TagCancel         = 6
	TagCallback       = 7
	TagCallbackReturn = 8
	TagCallbackError  = 9
	TagMessage        = 10
	TagStreamData     = 11
	TagCredit         = 12
	TagHalfClose      = 13
	TagPing           = 14
	TagPong           = 15
	TagShutdown       = 16
)

// FramePrefixBytes is the size of the length prefix every frame carries on
// the wire. Stream credit is charged against it (protocol/v1.md 9.2).
const FramePrefixBytes = 4

// Limits are the per-connection limits from protocol/v1.md section 6. The
// BEAM's READY frame overrides the defaults.
type Limits struct {
	MaxFrameSize          int
	MaxNestingDepth       int
	MaxCollectionLength   int
	MaxMetadataSize       int
	MaxCallbackDepth      int
	MaxInFlightCallbacks  int
	MaxInFlightRequests   int
	MaxStreamByteCredit   int
	MaxQueuedStreamFrames int
}

// DefaultLimits mirrors Portals.Protocol.default_limits/0.
var DefaultLimits = Limits{
	MaxFrameSize:          16 * 1024 * 1024,
	MaxNestingDepth:       32,
	MaxCollectionLength:   65536,
	MaxMetadataSize:       65536,
	MaxCallbackDepth:      16,
	MaxInFlightCallbacks:  256,
	MaxInFlightRequests:   4096,
	MaxStreamByteCredit:   4 * 1024 * 1024,
	MaxQueuedStreamFrames: 1024,
}

// merge applies the string-keyed limits map carried by READY.
func (l Limits) merge(m map[string]any) Limits {
	fields := map[string]*int{
		"max_frame_size":           &l.MaxFrameSize,
		"max_nesting_depth":        &l.MaxNestingDepth,
		"max_collection_length":    &l.MaxCollectionLength,
		"max_metadata_size":        &l.MaxMetadataSize,
		"max_callback_depth":       &l.MaxCallbackDepth,
		"max_in_flight_callbacks":  &l.MaxInFlightCallbacks,
		"max_in_flight_requests":   &l.MaxInFlightRequests,
		"max_stream_byte_credit":   &l.MaxStreamByteCredit,
		"max_queued_stream_frames": &l.MaxQueuedStreamFrames,
	}
	for key, ptr := range fields {
		if n, ok := toInt64(m[key]); ok {
			*ptr = int(n)
		}
	}
	return l
}
