package portals

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"strings"
	"testing"
)

// Inline calls (protocol/v1.md section 7.1) run on the frame-reading
// goroutine: handleFrame returns only once their terminal frame is sent.

func newInlineTestWorker(t *testing.T) (*Worker, *bytes.Buffer) {
	t.Helper()
	out := &bytes.Buffer{}
	w := NewWorker(Options{Logger: func(string) {}})
	w.conn = &framedConn{w: out}
	w.ctx, w.stop = context.WithCancel(context.Background())
	w.slots = make(chan struct{}, w.maxConcurrency)
	t.Cleanup(w.stop)
	return w, out
}

func sentFrames(t *testing.T, out *bytes.Buffer) [][]any {
	t.Helper()
	var frames [][]any
	data := out.Bytes()
	for len(data) > 0 {
		n := int(binary.BigEndian.Uint32(data))
		term, _, err := Decode(data[FramePrefixBytes:FramePrefixBytes+n], DefaultLimits)
		if err != nil {
			t.Fatal(err)
		}
		frames = append(frames, term.([]any))
		data = data[FramePrefixBytes+n:]
	}
	return frames
}

func inlineCall(t *testing.T, w *Worker, id int, function string, args ...any) {
	t.Helper()
	if args == nil {
		args = []any{}
	}
	payload, err := Encode([]any{TagCall, id, "m", function, args, nil, 0, true}, DefaultLimits)
	if err != nil {
		t.Fatal(err)
	}
	w.handleFrame(payload)
}

func TestInlineCallSendsItsResultBeforeHandleFrameReturns(t *testing.T) {
	w, out := newInlineTestWorker(t)
	w.Handle("m", "add", func(c *Call, args Args) (any, error) {
		a, _ := args.Int(0)
		b, _ := args.Int(1)
		return a + b, nil
	})

	inlineCall(t, w, 1, "add", 1, 2)

	frames := sentFrames(t, out)
	if len(frames) != 1 {
		t.Fatalf("expected one frame, got %v", frames)
	}
	if tag, _ := toInt64(frames[0][0]); tag != TagReturn || toUint64(frames[0][1]) != 1 {
		t.Fatalf("expected RETURN for request 1, got %v", frames[0])
	}
	if v, _ := toInt64(frames[0][2]); v != 3 {
		t.Fatalf("expected 3, got %v", frames[0][2])
	}
}

func TestInlineCallCannotCallBack(t *testing.T) {
	w, out := newInlineTestWorker(t)
	var cbErr error
	w.Handle("m", "cb", func(c *Call, args Args) (any, error) {
		_, cbErr = c.Callback("Elixir.Target", "double", 21)
		return nil, cbErr
	})

	inlineCall(t, w, 2, "cb")

	if !errors.Is(cbErr, ErrInlineCallback) {
		t.Fatalf("expected ErrInlineCallback, got %v", cbErr)
	}
	frames := sentFrames(t, out)
	if len(frames) != 1 {
		t.Fatalf("expected only the ERROR frame (no CALLBACK), got %v", frames)
	}
	if tag, _ := toInt64(frames[0][0]); tag != TagError {
		t.Fatalf("expected ERROR, got %v", frames[0])
	}
	errMap := frames[0][2].(map[string]any)
	if msg, _ := errMap["message"].(string); !strings.Contains(msg, "inline") {
		t.Fatalf("error message should mention inline: %q", msg)
	}
}
