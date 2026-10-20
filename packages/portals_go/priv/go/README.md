# Portals Go worker SDK

A Go worker for [Portals](../../../../README.md), implementing the v1 wire
protocol in [`protocol/v1.md`](../../../../protocol/v1.md) with full parity with
the reference Python SDK.

This SDK ships inside the `portals_go` Hex package, which also puts it
on the worker's import path. **Application developers should start with the
[Go guide](../../../../guides/languages/go.md)**; this README documents the
SDK itself.

Standard library only: both wire codecs are implemented in the SDK, the
Erlang External Term Format (the default, `etf_codec.go`) and MessagePack
with the Erlang value extensions (`codec.go`), so a worker needs nothing
but a Go toolchain to build. The BEAM picks the codec per worker
(`codec: :etf | :msgpack`) and passes it in `PORTALS_CODEC`; the worker
uses it for every frame, and `Run` fails on a value it does not know.
Handlers see the same Go values under either codec.

## Installing

The Go SDK is distributed only inside the `portals_go` Hex package, never
through the Go module proxy, so it is always the version `mix.lock` pins.
After `mix deps.get`, point your worker's module at the copy in `deps/`:

```
// go.mod
require github.com/Ziinc/portals/sdk/go v0.0.0
replace github.com/Ziinc/portals/sdk/go => ../deps/portals_go/priv/go
```

See the [Go guide](../../../../guides/languages/go.md) for the full setup.

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
{:ok, conn} = Portals.start_worker(Portals.Go.worker_opts(binary: "./my_worker"))
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

Map keys arrive as strings under either codec: atom keys become their
name and integer keys their decimal text.

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
side: run `mix test` in `packages/portals_go`, or
`scripts/test_all.sh go` from the repository root.
