package portals

import (
	"context"
	"fmt"
	"math/big"
)

// Handler handles one unary CALL. Its return value becomes the RETURN
// frame's value; a returned error (or a panic) becomes a structured ERROR
// frame.
type Handler func(c *Call, args Args) (any, error)

// StreamHandler handles a CALL that opens a bidirectional stream. Its
// return value becomes the stream's terminal RETURN.
type StreamHandler func(c *Call, s *Stream, args Args) (any, error)

// Call is the context of one in-flight CALL, passed to every handler. Go
// has no thread-locals, so everything the other SDKs expose as ambient
// handler context (callbacks, deadline, depth, cancellation) hangs off it.
type Call struct {
	ctx         context.Context
	worker      *Worker
	requestID   uint64
	module      string
	function    string
	deadlineMS  int64
	hasDeadline bool
	depth       int64
	inline      bool
}

// Context is cancelled when the BEAM sends CANCEL for this call (or
// cancels the stream), and when the worker shuts down. Cancellation is
// cooperative: Portals never forcibly stops a handler.
func (c *Call) Context() context.Context { return c.ctx }

// Cancelled reports whether the BEAM cancelled this call.
func (c *Call) Cancelled() bool { return c.ctx.Err() != nil }

// RequestID is the CALL's request_id (for a stream, also its stream_id).
func (c *Call) RequestID() uint64 { return c.requestID }

// Module is the module name the BEAM called.
func (c *Call) Module() string { return c.module }

// Function is the function name the BEAM called.
func (c *Call) Function() string { return c.function }

// DeadlineMS is the deadline the BEAM attached to this CALL, if any.
// Handlers use it to bound their own work cooperatively.
func (c *Call) DeadlineMS() (int64, bool) { return c.deadlineMS, c.hasDeadline }

// CallbackDepth is the reentrancy depth of this CALL: 0 for a top-level
// call, or the depth of the BEAM callback handler it was dispatched from
// (protocol/v1.md section 8).
func (c *Call) CallbackDepth() int64 { return c.depth }

// Callback calls module.function back on the BEAM and blocks this
// handler's goroutine (never the socket reader) for the result. It gives
// up when the call's context is cancelled. A failing BEAM-side target is
// returned as an *Error. Inside an inline call (protocol/v1.md section 7.1)
// it fails at once with ErrInlineCallback.
func (c *Call) Callback(module, function string, args ...any) (any, error) {
	return c.CallbackContext(c.ctx, module, function, args...)
}

// CallbackContext is Callback bounded by ctx instead of the call's own
// context, e.g. to apply a timeout.
func (c *Call) CallbackContext(ctx context.Context, module, function string, args ...any) (any, error) {
	if c.inline {
		return nil, ErrInlineCallback
	}
	if args == nil {
		args = []any{}
	}
	return c.worker.callback(ctx, c.depth+1, module, function, args)
}

// SendMessage delivers value to a BEAM PID (typically one received as a
// CALL argument). Fire-and-forget: there is no acknowledgement.
func (c *Call) SendMessage(target Pid, value any) error {
	return c.worker.sendEnvelope([]any{TagMessage, target, value})
}

// Args are a CALL's decoded arguments, with typed accessors that return an
// *ArgumentError (reported to the BEAM as a remote error) on mismatch.
type Args []any

// ArgumentError reports a missing or mistyped argument.
type ArgumentError struct {
	Index int
	Want  string
	Got   any
}

func (e *ArgumentError) Error() string {
	if e.Got == nil {
		return fmt.Sprintf("argument %d: expected %s, got nil or missing", e.Index, e.Want)
	}
	return fmt.Sprintf("argument %d: expected %s, got %T", e.Index, e.Want, e.Got)
}

// Get returns argument i, or nil when there are fewer arguments.
func (a Args) Get(i int) any {
	if i < 0 || i >= len(a) {
		return nil
	}
	return a[i]
}

// Int returns argument i as an int64.
func (a Args) Int(i int) (int64, error) {
	v := a.Get(i)
	if n, ok := toInt64(v); ok {
		return n, nil
	}
	return 0, &ArgumentError{i, "integer", v}
}

// BigInt returns argument i as a *big.Int, whatever its size.
func (a Args) BigInt(i int) (*big.Int, error) {
	switch v := a.Get(i).(type) {
	case *big.Int:
		return v, nil
	case uint64:
		return new(big.Int).SetUint64(v), nil
	default:
		if n, ok := toInt64(v); ok {
			return big.NewInt(n), nil
		}
		return nil, &ArgumentError{i, "integer", v}
	}
}

// Float returns argument i as a float64, accepting integers too.
func (a Args) Float(i int) (float64, error) {
	v := a.Get(i)
	if f, ok := v.(float64); ok {
		return f, nil
	}
	if n, ok := toInt64(v); ok {
		return float64(n), nil
	}
	return 0, &ArgumentError{i, "number", v}
}

// String returns argument i as a string, accepting str and bin payloads.
func (a Args) String(i int) (string, error) {
	switch v := a.Get(i).(type) {
	case string:
		return v, nil
	case []byte:
		return string(v), nil
	default:
		return "", &ArgumentError{i, "string", v}
	}
}

// Bytes returns argument i as a byte slice, accepting bin and str payloads.
func (a Args) Bytes(i int) ([]byte, error) {
	switch v := a.Get(i).(type) {
	case []byte:
		return v, nil
	case string:
		return []byte(v), nil
	default:
		return nil, &ArgumentError{i, "binary", v}
	}
}

// Bool returns argument i as a bool.
func (a Args) Bool(i int) (bool, error) {
	v, ok := a.Get(i).(bool)
	if !ok {
		return false, &ArgumentError{i, "boolean", a.Get(i)}
	}
	return v, nil
}

// Pid returns argument i as a Pid.
func (a Args) Pid(i int) (Pid, error) {
	v, ok := a.Get(i).(Pid)
	if !ok {
		return Pid{}, &ArgumentError{i, "pid", a.Get(i)}
	}
	return v, nil
}

// List returns argument i as a list.
func (a Args) List(i int) ([]any, error) {
	v, ok := a.Get(i).([]any)
	if !ok {
		return nil, &ArgumentError{i, "list", a.Get(i)}
	}
	return v, nil
}

// Map returns argument i as a string-keyed map.
func (a Args) Map(i int) (map[string]any, error) {
	v, ok := a.Get(i).(map[string]any)
	if !ok {
		return nil, &ArgumentError{i, "map", a.Get(i)}
	}
	return v, nil
}
