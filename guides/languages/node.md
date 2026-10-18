# Node.js

Run JavaScript from Elixir in supervised, pooled Node.js processes. The
`portals_node` package bundles a dependency-free worker SDK as the
`portals-worker` module and puts it on each worker's `NODE_PATH`, so
`require('portals-worker')` works without `npm install`. Your own npm
dependencies keep working from your project's `node_modules`.

**Requirements:** Node.js 18 or newer on the machine that runs the
workers. The SDK has no npm dependencies.

This page walks through a complete worker, a `text_tools` module that
counts words, parses integers, reports progress back to Elixir, messages a
process and streams text. The same example exists for every language, and
the code below is exactly the code Portals' own test suite runs.

## 1. Install

```elixir
# mix.exs
def deps do
  [
    {:portals_node, "~> 0.1.0"}
  ]
end
```

`portals_node` depends on `portals`, so this is the only line you need.

## 2. Write the handlers

Handlers are plain functions exported from a CommonJS module, and may be
`async`. Export them under the names Elixir will call.

```js
// priv/node/textTools.js
'use strict';

const portals = require('portals-worker');

const wordCount = (text) => text.split(/\s+/).filter(Boolean).length;

const parseInteger = (text) => {
  const n = Number.parseInt(text, 10);
  if (Number.isNaN(n)) throw new TypeError(`not an integer: ${text}`); // becomes %Portals.Error{kind: :remote}
  return n;
};

const progress = async (steps) => {
  for (let step = 1; step <= steps; step += 1) {
    // Awaits MyApp.Progress.report/1 without blocking other calls.
    await portals.callback('Elixir.MyApp.Progress', 'report', [step]);
  }
  return steps;
};

const notify = (pid, text) => {
  portals.sendMessage(pid, text.toUpperCase()); // fire-and-forget
  return 'sent';
};

const upcaseStream = portals.streamHandler(async (stream) => {
  let count = 0;
  for await (const chunk of stream) { // ends when the BEAM half-closes its side
    await stream.send(chunk.toUpperCase()); // waits while the BEAM's credit is used up
    count += 1;
  }
  return count; // the stream's final result
});

module.exports = {
  word_count: wordCount,
  parse_int: parseInteger,
  progress,
  notify,
  upcase_stream: upcaseStream,
};
```

## 3. Write the entry script

```js
// priv/node/worker.js
'use strict';

// Portals starts this script and appends the socket path as the last argument.
const { Worker } = require('portals-worker');

new Worker({
  maxConcurrency: 8,
  maxStreams: 4,
  modules: { text_tools: require('./textTools') },
})
  .run()
  .catch((err) => {
    process.stderr.write(`${err.stack}\n`);
    process.exit(1);
  });
```

`modules:` maps the name Elixir uses in `CALL` to a module object. Without
an entry, the SDK `require`s the name relative to `modulePaths` (default
`[process.cwd()]`, which is the BEAM's working directory, not the
script's). `maxConcurrency` bounds how many calls run at once.
`maxStreams` is a separate budget for streams.

## 4. Start a pool

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Portals.Pool,
     Portals.Node.worker_opts(
       script: Application.app_dir(:my_app, "priv/node/worker.js"),
       name: MyApp.Node,
       size: 4
     )}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

| Option | Default | Use it for |
|---|---|---|
| `:node` | `"node"` | A specific runtime, e.g. one installed by `nvm` or `asdf` |
| `:node_args` | `[]` | Runtime flags, e.g. `["--max-old-space-size=512"]` |
| `:args` | `[]` | Arguments to your script (before the socket path Portals appends) |
| `:env` | `[]` | Extra environment variables, e.g. `[{"NODE_ENV", "production"}]` |

## 5. Call it

```elixir
iex> Portals.Pool.call(MyApp.Node, "text_tools", "word_count", ["hello world"])
{:ok, 2}

iex> Portals.Pool.call(MyApp.Node, "text_tools", "parse_int", ["12"])
{:ok, 12}
```

## 6. Errors

A thrown error (or a rejected promise) becomes a structured error:

```elixir
iex> {:error, error} = Portals.Pool.call(MyApp.Node, "text_tools", "parse_int", ["nope"])
iex> error.kind
:remote
iex> error.remote["exception_type"]
"TypeError"
```

`error.message` holds the exception message and `error.stacktrace` the
worker-side stack trace as a list of strings. Use `Portals.Pool.call!/5` to
raise `Portals.CallError` instead.

## 7. Call back into Elixir

