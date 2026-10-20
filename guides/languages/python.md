# Python

Run Python code from Elixir in supervised, pooled Python processes. The
`portals_python` package bundles a dependency-free Python worker SDK (the
`portals` Python package) and puts it on each worker's `PYTHONPATH`. You
never `pip install` anything for Portals itself, and your own Python
dependencies keep working through whatever interpreter or virtualenv you
point it at.

**Requirements:** Python 3 on the machine that runs the workers (the SDK is
tested on Python 3.13). The SDK uses only the standard library.

This page walks through a complete worker, a `text_tools` module that
counts words, parses integers, reports progress back to Elixir, messages a
process and streams text. The same example exists for every language, and
the code below is exactly the code Portals' own test suite runs.

## 1. Install

```elixir
# mix.exs
def deps do
  [
    {:portals_python, "~> 0.1.0"}
  ]
end
```

`portals_python` depends on `portals`, so this is the only line you need.

## 2. Write the handlers

A handler is a plain module-level function. Portals imports the module with
`importlib.import_module`, so any module importable from the worker can be
called. Put this next to the entry script:

```python
# priv/python/text_tools.py
import portals


def word_count(text):
    return len(text.split())


def parse_int(text):
    return int(text)  # a ValueError becomes %Portals.Error{kind: :remote}


def progress(steps):
    for step in range(1, steps + 1):
        # Blocks this handler's thread until MyApp.Progress.report/1 returns.
        portals.callback("Elixir.MyApp.Progress", "report", [step])
    return steps


def notify(pid, text):
    portals.send_message(pid, text.upper())  # fire-and-forget
    return "sent"


@portals.stream_handler
def upcase_stream(stream):
    count = 0
    for chunk in stream:  # ends when the BEAM half-closes its side
        stream.send(chunk.upper())  # blocks while the BEAM's credit is used up
        count += 1
    return count  # the stream's final result
```

## 3. Write the entry script

The entry script creates a `Worker` and runs it. `from portals import
Worker` works because `Portals.Python.worker_opts/1` puts the SDK on
`PYTHONPATH`. Python adds the script's own directory to `sys.path`, so
`text_tools` is importable.

```python
# priv/python/worker.py
# Portals starts this script and appends the socket path as the last argument.
from portals import Worker

Worker(max_concurrency=8, max_streams=4).run()
```

`max_concurrency` is how many calls this worker runs at once (one thread
each); `max_streams` is a separate budget for streams, so long-lived
streams never starve ordinary calls.

## 4. Start a pool

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Portals.Pool,
     Portals.Python.worker_opts(
       script: Application.app_dir(:my_app, "priv/python/worker.py"),
       name: MyApp.Python,
       size: 4
     )}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

`worker_opts/1` turns `:script` into the generic `:command`/`:args`/`:env`
options. Other options include:

| Option | Default | Use it for |
|---|---|---|
| `:python` | `"python3"` | A virtualenv: `python: Path.expand(".venv/bin/python")`, no activation needed |
| `:python_args` | `[]` | Interpreter flags, e.g. `["-X", "dev"]` or `["-O"]` |
| `:args` | `[]` | Arguments to your script (before the socket path Portals appends) |
| `:env` | `[]` | Extra environment variables; they win over the ones Portals sets |

Everything else (`:name`, `:size`, `:max_overflow`, `:checkout_timeout`,
`:callback_allowlist`, ...) is passed to `Portals.Pool` unchanged.

## 5. Call it

```elixir
iex> Portals.Pool.call(MyApp.Python, "text_tools", "word_count", ["hello world"])
{:ok, 2}

iex> Portals.Pool.call(MyApp.Python, "text_tools", "parse_int", ["12"])
{:ok, 12}
```

`"text_tools"` is the Python module name and `"word_count"` the function.
Dotted names work too: `"myapp.text.tools"` imports the `myapp.text.tools`
module.

## 6. Errors

An exception raised by a handler becomes a structured error. Nothing
crashes on either side:

```elixir
iex> {:error, error} = Portals.Pool.call(MyApp.Python, "text_tools", "parse_int", ["nope"])
iex> error.kind
:remote
iex> error.remote["exception_type"]
"ValueError"
```

`error.message` holds the exception message and `error.stacktrace` the
worker-side stack trace as a list of strings. Use `Portals.Pool.call!/5` to
raise `Portals.CallError` instead.

## 7. Call back into Elixir

