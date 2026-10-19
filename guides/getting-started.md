# Getting started

Portals runs code written in another language inside supervised OS
processes ("workers") and lets Elixir call it like a function. Each worker
is a normal program in its own language that imports a small Portals SDK;
the BEAM launches it, talks to it over a private Unix-domain socket, and
restarts or fails it like any other OTP process.

This page covers what is the same for every language. Each language has
its own page with a complete walkthrough:
[Python](python.html), [Ruby](ruby.html), [JavaScript](javascript.html),
[PHP](php.html), [Java](java.html) and [Go](go.html).

For a working app that uses all six languages at once, see
[`examples/hello_live`](https://github.com/Ziinc/portals/tree/main/examples/hello_live),
a Phoenix LiveView page that calls a hello-world function in each.

## Packages

Core `portals` contains the Elixir side only: pools, the connection state
machine, the wire protocol and the conformance kit. Each language is a
separate package that bundles its worker SDK, so you install only the
languages you use:

| Language | Package | Elixir module | Runtime needed on the host |
|---|---|---|---|
| Python | `portals_python` | `Portals.Python` | Python 3 |
| Ruby | `portals_ruby` | `Portals.Ruby` | Ruby 3.0+ |
| JavaScript | `portals_javascript` | `Portals.JavaScript` | Node.js 18+ (default), Bun, Deno 2 or QuickJS-ng |
| PHP | `portals_php` | `Portals.PHP` | PHP 8.1+ (64-bit) |
| Java | `portals_java` | `Portals.Java` | JDK 17+ |
| Go | `portals_go` | `Portals.Go` | Go 1.21+ to build |

Every package is published to Hex only. The SDKs are never installed
from PyPI, RubyGems, npm, Packagist, Maven or the Go module proxy: they live
in the package's `priv/` directory and the language module puts them on
the worker's import path for you. All packages are released in lockstep,
at the same version as `portals`.

```elixir
def deps do
  [
    {:portals_python, "~> 0.1.0"},
    {:portals_javascript, "~> 0.1.0"}
  ]
end
```

A language package depends on `portals`, so you don't list `portals`
itself.

## The shape of every integration

1. **Handlers**: ordinary functions in the other language.
2. **An entry script** (or main class or binary) that creates a `Worker`
   and calls `run()`. Portals passes it the socket path as its last
   command-line argument; the SDK reads it from there.
3. **A pool** in your supervision tree, configured with the language
   module's `worker_opts/1`.
4. **Calls** from Elixir: `Portals.Pool.call(pool, module, function, args)`.

```elixir
children = [
  {Portals.Pool,
   Portals.Python.worker_opts(
     script: Application.app_dir(:my_app, "priv/python/worker.py"),
     name: MyApp.Python,
     size: 4
   )}
]

{:ok, 2} = Portals.Pool.call(MyApp.Python, "text_tools", "word_count", ["hello world"])
```

`module` and `function` are strings in the worker's naming scheme, for
example a Python module path or a name registered with the worker. The
arguments are a list of values; see "Values" below.

## Pools

`Portals.Pool` keeps `size` workers running and can start up to
`max_overflow` temporary ones under load. Each worker serves many calls at
once, up to the concurrency it advertises (`max_concurrency` in its SDK).
The pool sends each call to the least-busy worker.

| Option | Default | Meaning |
|---|---|---|
| `:size` | required | Workers kept running |
| `:max_overflow` | `0` | Extra temporary workers when all are at capacity |
| `:checkout_timeout` | `5_000` | How long a call waits for capacity before `{:error, %Portals.Error{kind: :checkout_timeout}}` |
| `:name` | none | Register the pool, so it can be called by name |
| `:callback_allowlist` | `nil` (any) | `[{module, function, arity}]` the workers may call back into |
| `:cd` | BEAM's cwd | Working directory for the worker processes |
| `:env` | `[]` | Extra environment variables |

Per-call options: `:timeout` (how long the caller waits, default `5_000`)
and `:deadline_ms` (a deadline passed to the worker, which handlers can
read).

For a single unpooled worker, use `Portals.start_worker/1` with the same
options and `Portals.call/5`. Streams currently need a single worker (see
"Streaming").

## Errors

Every failure is `{:error, %Portals.Error{}}`, never a raise (except from
the `call!` variants). `kind` tells you what happened:

| `kind` | Meaning |
|---|---|
| `:remote` | The handler raised; `message`, `remote["exception_type"]` and `stacktrace` come from the worker |
| `:execution_timeout` | No reply within `:timeout` |
| `:checkout_timeout` | Every worker was at capacity for `:checkout_timeout` |
| `:worker_exit` | The worker process died; every call in flight on it gets this error |
| `:protocol` | The worker sent malformed data; only that worker is closed |
| `:cancelled` | A stream was cancelled, or its owning process exited |
| `:transport` | The socket to the worker failed |
| `:overload` | The worker refused the call (for example, too many streams) |

`Portals.cancel/1` is cooperative: it tells the worker the call was
cancelled, and the handler decides what to return (each SDK exposes a
"cancelled?" check). The caller still receives that terminal result.

## Callbacks and messages

A handler can call back into Elixir while it runs, for example to report
progress or to fetch data:

```python
portals.callback("Elixir.MyApp.Progress", "report", [step])
```

and can send a message to any PID it was given:

```python
portals.send_message(pid, {"done": True})
```

which arrives as `{:portals_message, worker_pid, value}` (or the bare
value with `message_envelope: :raw`).

## Streaming

`Portals.open_stream/5` opens a bidirectional stream on a single worker.
Both sides send chunks; each direction has a byte-credit window, so a slow
consumer slows the producer down instead of growing memory without bound.

```elixir
{:ok, worker} = Portals.start_worker(Portals.Python.worker_opts(script: "priv/python/worker.py"))
{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b"])
["A", "B"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 2} = Portals.Stream.await(stream)
```

## Values

Values are encoded with the Erlang External Term Format (or, with
`codec: :msgpack`, MessagePack plus Erlang extensions; handlers see the same
values either way), so most Elixir terms survive a round trip:

| Elixir | Notes |
|---|---|
| `nil`, booleans, integers, floats | Integers of any size. Floats stay floats. |
| strings (UTF-8 binaries) | Arrive as the language's string type |
| `%Portals.Codec.Bin{data: bytes}` | Raw bytes. **Wrap any binary that is not valid UTF-8.** |
| lists, tuples, improper lists | Tuples and improper lists use SDK wrapper types |
| maps | Keys become strings: `%{a: 1}` and `%{1 => 2}` come back as `%{"a" => 1}` and `%{"1" => 2}` |
| atoms | SDK `Atom` wrapper types. Only atoms that already exist on the BEAM are decoded. |
| PIDs, references | Opaque. Pass them back, or use them as message targets. |
| charlists | Plain lists of integers |

## Gotchas (all languages)

- **Wrap raw bytes in `%Portals.Codec.Bin{}`.** Elixir binaries are sent as
  text. Under the default ETF codec, a call carrying a binary that is not
  valid UTF-8 is rejected by the worker before it runs, so it times out.
  Under `codec: :msgpack` the bytes are corrupted or rejected depending on
  the language; in Python that closes the worker's connection.
- **Only return atoms the BEAM already knows.** A worker that sends an
  atom which does not exist on the BEAM (to stop atom-table exhaustion,
  Portals never creates atoms from worker input) breaks the protocol: the
  worker's connection is closed and every call in flight on it fails. Send
  strings for open-ended values.
- **Callback targets need the `Elixir.` prefix and must exist.** Name the
  module as `"Elixir.MyApp.Progress"`, not `"MyApp.Progress"`. The module
  and function atoms must already exist on the BEAM, so the module must be
  loaded (it is in a release; in tests, call `Code.ensure_loaded!/1`).
- **`:timeout` only stops the caller waiting.** The handler keeps running,
  the call keeps its slot in the worker's concurrency budget until it
  returns, and its late reply is dropped into the caller's mailbox as a
  `{:portals_result, ...}` message. Keep handlers bounded, honor
  `:deadline_ms` inside long handlers, and for work you may abandon use
  `Portals.async/5`, then `Portals.cancel/1` with a handler that checks its
  SDK's cancelled flag.
- **Worker stdout and stderr are discarded** under the default Unix-socket
  transport. A `print` or a crash traceback written there never reaches your
  logs. Log to a file (`PORTALS_LOG_FILE` in the Ruby, JavaScript, PHP, Java and
  Go SDKs; the `logging` module in Python).
- **Streams are per worker.** `Portals.Pool` has no streaming API; open
  streams on a dedicated `Portals.start_worker/1` worker.
- **Give each pool its own child id.** Two `{Portals.Pool, ...}` children in
  one supervisor need `Supervisor.child_spec({Portals.Pool, opts}, id: MyApp.Python)`.
- **The working directory is the BEAM's.** Use absolute paths
  (`Application.app_dir/2`) for scripts and data files, or pass `:cd`.
- **Unix socket paths are limited to about 100 bytes.** Sockets live under
  `$PORTALS_RUNTIME_DIR` (default `System.tmp_dir!()/portals`). If your
  temp directory has a long path, set `PORTALS_RUNTIME_DIR` to something
  short.
- **Portals owns only the direct worker process.** Processes your handler
  spawns are not killed with the worker. Use a container or process group
  if you need that.
- **Workers are trusted.** Process isolation is not a sandbox. Never let
  user input choose the `module`/`function` names: in Python, for example,
  any importable module, `os` included, is callable.

## Best practices (all languages)

- Build `worker_opts/1` with `Application.app_dir(:my_app, "priv/...")`
  paths so they work identically in development and in releases.
- Size pools for CPU parallelism and `max_concurrency` for I/O
  concurrency. Most runtimes have a global lock or a single event loop, so
  one worker rarely uses more than one core.
- Set `:callback_allowlist` in production so a worker can only call the
  functions it is meant to.
- Pass plain data (maps, lists, strings, numbers) across the boundary and
  keep language objects on their own side.
- Treat the worker like a microservice: keep it stateless where possible so
  a restart loses nothing, and make module and function names constants in
  your Elixir code.
