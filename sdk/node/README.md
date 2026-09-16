# Portals Node.js worker SDK

A Node worker for [Portals](../../README.md), implementing the v1 wire
protocol in [`protocol/v1.md`](../../protocol/v1.md) with full parity with
the reference Python SDK.

Zero dependencies: the MessagePack codec (including the Erlang value
extensions) is implemented in `lib/msgpackCodec.js`, so a worker only needs
a stock Node 18+ runtime — no `npm install` step.

## Writing a worker

```js
// myHandlers.js
const portals = require('portals-worker');

const encode = (text) => ({ length: text.length });

// Reentrant callback back into the BEAM; awaits without ever blocking the
// socket reader.
const withProgress = async (n) => {
  await portals.callback('MyApp.Progress', 'report', [n]);
  return n * 2;
};

const notify = (pid, value) => {
  portals.sendMessage(pid, value); // fire-and-forget to a BEAM PID
  return 'ok';
};

const echoStream = portals.streamHandler(async (stream) => {
  let count = 0;
  for await (const chunk of stream) { // credit-backed inbound frames
    await stream.send(chunk);         // awaits the BEAM's credit grant
    count += 1;
  }
  return count;                       // becomes the stream's terminal RETURN
});

module.exports = { encode, with_progress: withProgress, notify, echo_stream: echoStream };
```

```js
#!/usr/bin/env node
// runWorker.js — Portals appends the socket path as the last CLI argument
const { Worker } = require('portals-worker');

new Worker({
  maxConcurrency: 16,
  maxStreams: 8,
  modules: { my_handlers: require('./myHandlers') },
}).run().catch((err) => { process.stderr.write(`${err.stack}\n`); process.exit(1); });
```

From Elixir:

```elixir
{:ok, conn} = Portals.start_worker(command: "node", args: ["runWorker.js"])
{:ok, %{"length" => 5}} = Portals.call(conn, "my_handlers", "encode", ["hello"])
{:ok, stream} = Portals.open_stream(conn, "my_handlers", "echo_stream", [])
```

## Dispatch

`CALL`'s `module` names a module registered with `modules:`/`register()`, or
is `require`d relative to the configured `modulePaths` (default
`[process.cwd()]`). The function may be sync or async; a returned Promise is
awaited before the terminal `RETURN`.

## Handler context

| Helper | Meaning |
|---|---|
| `await portals.callback(mod, fun, args, timeoutMs)` | Reentrant call back into the BEAM |
| `portals.sendMessage(pid, value)` | Fire-and-forget message to a BEAM PID |
| `portals.currentCallbackDepth()` | Reentrancy depth of the current CALL |
| `portals.currentDeadlineMs()` | Deadline the BEAM attached to this CALL |
| `portals.isCancelled()` | True once the BEAM sent `CANCEL` for this CALL |

Context is carried by `AsyncLocalStorage`, so it survives `await`.

## Value model

| BEAM | JavaScript |
|---|---|
| binary (text) | `string` |
| binary (bytes) | `Buffer` |
| integer | `number`, or `BigInt` beyond 2^53 |
| float | `number`; use `portals.float(2)` to force a float for an integral value |
| tuple | `portals.Tuple` |
| atom | `portals.Atom` |
| pid / reference | `portals.Pid` / `portals.Ref` (opaque, echo-only) |
| improper list | `portals.ImproperList` |

## Logging

Never over the RPC protocol: set `PORTALS_LOG_FILE`, or pass
`logger: (message) => ...` to the `Worker` constructor.

## Transports

`transport: 'unix'` (default) or `transport: 'stdio'` for the framed
stdin/stdout fallback.

## Tests

```sh
npm test    # node --test test/*.test.js
```

The cross-language conformance and integration suites live on the Elixir
side: `mix test test/conformance/sdk_conformance_test.exs
test/integration/node_worker_test.exs`.
