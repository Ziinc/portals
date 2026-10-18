# Go

Run Go code from Elixir in supervised, pooled worker processes. Go workers
are compiled programs, so `portals_go` plays two roles. At build time it
provides the Go SDK sources in `deps/`, which your module points at with a
`replace` directive. At run time `Portals.Go.worker_opts/1` launches the
binary you built. The SDK is never fetched from the Go module proxy.

**Requirements:** Go 1.21 or newer to build the worker. The machine that
runs the workers needs only the binary. The SDK uses only the standard
library.

This page walks through a complete worker that counts words, parses
integers, reports progress back to Elixir, messages a process and streams
text. The same example exists for every language, and the code below is
exactly the code Portals' own test suite runs.

## 1. Install

```elixir
# mix.exs
def deps do
  [
    {:portals_go, "~> 0.1.0"}
  ]
end
```

`portals_go` depends on `portals`, so this is the only line you need.

Run `mix deps.get`: the SDK sources now live in
`deps/portals_go/priv/go`.

## 2. Create the Go module

Keep the worker in a `go/` directory at the root of your Mix project, so
`deps/` is one level up:

```
// go/go.mod
module example.com/text_worker

go 1.21

require github.com/Ziinc/portals/sdk/go v0.0.0

// The SDK comes from the portals_go Hex package in deps/, never the Go proxy.
replace github.com/Ziinc/portals/sdk/go => ../deps/portals_go/priv/go
```

`v0.0.0` is a placeholder: the `replace` directive always wins, so the
SDK version is whatever `mix.lock` pins for `portals_go`. `go mod tidy`,
`go build` and `gopls` all resolve the module offline through it. If your
worker lives elsewhere, adjust the relative path. `mix portals.sdk_path go
| tail -n 1` prints the absolute SDK directory.

## 3. Write the worker

Go can't look functions up by name at run time, so every target is
registered explicitly under the module/function names Elixir calls:

```go
// go/main.go
package main

import (
	"log"
	"strconv"
	"strings"

	portals "github.com/Ziinc/portals/sdk/go"
)

func main() {
	// Portals starts this binary and appends the socket path as the last argument.
	w := portals.NewWorker(portals.Options{MaxConcurrency: 8, MaxStreams: 4})

	w.Handle("text_tools", "word_count", func(c *portals.Call, args portals.Args) (any, error) {
		text, err := args.String(0)
		if err != nil {
			return nil, err
		}
		return len(strings.Fields(text)), nil
	})

	w.Handle("text_tools", "parse_int", func(c *portals.Call, args portals.Args) (any, error) {
		text, err := args.String(0)
		if err != nil {
			return nil, err
		}
		return strconv.Atoi(text) // an error becomes %Portals.Error{kind: :remote}
	})

	w.Handle("text_tools", "progress", func(c *portals.Call, args portals.Args) (any, error) {
		steps, err := args.Int(0)
		if err != nil {
			return nil, err
		}
		for step := int64(1); step <= steps; step++ {
			// Blocks this goroutine until MyApp.Progress.report/1 returns.
			if _, err := c.Callback("Elixir.MyApp.Progress", "report", step); err != nil {
				return nil, err
			}
		}
		return steps, nil
	})

	w.Handle("text_tools", "notify", func(c *portals.Call, args portals.Args) (any, error) {
		pid, err := args.Pid(0)
		if err != nil {
			return nil, err
		}
		text, err := args.String(1)
		if err != nil {
			return nil, err
		}
		return "sent", c.SendMessage(pid, strings.ToUpper(text)) // fire-and-forget
	})

	w.HandleStream("text_tools", "upcase_stream", func(c *portals.Call, s *portals.Stream, args portals.Args) (any, error) {
		count := 0
		for {
			chunk, err := s.Recv() // io.EOF once the BEAM half-closes its side
			if err != nil {
				return count, nil // the stream's final result
			}
			text, _ := chunk.(string)
			if err := s.Send(strings.ToUpper(text)); err != nil { // blocks while the BEAM's credit is used up
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

Each call runs on its own goroutine. At most `MaxConcurrency` unary
handlers run at once, and up to `MaxStreams` streams are open at once,
budgeted separately so streams never starve ordinary calls.

## 4. Build it

```sh
cd go && go build -o ../priv/bin/text_worker .
```

Build into `priv/` so the binary ships with your release. A Mix alias
keeps it in step with your Elixir build:

```elixir
# mix.exs
defp aliases do
  [compile: [&build_go_worker/1, "compile"]]
