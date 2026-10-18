package portals

import (
	"errors"
	"fmt"
	"runtime/debug"
	"strings"
)

// Structured remote-error mapping (FR-4). Every error returned, or panic
// raised, by a handler becomes an ERROR frame carrying language, error type,
// message, and a normalized, bounded stacktrace — never a raw serialized
// object. The wire shape matches %Portals.Error{}:
// kind/message/details/remote/stacktrace.

const (
	maxStackFrames = 64
	maxMessageSize = 4096
)

// Sentinel errors returned by the SDK.
var (
	// ErrStreamClosed is returned when sending on a cancelled stream, or on
	// a direction this side already half-closed.
	ErrStreamClosed = errors.New("portals: stream closed")
	// ErrStreamCancelled is returned by Stream.Recv once the stream was
	// cancelled.
	ErrStreamCancelled = errors.New("portals: stream cancelled")
	// ErrTimeout is returned by the timeout variants of stream operations.
	ErrTimeout = errors.New("portals: timed out")
	// ErrNoWorker is returned when a call context outlives its worker.
	ErrNoWorker = errors.New("portals: worker is not running")
)

// Error is a structured error. Handlers may return one to control the
// reported kind and details; Callback returns one when the BEAM-side
// callback target fails.
type Error struct {
	Kind       string
	Message    string
	Details    map[string]any
	Remote     map[string]any
	Stacktrace []any
}

func (e *Error) Error() string {
	if e.Kind == "" || e.Kind == "remote" {
		return e.Message
	}
	return e.Kind + ": " + e.Message
}

func (e *Error) toMap() map[string]any {
	kind := e.Kind
	if kind == "" {
		kind = "remote"
	}
	details := e.Details
	if details == nil {
		details = map[string]any{}
	}
	remote := e.Remote
	if remote == nil {
		remote = map[string]any{"language": "go", "exception_type": "*portals.Error"}
	}
	stack := e.Stacktrace
	if stack == nil {
		stack = []any{}
	}
	return map[string]any{
		"kind":       kind,
		"message":    e.Message,
		"details":    details,
		"remote":     remote,
		"stacktrace": stack,
	}
}

// errorFromMap rebuilds an *Error from a decoded error_map.
func errorFromMap(v any) *Error {
	m, _ := v.(map[string]any)
	e := &Error{Kind: "remote", Message: "callback failed"}
	if kind, ok := m["kind"].(string); ok {
		e.Kind = kind
	}
	if message, ok := m["message"].(string); ok {
		e.Message = message
	}
	e.Details, _ = m["details"].(map[string]any)
	e.Remote, _ = m["remote"].(map[string]any)
	e.Stacktrace, _ = m["stacktrace"].([]any)
	return e
}

func truncateMessage(message string) string {
	if len(message) <= maxMessageSize {
		return message
	}
	return strings.ToValidUTF8(message[:maxMessageSize], "")
}

// errorMap builds the ERROR frame payload for an error a handler returned.
func errorMap(err error) map[string]any {
	var perr *Error
	if errors.As(err, &perr) {
		return perr.toMap()
	}
	message := truncateMessage(err.Error())
	typeName := fmt.Sprintf("%T", err)
	if message == "" {
		message = typeName
	}
	return map[string]any{
		"kind":    "remote",
		"message": message,
		"details": map[string]any{},
		"remote": map[string]any{
			"language":       "go",
			"exception_type": typeName,
		},
		"stacktrace": []any{},
	}
}

// panicErrorMap builds the ERROR frame payload for a recovered panic, with
// the panicking goroutine's stack.
func panicErrorMap(recovered any) map[string]any {
	var message string
	typeName := "panic"
	if err, ok := recovered.(error); ok {
		message = err.Error()
		typeName = fmt.Sprintf("panic(%T)", err)
	} else {
		message = fmt.Sprint(recovered)
	}
	return map[string]any{
		"kind":    "remote",
		"message": truncateMessage(message),
		"details": map[string]any{},
		"remote": map[string]any{
			"language":       "go",
			"exception_type": typeName,
		},
		"stacktrace": stackFrames(),
	}
}

// stackFrames normalizes debug.Stack() into one "function file:line" entry
// per frame, bounded to maxStackFrames.
func stackFrames() []any {
	lines := strings.Split(strings.TrimSpace(string(debug.Stack())), "\n")
	frames := []any{}
	// lines[0] is the "goroutine N [running]:" header; the rest alternate
	// between a function line and its tab-indented file:line.
	for i := 1; i+1 < len(lines) && len(frames) < maxStackFrames; i += 2 {
		location := strings.TrimSpace(lines[i+1])
		if j := strings.LastIndex(location, " +0x"); j >= 0 {
			location = location[:j]
		}
		frames = append(frames, strings.TrimSpace(lines[i])+" "+location)
	}
	return frames
}

func overloadErrorMap(message string) map[string]any {
	return map[string]any{
		"kind":    "overload",
		"message": message,
		"details": map[string]any{},
		"remote":  map[string]any{"language": "go"},
	}
}

func protocolErrorMap(message string) map[string]any {
	return map[string]any{
		"kind":    "protocol",
		"message": message,
		"details": map[string]any{},
		"remote":  map[string]any{"language": "go"},
	}
}
