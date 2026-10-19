package main

import (
	"errors"
	"os"
	"strings"
	"time"

	portals "github.com/Ziinc/portals/sdk/go"
)

const callbackTarget = "Elixir.Portals.Fixtures.CallbackTarget"

func sleepMS(ms int64) { time.Sleep(time.Duration(ms) * time.Millisecond) }

// registerBenchWorker registers the function targets used by the Elixir
// integration tests.
func registerBenchWorker(w *portals.Worker) {
	const m = "bench_worker"

	w.Handle(m, "echo", func(c *portals.Call, args portals.Args) (any, error) {
		return args.Get(0), nil
	})

	w.Handle(m, "add", func(c *portals.Call, args portals.Args) (any, error) {
		a, err := args.Int(0)
		if err != nil {
			return nil, err
		}
		b, err := args.Int(1)
		if err != nil {
			return nil, err
		}
		return a + b, nil
	})

	w.Handle(m, "raise_error", func(c *portals.Call, args portals.Args) (any, error) {
		message, _ := args.String(0)
		return nil, errors.New(message)
	})

	w.Handle(m, "sleep_ms", func(c *portals.Call, args portals.Args) (any, error) {
		ms, err := args.Int(0)
		if err != nil {
			return nil, err
		}
		sleepMS(ms)
		return ms, nil
	})

	w.Handle(m, "crash_process", func(c *portals.Call, args portals.Args) (any, error) {
		os.Exit(1)
		return nil, nil
	})

	// Calls back into the BEAM to double a number, demonstrating a
	// reentrant round trip.
	w.Handle(m, "double_via_callback", func(c *portals.Call, args portals.Args) (any, error) {
		return c.Callback(callbackTarget, "double", args.Get(0))
	})

	// A callback target the Elixir side invokes; while running (still
	// inside the BEAM-side callback handler) it reports the reentrancy
	// depth the BEAM echoed back on this nested CALL.
	w.Handle(m, "nested_call_then_callback", func(c *portals.Call, args portals.Args) (any, error) {
		n, err := args.Int(1)
		if err != nil {
			return nil, err
		}
		return map[string]any{"depth_seen": c.CallbackDepth(), "doubled": n * 2}, nil
	})

	w.Handle(m, "callback_depth_probe", func(c *portals.Call, args portals.Args) (any, error) {
		return c.CallbackDepth(), nil
	})

	w.Handle(m, "deadline_probe", func(c *portals.Call, args portals.Args) (any, error) {
		if ms, ok := c.DeadlineMS(); ok {
			return ms, nil
		}
		return nil, nil
	})

	w.Handle(m, "message_to_caller", func(c *portals.Call, args portals.Args) (any, error) {
		pid, err := args.Pid(0)
		if err != nil {
			return nil, err
		}
		if err := c.SendMessage(pid, args.Get(1)); err != nil {
			return nil, err
		}
		return "sent", nil
	})

	w.Handle(m, "raise_callback_error", func(c *portals.Call, args portals.Args) (any, error) {
		return c.Callback(callbackTarget, "boom")
	})

	// Value-model probes: prove the Erlang extensions survive a round trip
	// through Go untouched.
	w.Handle(m, "echo_term", func(c *portals.Call, args portals.Args) (any, error) {
		return args.Get(0), nil
	})

	w.Handle(m, "make_tuple", func(c *portals.Call, args portals.Args) (any, error) {
		items, err := args.List(0)
		if err != nil {
			return nil, err
		}
		return portals.Tuple(items), nil
	})

	w.Handle(m, "make_atom", func(c *portals.Call, args portals.Args) (any, error) {
		text, err := args.String(0)
		if err != nil {
			return nil, err
		}
		return portals.Atom(text), nil
	})

	// Cooperative cancellation: watches the context the CANCEL frame
	// cancels.
	w.Handle(m, "cancellable", func(c *portals.Call, args portals.Args) (any, error) {
		ms, err := args.Int(0)
		if err != nil {
			return nil, err
		}
		select {
		case <-c.Context().Done():
			return "cancelled", nil
		case <-time.After(time.Duration(ms) * time.Millisecond):
			return "completed", nil
		}
	})

	// -- Streaming targets ------------------------------------------------

	// Echo every inbound chunk back out, then terminate with a count.
	w.HandleStream(m, "echo_stream", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		count := 0
		for {
			chunk, err := s.Recv()
			if err != nil {
				return count, nil
			}
			if err := s.Send(chunk); err != nil {
				return nil, err
			}
			count++
		}
	})

	// Produce count chunks of size bytes each, blocking on the BEAM's
	// credit window.
	w.HandleStream(m, "produce_stream", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		count, err := args.Int(0)
		if err != nil {
			return nil, err
		}
		size, err := args.Int(1)
		if err != nil {
			return nil, err
		}
		payload := strings.Repeat("x", int(size))
		for i := int64(0); i < count; i++ {
			if err := s.SendTimeout(payload, 10*time.Second); err != nil {
				return nil, err
			}
		}
		s.HalfClose()
		return count, nil
	})

	// Consume everything the BEAM sends, optionally slowly.
	w.HandleStream(m, "drain_stream", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		delay, _ := args.Int(0)
		chunks, total := 0, 0
		for {
			chunk, err := s.Recv()
			if err != nil {
				break
			}
			chunks++
			if b, err := (portals.Args{chunk}).Bytes(0); err == nil {
				total += len(b)
			}
			if delay > 0 {
				sleepMS(delay)
			}
		}
		return map[string]any{"chunks": chunks, "bytes": total}, nil
	})

	// Never consume inbound chunks: the BEAM's sender must block on the
	// credit window rather than grow BEAM memory.
	w.HandleStream(m, "never_consume", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		ms, _ := args.Int(0)
		sleepMS(ms)
		return "held", nil
	})

	// Close only the worker's sending direction immediately, then keep
	// consuming — proving half-close is per-direction.
	w.HandleStream(m, "half_close_then_drain", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		s.HalfClose()
		chunks := 0
		for {
			if _, err := s.Recv(); err != nil {
				return chunks, nil
			}
			chunks++
		}
	})

	// Keep a stream open without doing anything, for unary/stream fairness
	// tests.
	w.HandleStream(m, "hold_stream", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		ms, _ := args.Int(0)
		sleepMS(ms)
		return "done", nil
	})
}
