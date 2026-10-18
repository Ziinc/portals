# Portals Go worker SDK

A Go worker for [Portals](../../README.md), implementing the v1 wire
protocol in [`protocol/v1.md`](../../protocol/v1.md) with full parity with
the reference Python SDK.

Standard library only: the MessagePack codec (including the Erlang value
extensions) is implemented in `codec.go`, so a worker needs nothing but a
Go toolchain to build.

## Installing

The Go SDK is versioned in lockstep with the `portals` Hex package. Each
Hex release `X.Y.Z` is tagged `sdk/go/vX.Y.Z` on the same commit (Go
versions a module in a subdirectory with that directory as the tag
prefix), so require the version matching your `mix.lock`:

```sh
go get github.com/Ziinc/portals/sdk/go@v0.1.0
```

The HELLO/READY handshake requires the exact same protocol version on both
sides. To build against whatever your Elixir dependency ships instead,
point the module at the copy inside `deps/` (the Hex package includes the
Go sources):

```
// go.mod
require github.com/Ziinc/portals/sdk/go v0.1.0
replace github.com/Ziinc/portals/sdk/go => ../deps/portals/sdk/go
```

## Writing a worker

```go
package main

import (
	"log"

	portals "github.com/Ziinc/portals/sdk/go"
)

func main() {
	// Portals appends the socket path as the last CLI argument.
	w := portals.NewWorker(portals.Options{MaxConcurrency: 16, MaxStreams: 8})

	w.Handle("my_handlers", "encode", func(c *portals.Call, args portals.Args) (any, error) {
		text, err := args.String(0)
		if err != nil {
			return nil, err // becomes a structured %Portals.Error{kind: :remote}
		}
		return map[string]any{"length": len(text)}, nil
	})

	w.Handle("my_handlers", "with_progress", func(c *portals.Call, args portals.Args) (any, error) {
		n, _ := args.Int(0)
		// Reentrant callback into the BEAM; blocks this handler's goroutine,
		// never the socket reader.
		if _, err := c.Callback("Elixir.MyApp.Progress", "report", n); err != nil {
			return nil, err
		}
		return n * 2, nil
	})

	w.Handle("my_handlers", "notify", func(c *portals.Call, args portals.Args) (any, error) {
		pid, err := args.Pid(0)
		if err != nil {
			return nil, err
		}
		return portals.Atom("ok"), c.SendMessage(pid, args.Get(1)) // fire-and-forget
	})

	w.HandleStream("my_handlers", "echo_stream", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		count := 0
		for {
			chunk, err := s.Recv() // blocks until credit-backed data arrives
			if err != nil {        // io.EOF once the BEAM half-closes
				return count, nil  // becomes the stream's terminal RETURN
			}
			if err := s.Send(chunk); err != nil { // blocks until the BEAM grants credit
				return nil, err
			}
			count++
		}
	})

	if err := w.Run(); err != nil {
		log.Fatal(err)
	}
}
```

From Elixir, after `go build -o my_worker .`:

```elixir
{:ok, conn} = Portals.start_worker(command: "./my_worker")
{:ok, %{"length" => 5}} = Portals.call(conn, "my_handlers", "encode", ["hello"])
{:ok, stream} = Portals.open_stream(conn, "my_handlers", "echo_stream", [])
```

## Dispatch

Go cannot look functions up by name at runtime, so every target is
registered explicitly with `Handle` (unary) or `HandleStream` (streaming)
under the module/function names the BEAM uses in `CALL`. A `CALL` to an
unregistered target is reported as a remote `*portals.UndefinedError`.

Each `CALL` runs on its own goroutine; at most `MaxConcurrency` unary
handlers execute at once (the rest wait their turn), and up to
`MaxStreams` streams are open at once, budgeted separately so long-lived
streams never starve unary calls. Opening a stream beyond `MaxStreams` is
an `overload` error.

## Values

| Erlang | Go (decoded) | Go (accepted on encode) |
|---|---|---|
| `nil`, booleans | `nil`, `bool` | same |
| integer | `int64`; `uint64` above `math.MaxInt64`; `*big.Int` beyond 64 bits | any integer type, `*big.Int` |
| float | `float64` | `float64`, `float32` |
| binary string | `string` | `string` |
| `%Portals.Codec.Bin{}` | `[]byte` | `[]byte` |
| list | `[]any` | any slice or array |
| map | `map[string]any` | any string-keyed map |
| tuple | `portals.Tuple` | same |
| atom | `portals.Atom` | same |
| PID / reference | `portals.Pid` / `portals.Reference` (opaque, comparable) | same |
| improper list | `portals.ImproperList` | same |

`portals.Args` has typed accessors (`Int`, `BigInt`, `Float`, `String`,
`Bytes`, `Bool`, `Pid`, `List`, `Map`, `Get`) that return an
`*portals.ArgumentError` on a mismatch.

## Handler context

| `*portals.Call` method | Meaning |
|---|---|
| `Callback(mod, fun, args...)` | Reentrant call back into the BEAM; a failing target returns an `*portals.Error` |
| `CallbackContext(ctx, mod, fun, args...)` | Same, bounded by `ctx` (e.g. a timeout) |
| `SendMessage(pid, value)` | Fire-and-forget message to a BEAM PID |
| `Context()` | Cancelled when the BEAM sends `CANCEL` (or cancels the stream) |
| `Cancelled()` | True once the BEAM cancelled this call |
| `CallbackDepth()` | Reentrancy depth of the current CALL |
| `DeadlineMS()` | Deadline the BEAM attached to this CALL, if any |

Return an `*portals.Error` from a handler to choose the reported `kind` and
`details`; any other error, or a panic (with its stack), is reported as
`kind: "remote"`.

## Logging

Never over the RPC protocol: set `PORTALS_LOG_FILE` for a file sink, or
pass `Options.Logger`. The default is stderr, which the BEAM captures out of
band.

## Transports

`Options.Transport` is `"unix"` (default) or `"stdio"` for the framed
stdin/stdout fallback.

## Tests

```sh
go test ./...
```

The cross-language conformance and integration suites live on the Elixir
side: `mix test test/conformance/sdk_conformance_test.exs
test/integration/go_worker_test.exs`. They launch
`test/fixtures/run_worker.sh`, which builds the fixture worker in
`test/fixtures/worker` into `.build/` on first use.
