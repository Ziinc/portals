# Portals Ruby worker SDK

A Ruby worker for [Portals](../../README.md), implementing the v1 wire
protocol in [`protocol/v1.md`](../../protocol/v1.md) with full parity with
the reference Python SDK.

No gems required: the MessagePack codec (including the Erlang value
extensions) is implemented in pure Ruby in `lib/portals/msgpack_codec.rb`,
so a worker only needs a stock Ruby interpreter.

## Writing a worker

```ruby
# my_handlers.rb
require 'portals'

module MyHandlers
  extend Portals::StreamHandlers
  module_function

  def encode(text)
    { 'length' => text.length }
  end

  def with_progress(n)
    # Reentrant callback back into the BEAM; blocks this handler's thread,
    # never the socket reader.
    Portals.callback('MyApp.Progress', 'report', [n])
    n * 2
  end

  def notify(pid, value)
    Portals.send_message(pid, value) # fire-and-forget to a BEAM PID
    :ok
  end

  stream_handler def echo_stream(stream)
    count = 0
    while (chunk = stream.recv)   # blocks until credit-backed data arrives
      stream.send(chunk)          # blocks until the BEAM grants credit
      count += 1
    end
    count                         # becomes the stream's terminal RETURN
  end
end
```

```ruby
#!/usr/bin/env ruby
# run_worker.rb — Portals appends the socket path as the last CLI argument
require 'portals'
require 'my_handlers'

Portals::Worker.new(max_concurrency: 16, max_streams: 8).run
```

From Elixir:

```elixir
{:ok, conn} = Portals.start_worker(command: "ruby", args: ["run_worker.rb"])
{:ok, %{"length" => 5}} = Portals.call(conn, "my_handlers", "encode", ["hello"])
{:ok, stream} = Portals.open_stream(conn, "my_handlers", "echo_stream", [])
```

## Dispatch

`CALL`'s `module` names a registered module, an existing constant, or a
requirable file whose camelized basename is the module (`"my_handlers"` ->
`MyHandlers`). Register explicitly to skip the lookup:

```ruby
Portals::Worker.new(modules: { 'my_handlers' => MyHandlers }).run
```

## Handler context

| Helper | Meaning |
|---|---|
| `Portals.callback(mod, fun, args, timeout:)` | Reentrant call back into the BEAM |
| `Portals.send_message(pid, value)` | Fire-and-forget message to a BEAM PID |
| `Portals.current_callback_depth` | Reentrancy depth of the current CALL |
| `Portals.current_deadline_ms` | Deadline the BEAM attached to this CALL |
| `Portals.cancelled?` | True once the BEAM sent `CANCEL` for this CALL |

## Logging

Never over the RPC protocol: set `PORTALS_LOG_FILE` for a file sink, or pass
`logger: ->(message) { ... }` to `Worker.new`.

## Transports

`transport: :unix` (default) or `transport: :stdio` for the framed
stdin/stdout fallback.

## Tests

```sh
rake            # or: ruby test/test_msgpack_codec.rb && ruby test/test_streams.rb
```

The cross-language conformance and integration suites live on the Elixir
side: `mix test test/conformance/sdk_conformance_test.exs
test/integration/ruby_worker_test.exs`.
