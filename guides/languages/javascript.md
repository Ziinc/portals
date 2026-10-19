# JavaScript

Run JavaScript from Elixir in supervised, pooled worker processes, on
**Node.js, Bun, Deno or QuickJS**. The `portals_javascript` package bundles
one dependency-free worker SDK, the `portals-worker` module, and makes
`require('portals-worker')` resolve to it on every runtime. You never
`npm install` anything for Portals itself, the same worker script runs on
all four runtimes, and you pick the runtime with one option.

**Requirements:** one of the runtimes below, on the machine that runs the
workers. The SDK has no npm dependencies.

| `runtime:` | Runtime | Tested with | How the SDK is found | Transport |
|---|---|---|---|---|
| `:node` (default) | [Node.js](https://nodejs.org) 18+ | 22 | `NODE_PATH` | Unix socket |
| `:bun` | [Bun](https://bun.sh) | 1.4 | `NODE_PATH` | Unix socket |
| `:deno` | [Deno](https://deno.com) 2 | 2.9 | a resolve hook preloaded with `--require` | Unix socket |
| `:quickjs` | [QuickJS-ng](https://quickjs-ng.github.io/quickjs/) (`qjs`) | 0.17 | the bundled QuickJS host | framed stdio |

This page walks through a complete worker, a `text_tools` module that
counts words, parses integers, reports progress back to Elixir, messages a
process and streams text. The same example exists for every language, and
the code below is exactly the code Portals' own test suite runs, on all
four runtimes.

## 1. Install

```elixir
# mix.exs
def deps do
  [
    {:portals_javascript, "~> 0.1.0"}
  ]
end
```

`portals_javascript` depends on `portals`, so this is the only line you need.

## 2. Write the handlers

Handlers are plain functions exported from a CommonJS module, and may be
`async`. Export them under the names Elixir will call.

```js
// priv/js/textTools.js
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
// priv/js/worker.js
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
     Portals.JavaScript.worker_opts(
       script: Application.app_dir(:my_app, "priv/js/worker.js"),
       runtime: :node,
       name: MyApp.JS,
       size: 4
     )}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

To switch runtimes, change `runtime:` to `:bun`, `:deno` or `:quickjs`.
Nothing else changes: not the worker script, the handlers or the Elixir
calls. You can even run several runtimes side by side, as separate pools.

| Option | Default | Use it for |
|---|---|---|
| `:runtime` | `:node` | `:node`, `:bun`, `:deno` or `:quickjs` |
| `:executable` | `node`, `bun`, `deno` or `qjs` | A specific binary, e.g. one installed by `nvm`, `asdf` or `mise` |
| `:runtime_args` | `[]` | Runtime flags, e.g. `["--max-old-space-size=512"]` for Node.js |
| `:deno_permissions` | `["--allow-all"]` | Deno permission flags (see below) |
| `:args` | `[]` | Arguments to your script (before the socket path Portals appends) |
| `:env` | `[]` | Extra environment variables, e.g. `[{"NODE_ENV", "production"}]` |

## 5. Call it

```elixir
iex> Portals.Pool.call(MyApp.JS, "text_tools", "word_count", ["hello world"])
{:ok, 2}

iex> Portals.Pool.call(MyApp.JS, "text_tools", "parse_int", ["12"])
{:ok, 12}
```

## 6. Errors

A thrown error (or a rejected promise) becomes a structured error:

```elixir
iex> {:error, error} = Portals.Pool.call(MyApp.JS, "text_tools", "parse_int", ["nope"])
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
iex> Portals.Pool.call(MyApp.JS, "text_tools", "progress", [3])
{:ok, 3}
```

The fourth argument is a timeout in milliseconds. A failing Elixir
function rejects with `portals.RemoteError`, and a timeout with
`portals.CallbackTimeout`. Awaiting never blocks the worker's reader, so
other calls keep flowing.

## 8. Send messages to Elixir processes

A PID passed as an argument arrives as an opaque `portals.Pid`:

```elixir
iex> Portals.Pool.call(MyApp.JS, "text_tools", "notify", [self(), "hi"])
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
{:ok, worker} = Portals.start_worker(Portals.JS.worker_opts(script: Application.app_dir(:my_app, "priv/js/worker.js"), runtime: :node))

{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 3} = Portals.Stream.await(stream)
```

Streams also have `await stream.recv(timeoutMs)` (returns `null` at the
end), `await stream.sendAll(chunks)` and `stream.halfClose()`.

## 10. Runtimes

`portals.runtime()` returns `{ name, version }` for the runtime the
worker is on (`node`, `bun`, `deno` or `quickjs`), and the worker reports
it in its handshake (`Portals.health(worker).worker_info.runtime`).

### Node.js

The default and the reference runtime. The SDK's parent directory is put on
`NODE_PATH`.

### Bun

Bun runs the same CommonJS worker with Node's APIs, and also resolves
`portals-worker` through `NODE_PATH`. Bun-specific APIs (`Bun.file`,
`bun:sqlite`, ...) are available to your handlers. ES-module workers work
too: `import { Worker } from 'portals-worker'`.

### Deno

Deno runs the worker through its Node compatibility layer. Portals launches
`deno run --allow-all --unstable-detect-cjs --require=<sdk>/register.cjs
worker.js`:

- `--unstable-detect-cjs` lets Deno run `.js` files that use `require`,
  so the same CommonJS worker works. Alternatively, name your files
  `.cjs`, or add a `package.json` with `"type": "commonjs"` next to them.
- `register.cjs` makes `require('portals-worker')` resolve to the bundled
  SDK, because Deno ignores `NODE_PATH`.
- Permissions default to `--allow-all`, since workers are trusted code. To
  narrow them, pass `deno_permissions:`. The SDK itself needs
  `["--allow-read", "--allow-write", "--allow-env", "--allow-net"]`
  (Deno counts connecting to the Unix socket as network access). Add
  whatever else your handlers need.

### QuickJS

[QuickJS-ng](https://quickjs-ng.github.io/quickjs/) is a small embeddable
engine (a 2.5 MB binary) that starts in milliseconds. A worker running
this guide's example uses about 9 MB of memory, against about 50 MB for
Deno. It has none of Node's APIs, so Portals runs the worker
through a bundled host (`quickjs/host.mjs`). The host provides what the
SDK needs: `Buffer`, `process`, timers, `require`, and minimal `path`,
`fs` and `async_hooks`. It then loads your CommonJS worker exactly as Node
would.

Differences from the other runtimes:

- **Framed stdio instead of a socket.** QuickJS has no socket API, so the
  worker talks to the BEAM over stdin/stdout. `worker_opts/1` sets this up.
  `console.log` is redirected to stderr so it cannot corrupt the frames;
  QuickJS's own `print()` writes to stdout and must not be used.
- **Only pure-JavaScript dependencies.** `require` finds relative files and
  `node_modules` packages, but packages that need Node APIs beyond the
  ones listed (`http`, `crypto`, `child_process`, ...) fail to load.
- **Call context is emulated.** QuickJS has no async context tracking, so
  `portals.currentDeadlineMs()`, `portals.isCancelled()` and the callback
  depth follow the calls in flight like a stack. They are exact when calls
  don't overlap, or when they nest through callbacks (the common case).
  For long, concurrent, `await`-heavy handlers that rely on these helpers,
  set `maxConcurrency: 1` in the worker.
- **An interpreter, not a JIT.** CPU-heavy JavaScript is much slower than
  on Node.js, Bun or Deno. QuickJS suits small, fast-starting workers.

## 11. Deploy

- Keep the JavaScript in `priv/js/` (with its own `package.json` and
  `node_modules` if you use npm packages) and build paths with
  `Application.app_dir(:my_app, "priv/js/...")`. `mix release` copies
  `priv/`, including the SDK bundled in `portals_javascript`.
- Install the chosen runtime in the release image. For npm dependencies,
  run `npm ci --omit=dev` (or `bun install --production`) in `priv/js`
  while building it.
- `mix portals.sdk_path javascript | tail -n 1` prints the SDK directory.
  For editor support, add its parent to `NODE_PATH`, or map
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
| `portals.runtime()` | `{ name, version }` of the runtime the worker runs on |

On Node.js, Bun and Deno the call context travels with
`AsyncLocalStorage`, so these work after any number of `await`s. On
QuickJS, see the note above.

## Gotchas

- **One event loop per worker.** Concurrency comes from `async` I/O. A
  synchronous CPU-heavy handler blocks every other call on that worker,
  callbacks and streams included. Scale CPU work with pool `:size`, or move
  it to `worker_threads` (Node.js, Bun) or a Web Worker (Deno).
- **Node.js ES modules don't read `NODE_PATH`.** In a `.mjs` worker on
  Node.js, `import 'portals-worker'` fails with `ERR_MODULE_NOT_FOUND`. Use
  `createRequire`, or run that worker on Bun:

  ```js
  import { createRequire } from 'node:module';
  const require = createRequire(import.meta.url);
  const { Worker } = require('portals-worker');
  ```

- **`NODE_PATH` has the lowest priority.** On Node.js and Bun, a
  `portals-worker` package in a local `node_modules` would shadow the
  bundled SDK. Don't install one.
- **Deno needs CommonJS detection for `.js` files.** Portals passes
  `--unstable-detect-cjs`. If you override the Deno command yourself, keep
  it, or use `.cjs` files.
- **Large integers become `BigInt`.** Values beyond 2^53 arrive as `BigInt`,
  which doesn't mix with `number` arithmetic. Integral floats encode as
  integers unless wrapped in `portals.float()`.
- **Wrap raw bytes in `%Portals.Codec.Bin{}`.** A plain Elixir binary that
  is not valid UTF-8 is decoded as a string with the invalid bytes replaced
  by U+FFFD, so the data is silently corrupted. Wrapped bytes arrive as a
  `Buffer`.
- **`console.log` goes nowhere.** stdout and stderr are discarded under the
  default transport (on QuickJS, console output goes to stderr). Set
  `PORTALS_LOG_FILE`, or pass `logger: (message) => ...` to
  `new Worker(...)` for the SDK's own logs.
- **Unregistered module names are resolved from the BEAM's working
  directory.** Register modules explicitly, or set `modulePaths: [__dirname]`.

## Best practices

- Register every module in `modules:` with `require('./...')` paths
  relative to the entry script.
- Write workers as CommonJS. The same files then run on all four runtimes,
  and switching is a one-word change in Elixir.
- Make handlers `async` and await I/O. Never use synchronous file or
  network APIs (`fs.readFileSync`, `execSync`) in a handler.
- Create clients and caches at module load, and reuse them across calls.
- Return plain data (objects, arrays, strings, numbers, `Buffer`s). Class
  instances are encoded as plain objects with only their own enumerable
  properties.
- For long jobs, check `portals.isCancelled()` between steps and respect
  `portals.currentDeadlineMs()`.