`portals.callback(module, function, args)` runs an Elixir function and
returns its result to Python. The `progress` handler above calls this
module:

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
iex> Portals.Pool.call(MyApp.Python, "text_tools", "progress", [3])
{:ok, 3}
```

The callback blocks only the handler's own thread. The worker keeps
serving other calls, including calls the callback itself makes back into
the same worker. Pass `timeout=` (seconds) to bound the wait; a failing
Elixir function raises `portals.RemoteError` in Python.

## 8. Send messages to Elixir processes

A PID passed as an argument arrives as an opaque `portals.Pid`.
`portals.send_message(pid, value)` delivers `value` to it, wrapped as
`{:portals_message, worker_pid, value}`:

```elixir
iex> Portals.Pool.call(MyApp.Python, "text_tools", "notify", [self(), "hi"])
{:ok, "sent"}
iex> flush()
{:portals_message, #PID<0.312.0>, "HI"}
```

Delivery is fire-and-forget, like `send/2`: no acknowledgement, and no
error if the process is gone.

## 9. Stream

Mark a function with `@portals.stream_handler` and it receives a
`portals.Stream` as its first argument. Iterating it yields inbound chunks
until Elixir half-closes its side. `stream.send/1` blocks while Elixir's
credit window is full, so neither side can outrun the other. The return
value is the stream's final result.

Pools don't stream, so open streams on a dedicated worker:

```elixir
{:ok, worker} = Portals.start_worker(Portals.Python.worker_opts(script: Application.app_dir(:my_app, "priv/python/worker.py")))

{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 3} = Portals.Stream.await(stream)
```

Inside the handler you can also call `stream.recv(timeout=...)`,
`stream.send_all(iterable)` and `stream.half_close()`.

## 10. Deploy

- Keep the Python files in `priv/python/` and always build paths with
  `Application.app_dir(:my_app, "priv/python/...")`. `mix release` copies
  `priv/`, including the SDK bundled in `portals_python`.
- The release machine needs a Python interpreter and your Python
  dependencies. In Docker, install them in the runtime image and point
  `:python` at that interpreter, for example
  `python: "/opt/venv/bin/python"`.
- `mix portals.sdk_path python` prints the SDK directory. Add it to your
  editor's or type checker's extra paths (Pyright `extraPaths`, mypy
  `mypy_path`) so `import portals` resolves there too.

## Values

| Elixir | Python | Back to Elixir |
|---|---|---|
| `nil`, `true`, `false` | `None`, `True`, `False` | same |
| integer (any size) | `int` | integer |
| float | `float` | float |
| string | `str` | string |
| `%Portals.Codec.Bin{data: bytes}` | `bytes` | `%Portals.Codec.Bin{}`; return `bytes` to send raw bytes |
| list | `list` | list |
| tuple | `tuple` | tuple |
| map | `dict` with `str` keys | map with string keys |
| atom | `portals.Atom` (`.name`) | atom, if it already exists |
| PID / reference | `portals.Pid` / `portals.Reference` (opaque) | the same PID / reference |
| improper list | `portals.ImproperList` | improper list |

## Handler API

| Function | Meaning |
|---|---|
| `portals.callback(module, function, args, timeout=None)` | Call an Elixir function and wait for its result |
| `portals.send_message(pid, value)` | Fire-and-forget message to a PID |
| `portals.cancelled()` | `True` once Elixir has cancelled the current call (`Portals.cancel/1`) |
| `portals.current_deadline_ms()` | The `:deadline_ms` the caller attached, or `None` |
| `portals.current_callback_depth()` | How deeply nested in callbacks the current call is |

## Gotchas

- **The GIL limits each worker to one core of Python bytecode.**
  `max_concurrency` threads help with I/O-bound handlers and C extensions
  that release the GIL (NumPy and friends). For CPU-bound pure Python,
  scale with pool `:size`, not `max_concurrency`.
- **Wrap raw bytes in `%Portals.Codec.Bin{}`.** A plain Elixir binary is
  sent as text. If it is not valid UTF-8, the worker rejects the call
  before it runs, so it times out (under `codec: :msgpack` the worker
  instead **closes its connection**, failing every call in flight on it).
  Image data, hashes and other binary payloads must be wrapped.
- **Any importable module is callable.** `CALL` imports whatever module it
  names, `os` and `subprocess` included. Never build module or function
  names from user input, and keep them as constants in Elixir.
- **Modules are imported once.** Editing a `.py` file has no effect until
  the worker restarts. In development, restart the pool (or the app) after
  changing Python code.
- **`print` output is discarded.** Under the default transport, stdout and
  stderr go nowhere. Use the `logging` module with a `FileHandler`. The SDK
  logs as `portals.worker`.
- **Dict keys come back as strings.** `%{a: 1}` and `%{1 => 2}` arrive in
  Python as `{"a": 1}` and `{"1": 2}`, and return to Elixir with string
  keys.
- **Cancellation is cooperative.** `Portals.cancel/1` sets a flag; a long
  handler must poll `portals.cancelled()` and return early. Nothing
  interrupts a running thread.
- **The working directory is the BEAM's**, not the script's. Open data
  files relative to `os.path.dirname(__file__)`, or pass `cd:`.

## Best practices

- Pin the interpreter with `python: ` pointing at a virtualenv, so the
  worker never picks up whatever `python3` is first on `PATH`.
- Keep the entry script tiny and put handlers in modules. Registering one
  module per concern (`text_tools`, `embeddings`, ...) keeps the
  module/function names readable in Elixir and in telemetry.
- Do expensive setup (loading models, opening clients) once, at module
  import time, and share it across threads. A handler module is imported by
  the first call that names it, so that call pays for the import. To pay at
  startup instead, import the module in `worker.py` before
  `Worker(...).run()`, and raise `connect_timeout:` (default 5 seconds) if
  the import is slow: the worker must connect within it.
- Make shared state thread-safe. Handlers run concurrently on
  `max_concurrency` threads.
- Return plain data (dicts, lists, strings, numbers). Convert NumPy arrays
  and dataclasses before returning, e.g. `array.tolist()` or
  `dataclasses.asdict(obj)`.
- For long jobs, accept a deadline (`portals.current_deadline_ms()`) and
  check `portals.cancelled()` between steps.
