# Ruby

Run Ruby code from Elixir in supervised, pooled Ruby processes. The
`portals_ruby` package bundles a dependency-free Ruby worker SDK and puts
it on each worker's `RUBYLIB`, so `require 'portals'` works without
installing a gem. Your own gems keep working through Bundler or whatever
Ruby you point it at.

**Requirements:** Ruby 3.0 or newer on the machine that runs the workers
(tested on 3.3). The SDK uses only the standard library.

This page walks through a complete worker, a `text_tools` module that
counts words, parses integers, reports progress back to Elixir, messages a
process and streams text. The same example exists for every language, and
the code below is exactly the code Portals' own test suite runs.

## 1. Install

```elixir
# mix.exs
def deps do
  [
    {:portals_ruby, "~> 0.1.0"}
  ]
end
```

`portals_ruby` depends on `portals`, so this is the only line you need.

## 2. Write the handlers

Handlers are module functions. `extend Portals::StreamHandlers` provides
`stream_handler`, which marks a method as a streaming target.

```ruby
# priv/ruby/text_tools.rb
# frozen_string_literal: true

require 'portals'

module TextTools
  extend Portals::StreamHandlers
  module_function

  def word_count(text)
    text.split.length
  end

  def parse_int(text)
    Integer(text) # an ArgumentError becomes %Portals.Error{kind: :remote}
  end

  def progress(steps)
    (1..steps).each do |step|
      # Blocks this handler's thread until MyApp.Progress.report/1 returns.
      Portals.callback('Elixir.MyApp.Progress', 'report', [step])
    end
    steps
  end

  def notify(pid, text)
    Portals.send_message(pid, text.upcase) # fire-and-forget
    'sent'
  end

  stream_handler def upcase_stream(stream)
    count = 0
    while (chunk = stream.recv) # nil once the BEAM half-closes its side
      stream.send(chunk.upcase) # blocks while the BEAM's credit is used up
      count += 1
    end
    count # the stream's final result
  end
end
```

## 3. Write the entry script

```ruby
# priv/ruby/worker.rb
# frozen_string_literal: true

# Portals starts this script and appends the socket path as the last argument.
require 'portals'
require_relative 'text_tools'

Portals::Worker.new(
  max_concurrency: 8,
  max_streams: 4,
  modules: { 'text_tools' => TextTools }
).run
```

`modules:` maps the name Elixir uses in `CALL` to the Ruby module. Without
an entry, the SDK looks for an existing constant (`"text_tools"` ->
`TextTools`) or tries to `require` a file of that name from `$LOAD_PATH`.
Registering explicitly is faster, and it means only the modules you list
are reachable. `max_concurrency` is the size of the worker's call thread
pool. `max_streams` is a separate pool for streams, so long-lived streams
never starve ordinary calls.

## 4. Start a pool

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Portals.Pool,
     Portals.Ruby.worker_opts(
       script: Application.app_dir(:my_app, "priv/ruby/worker.rb"),
       name: MyApp.Ruby,
       size: 4
     )}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

| Option | Default | Use it for |
|---|---|---|
| `:ruby` | `"ruby"` | A specific interpreter, e.g. `Path.expand("~/.rbenv/shims/ruby")` |
| `:ruby_args` | `[]` | Interpreter flags, e.g. `["-W0"]` |
| `:args` | `[]` | Arguments to your script (before the socket path Portals appends) |
| `:env` | `[]` | Extra environment variables; they win over the ones Portals sets |

To run under Bundler, make `bundle` the interpreter and keep `RUBYLIB`
(which `bundle exec` preserves):

```elixir
Portals.Ruby.worker_opts(
  script: Application.app_dir(:my_app, "priv/ruby/worker.rb"),
  ruby: "bundle",
  ruby_args: ["exec", "ruby"],
  env: [{"BUNDLE_GEMFILE", Application.app_dir(:my_app, "priv/ruby/Gemfile")}]
)
```

## 5. Call it

```elixir
iex> Portals.Pool.call(MyApp.Ruby, "text_tools", "word_count", ["hello world"])
{:ok, 2}

iex> Portals.Pool.call(MyApp.Ruby, "text_tools", "parse_int", ["12"])
{:ok, 12}
```

## 6. Errors

```elixir
iex> {:error, error} = Portals.Pool.call(MyApp.Ruby, "text_tools", "parse_int", ["nope"])
iex> error.kind
:remote
iex> error.remote["exception_type"]
"ArgumentError"
```

`error.message` holds the exception message and `error.stacktrace` the
worker-side stack trace as a list of strings. Use `Portals.Pool.call!/5` to
raise `Portals.CallError` instead.

## 7. Call back into Elixir