end

defp build_go_worker(_args) do
  {_, 0} = System.cmd("go", ["build", "-o", "../priv/bin/text_worker", "."], cd: "go")
end
```

## 5. Start a pool

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Portals.Pool,
     Portals.Go.worker_opts(
       binary: Application.app_dir(:my_app, "priv/bin/text_worker"),
       name: MyApp.Go,
       size: 4
     )}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

| Option | Default | Use it for |
|---|---|---|
| `:binary` | required | Path to the compiled worker |
| `:args` | `[]` | Arguments to the binary (before the socket path Portals appends) |
| `:env` | `[]` | Extra environment variables, e.g. `[{"GOMAXPROCS", "2"}]` |

`worker_opts/1` raises if the binary doesn't exist, so a missing build
fails at startup with a clear message.

## 6. Call it

```elixir
iex> Portals.Pool.call(MyApp.Go, "text_tools", "word_count", ["hello world"])
{:ok, 2}

iex> Portals.Pool.call(MyApp.Go, "text_tools", "parse_int", ["12"])
{:ok, 12}
```

## 7. Errors

A returned `error` becomes a structured error, and `exception_type` is its
Go type. A panic is recovered and reported the same way, with its stack:

```elixir
iex> {:error, error} = Portals.Pool.call(MyApp.Go, "text_tools", "parse_int", ["nope"])
iex> error.kind
:remote
iex> error.remote["exception_type"]
"*strconv.NumError"
```

`error.message` holds the exception message and `error.stacktrace` the
worker-side stack trace as a list of strings. Use `Portals.Pool.call!/5` to
raise `Portals.CallError` instead.

Return a `*portals.Error` to choose the reported `kind` and `details`
yourself.

## 8. Call back into Elixir

`c.Callback(module, function, args...)` runs an Elixir function and
returns its result. The `progress` handler above calls this module:

```elixir
defmodule MyApp.Progress do
  require Logger

  def report(step) do
    Logger.info("text_tools progress: step #{step}")
    :ok
  end