`await portals.callback(module, function, args)` runs an Elixir function
and resolves with its result. The `progress` handler above calls this
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
iex> Portals.Pool.call(MyApp.Node, "text_tools", "progress", [3])
{:ok, 3}
```

The fourth argument is a timeout in milliseconds. A failing Elixir
function rejects with `portals.RemoteError`, and a timeout with
`portals.CallbackTimeout`. Awaiting never blocks the worker's socket
reader, so other calls keep flowing.

## 8. Send messages to Elixir processes

A PID passed as an argument arrives as an opaque `portals.Pid`:

```elixir
iex> Portals.Pool.call(MyApp.Node, "text_tools", "notify", [self(), "hi"])
{:ok, "sent"}
iex> flush()
{:portals_message, #PID<0.312.0>, "HI"}
```

## 9. Stream

Wrap a handler in `portals.streamHandler(...)` and it receives a stream as
its first argument. `for await` yields inbound chunks until Elixir
half-closes its side, and `await stream.send(chunk)` waits while Elixir's
credit window is full. The resolved value is the stream's final result.

```elixir
{:ok, worker} = Portals.start_worker(Portals.Node.worker_opts(script: Application.app_dir(:my_app, "priv/node/worker.js")))

{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 3} = Portals.Stream.await(stream)
```

Streams also have `await stream.recv(timeoutMs)` (returns `null` at the
end), `await stream.sendAll(chunks)` and `stream.halfClose()`.

## 10. Deploy

- Keep the JavaScript in `priv/node/` (with its own `package.json` and
  `node_modules` if you use npm packages) and build paths with
  `Application.app_dir(:my_app, "priv/node/...")`. `mix release` copies
  `priv/`, including the SDK bundled in `portals_node`.
- Run `npm ci --omit=dev` for `priv/node` while building the release
  image, and install the same Node.js major version you develop with.
- `mix portals.sdk_path node` prints the SDK directory. For editor
  support, add its parent directory to `NODE_PATH`, or map
  `portals-worker` to it in `jsconfig.json` `paths`.

## Values

| Elixir | JavaScript | Back to Elixir |
|---|---|---|
| `nil`, `true`, `false` | `null`, `true`, `false` | same (`undefined` also becomes `nil`) |
| integer | `number`, or `BigInt` beyond 2^53 | integer |
| float | `number` | float if it has a fraction; use `portals.float(2)` to force `2.0` |
| string | `string` | string |
| `%Portals.Codec.Bin{data: bytes}` | `Buffer` | `%Portals.Codec.Bin{}` |
| list | `Array` | list |
| tuple | `portals.Tuple` | tuple |
| map | plain object | map with string keys |
| atom | `portals.Atom` | atom, if it already exists |
| PID / reference | `portals.Pid` / `portals.Ref` (opaque) | the same PID / reference |
| improper list | `portals.ImproperList` | improper list |

## Handler API

| Function | Meaning |
|---|---|
| `await portals.callback(mod, fun, args, timeoutMs)` | Call an Elixir function and await its result |
| `portals.sendMessage(pid, value)` | Fire-and-forget message to a PID |
| `portals.isCancelled()` | `true` once Elixir has cancelled the current call |
| `portals.currentDeadlineMs()` | The `:deadline_ms` the caller attached, or `null` |
| `portals.currentCallbackDepth()` | How deeply nested in callbacks the current call is |

The call context travels with `AsyncLocalStorage`, so these work after any
number of `await`s.

## Gotchas

- **One event loop per worker.** Concurrency comes from `async` I/O. A
  synchronous CPU-heavy handler blocks every other call on that worker,
  callbacks and streams included. Scale CPU work with pool `:size`, or move
  it to `worker_threads`.
- **ES modules don't read `NODE_PATH`.** In a `.mjs` worker,
  `import 'portals-worker'` fails with `ERR_MODULE_NOT_FOUND`. Use
  `createRequire`:

  ```js
  import { createRequire } from 'node:module';
  const require = createRequire(import.meta.url);
  const { Worker } = require('portals-worker');
  ```

- **`NODE_PATH` has the lowest priority.** A `portals-worker` package in a
  local `node_modules` would shadow the bundled SDK. Don't install one.
- **Large integers become `BigInt`.** Values beyond 2^53 arrive as `BigInt`,
  which doesn't mix with `number` arithmetic. Integral floats encode as
  integers unless wrapped in `portals.float()`.
- **Wrap raw bytes in `%Portals.Codec.Bin{}`.** A plain Elixir binary that
  is not valid UTF-8 is decoded as a string with the invalid bytes replaced
  by U+FFFD, so the data is silently corrupted. Wrapped bytes arrive as a
  `Buffer`.
- **`console.log` goes nowhere.** stdout and stderr are discarded under the
  default transport. Set `PORTALS_LOG_FILE`, or pass `logger: (message) =>
  ...` to `new Worker(...)` for the SDK's own logs.
- **Unregistered module names are resolved from the BEAM's working
  directory.** Register modules explicitly, or set `modulePaths: [__dirname]`.

## Best practices

- Register every module in `modules:` with `require('./...')` paths
  relative to the entry script.
- Make handlers `async` and await I/O. Never use synchronous file or
  network APIs (`fs.readFileSync`, `execSync`) in a handler.
- Create clients and caches at module load, and reuse them across calls.
- Return plain data (objects, arrays, strings, numbers, `Buffer`s). Class
  instances are encoded as plain objects with only their own enumerable
  properties.
- For long jobs, check `portals.isCancelled()` between steps and respect
  `portals.currentDeadlineMs()`.