`Portals.callback(module, function, args)` runs an Elixir function and
returns its result to Ruby. The `progress` handler above calls this
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
iex> Portals.Pool.call(MyApp.Ruby, "text_tools", "progress", [3])
{:ok, 3}
```

The callback blocks only the handler's own thread. Pass `timeout:`
(seconds) to bound the wait. A failing Elixir function raises
`Portals::RemoteError`, and a timeout raises `Portals::CallbackTimeout`.

## 8. Send messages to Elixir processes

A PID passed as an argument arrives as an opaque `Portals::Pid`:

```elixir
iex> Portals.Pool.call(MyApp.Ruby, "text_tools", "notify", [self(), "hi"])
{:ok, "sent"}
iex> flush()
{:portals_message, #PID<0.312.0>, "HI"}
```

## 9. Stream

`stream.recv` returns the next inbound chunk, or `nil` once Elixir
half-closes its side (`stream.each` iterates the same way). `stream.send`
blocks while Elixir's credit window is full. The method's return value is
the stream's final result.

```elixir
{:ok, worker} = Portals.start_worker(Portals.Ruby.worker_opts(script: Application.app_dir(:my_app, "priv/ruby/worker.rb")))

{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 3} = Portals.Stream.await(stream)
```

`stream.recv(timeout)` and `stream.send(chunk, timeout:)` take seconds and
raise `Portals::StreamTimeout`. `stream.half_close` closes your side early.

## 10. Deploy

- Keep the Ruby files in `priv/ruby/` and build paths with
  `Application.app_dir(:my_app, "priv/ruby/...")`. `mix release` copies
  `priv/`, including the SDK bundled in `portals_ruby`.
- The release machine needs Ruby and your gems installed. With Bundler,
  run `bundle install` (or `bundle install --deployment`) in the image and
  use the Bundler options above.
- `mix portals.sdk_path ruby` prints the SDK's `lib` directory. Point
  Solargraph or Ruby LSP at it (for example via `RUBYLIB`) so `require
  'portals'` resolves in your editor.

## Values

| Elixir | Ruby | Back to Elixir |
|---|---|---|
| `nil`, `true`, `false` | `nil`, `true`, `false` | same |
| integer (any size) | `Integer` | integer |
| float | `Float` | float; wrap in `Portals::Float64` to force a float for an integral value |
| string | `String` (UTF-8) | string |
| `%Portals.Codec.Bin{data: bytes}` | `String` (BINARY encoding) | a BINARY-encoded `String` or `Portals::Bin` becomes `%Portals.Codec.Bin{}` |
| list | `Array` | list |
| tuple | `Portals::Tuple` (`.to_a`) | tuple |
| map | `Hash` with `String` keys | map with string keys |
| atom | `Symbol` | atom, if it already exists |
| PID / reference | `Portals::Pid` / `Portals::Reference` (opaque) | the same PID / reference |
| improper list | `Portals::ImproperList` | improper list |

## Handler API

| Method | Meaning |
|---|---|
| `Portals.callback(mod, fun, args, timeout: nil)` | Call an Elixir function and wait for its result |
| `Portals.send_message(pid, value)` | Fire-and-forget message to a PID |
| `Portals.cancelled?` | `true` once Elixir has cancelled the current call |
| `Portals.current_deadline_ms` | The `:deadline_ms` the caller attached, or `nil` |
| `Portals.current_callback_depth` | How deeply nested in callbacks the current call is |

## Gotchas

- **The GVL limits each worker to one core of Ruby code.** Threads help
  with I/O-bound handlers. For CPU-bound work, scale with pool `:size`.
- **Symbols are atoms, and unknown atoms close the connection.** A `Symbol`
  you return becomes an atom on the BEAM, which only decodes atoms that
  already exist. Returning `:some_new_symbol` is treated as a protocol
  violation: the worker's connection is closed and every call in flight on
  it fails. Return strings for open-ended values, and symbols only for a
  fixed set your Elixir code also uses.
- **BINARY strings become raw bytes.** Strings read from sockets or files
  in binary mode (`File.binread`, `Net::HTTP` bodies) have BINARY encoding
  and reach Elixir as `%Portals.Codec.Bin{}`. Call
  `.force_encoding(Encoding::UTF_8)` on text before returning it.
- **The script directory is not on `$LOAD_PATH`.** Use `require_relative`
  for your own files, as in `worker.rb` above, or register modules
  explicitly.
- **Logs go nowhere by default.** stdout and stderr are discarded under the
  default transport. Set `PORTALS_LOG_FILE` (via `:env`) to send the SDK's
  log lines to a file, or pass `logger: ->(message) { ... }` to
  `Portals::Worker.new`.
- **Code is loaded once.** Changes to Ruby files take effect only after the
  worker restarts.
- **Cancellation is cooperative.** Long handlers must poll
  `Portals.cancelled?` and return early.

## Best practices

- Register every module in `modules:`. It documents the worker's surface
  and keeps arbitrary constants from being callable.
- Load heavy libraries once at the top of the handler file, not inside the
  handler. Note that `worker.rb` must finish loading and connect within
  `connect_timeout:` (default 5 seconds).
- Make shared state thread-safe (`Mutex`, `Concurrent::Map`). Handlers run
  on up to `max_concurrency` threads at once.
- Return plain data: hashes, arrays, strings and numbers. Convert
  ActiveRecord models and other objects with `as_json` or `to_h` first.