end
```

```elixir
iex> Portals.Pool.call(MyApp.Go, "text_tools", "progress", [3])
{:ok, 3}
```

The callback blocks only the handler's goroutine. Use
`c.CallbackContext(ctx, ...)` to bound it with a context. A failing Elixir
function returns a `*portals.Error`.

## 9. Send messages to Elixir processes

`args.Pid(i)` reads a PID argument, and `c.SendMessage(pid, value)`
delivers a value to it:

```elixir
iex> Portals.Pool.call(MyApp.Go, "text_tools", "notify", [self(), "hi"])
{:ok, "sent"}
iex> flush()
{:portals_message, #PID<0.312.0>, "HI"}
```

## 10. Stream

`HandleStream` registers a streaming target. `s.Recv()` returns the next
inbound chunk, or `io.EOF` once Elixir half-closes its side. `s.Send()`
blocks while Elixir's credit window is full. The returned value is the
stream's final result.

```elixir
{:ok, worker} = Portals.start_worker(Portals.Go.worker_opts(binary: Application.app_dir(:my_app, "priv/bin/text_worker")))

{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 3} = Portals.Stream.await(stream)
```

`RecvTimeout`/`SendTimeout` take a `time.Duration`, and `s.HalfClose()`
closes your side early.

## 11. Deploy

- In Docker, run `mix deps.get` before `go build`: the `replace` directive
  needs `deps/portals_go` to exist. A multi-stage build can copy `deps/`
  and your Go sources into a `golang` stage, build the binary into
  `priv/bin/`, and copy it into the release stage.
- Build for the release machine's platform. Cross-compile with
  `GOOS=linux GOARCH=amd64`, and use `CGO_ENABLED=0` for a static binary
  that runs on minimal images.
- The runtime image needs no Go toolchain, only the binary from `priv/`.

## Values

| Elixir | Go (decoded) | Go (accepted when returning) |
|---|---|---|
| `nil`, `true`, `false` | `nil`, `bool` | same |
| integer | `int64`; `uint64` above `math.MaxInt64`; `*big.Int` beyond 64 bits | any integer type, `*big.Int` |
| float | `float64` | `float64`, `float32` |
| string | `string` | `string` |
| `%Portals.Codec.Bin{data: bytes}` | `[]byte` | `[]byte` |
| list | `[]any` | any slice or array |
| map | `map[string]any` | any string-keyed map |
| tuple / atom | `portals.Tuple` / `portals.Atom` | same |
| PID / reference | `portals.Pid` / `portals.Reference` (opaque, comparable) | same |
| improper list | `portals.ImproperList` | same |

`portals.Args` has typed accessors (`Int`, `BigInt`, `Float`, `String`,
`Bytes`, `Bool`, `Pid`, `List`, `Map`, `Get`) that return an
`*portals.ArgumentError` on a type mismatch.

## Handler API

| `*portals.Call` method | Meaning |
|---|---|
| `Callback(mod, fun, args...)` | Call an Elixir function and wait for its result |
| `CallbackContext(ctx, mod, fun, args...)` | The same, bounded by `ctx` |
| `SendMessage(pid, value)` | Fire-and-forget message to a PID |
| `Context()` | Cancelled when Elixir cancels the call or stream |
| `Cancelled()` | `true` once Elixir has cancelled the call |
| `DeadlineMS()` | The `:deadline_ms` the caller attached, and whether there was one |
| `CallbackDepth()` | How deeply nested in callbacks the current call is |

## Gotchas

- **Rebuild after upgrading `portals_go`.** The protocol handshake requires
  the binary's SDK to match the BEAM exactly, so a binary built against an
  older `deps/portals_go` fails to start after `mix deps.update`. Rebuild
  it as part of every build, as with the alias above.
- **Every target must be registered.** A `CALL` to an unregistered
  module/function returns a remote `*portals.UndefinedError`; there is no
  reflection-based lookup.
- **Integers decode as `int64`.** `args.Int(i)` returns `int64`, and a raw
  `args.Get(i)` holds `int64`, `uint64` or `*big.Int`. Don't type-assert to
  `int`.
- **Wrap raw bytes in `%Portals.Codec.Bin{}`.** Wrapped bytes arrive as
  `[]byte` and plain binaries as `string`, so use `args.Bytes(i)` for
  binary payloads.
- **Logs go nowhere by default.** stdout and stderr are discarded under the
  default transport. Set `PORTALS_LOG_FILE`, or set `Options.Logger`. Plain
  `log.Printf` output is discarded too.
- **The binary is platform-specific.** A binary built on macOS won't run in
  a Linux container. Build in the image, or cross-compile.

## Best practices

- Pass `c.Context()` to everything a handler does (HTTP requests, database
  queries), so a cancelled call stops promptly.
- Validate arguments with the typed `args` accessors and return their
  errors as-is. They report clear `ArgumentError`s to Elixir.
- Keep shared state behind a `sync.Mutex` or in goroutine-safe types.
  Handlers run concurrently.
- Return `map[string]any`, slices, strings and numbers, not structs.
  Convert structs to maps first.
- Commit `go.mod` with the relative `replace` and rebuild the binary in CI
  and in your release build, never by hand.
