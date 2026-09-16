# portals
The spiritual erlport successor

See [`docs/prd.md`](docs/prd.md) for the full product/engineering PRD and
delivery plan.

## Status

Phase 1 (value model, protocol, and conformance) is implemented:

- `protocol/v1.md` — the language-neutral wire protocol specification.
- `lib/portals/protocol.ex` — frame tags, arities, and default limits.
- `lib/portals/codec/message_pack.ex` — the mandatory MessagePack codec,
  including the Erlang-value extensions in `lib/portals/term_extensions.ex`.
- `lib/portals/handshake.ex` — exact-version `HELLO`/`READY` negotiation.
- `lib/portals/conformance/runner.ex` — the black-box conformance runner,
  driven by `protocol/vectors/golden.exs` and `protocol/malformed/fixtures.exs`.

Phase 2 (lifecycle and transport) is implemented:

- `lib/portals/socket_dir.ex` — private `0700` per-worker runtime
  directories and stale-socket cleanup.
- `lib/portals/transport/unix.ex` — the default per-worker Unix-domain
  socket transport (`packet: 4` framing).
- `lib/portals/transport/stdio.ex` — the experimental framed-stdio
  fallback transport, for platforms without Unix-socket support.
- `lib/portals/worker_lifecycle/port.ex` — launches and monitors the
  direct worker through a BEAM Port, with graceful-then-forced shutdown.

Phase 3 (unary RPC and the Python vertical slice) is implemented:

- `lib/portals/connection.ex` — the connection state machine: handshake,
  per-connection monotonic request IDs, out-of-order pending-call
  tracking, cancellation, owner-exit handling, and deterministic failure
  of every pending caller on worker crash or protocol violation.
- `lib/portals/error.ex` — `%Portals.Error{}}`.
- `lib/portals.ex` — the public `call/5`, `call!/5`, `async/5`, `await/2`,
  `cancel/2` API (pre-pool: the first argument is a single worker
  connection; `Portals.Pool` in Phase 4 will be a drop-in replacement).
- `sdk/python/portals/` — the Python worker SDK: a dependency-free
  MessagePack codec/transport, and a threaded dispatcher supporting
  arbitrary `module.function` invocation with independent concurrent
  calls (`sdk/python/portals/worker.py`).

Phase 4 (pooling, overflow, deadlines, cancellation) is implemented:

- `lib/portals/pool.ex` — `Portals.Pool`, a supervised set of base
  workers plus on-demand `max_overflow` overflow workers. Least-in-flight
  scheduling with round-robin tie-breaking; blocking checkout with an
  independent `checkout_timeout` (execution timeout only starts once a
  call is actually dispatched); idle overflow workers are retired
  immediately; a crashed base worker is replaced automatically.
- `Portals.start_pool/1` and `Portals.Pool.call/5`, `call!/5`, `async/5`,
  `await/2`, `cancel/2`, `health/1` — the same shapes as the single-worker
  API, now load-balanced across a pool.

Phase 5 (reentrant callbacks and PID messaging) is implemented:

- `Portals.Connection` now handles `CALLBACK` frames: each is dispatched
  to an independent supervised task (never inline on the socket reader),
  enforcing `max_callback_depth` and `max_in_flight_callbacks` and an
  optional callback allowlist, and replies with `CALLBACK_RETURN`/
  `CALLBACK_ERROR`. Reentrancy depth is self-reported by the trusted
  worker and echoed back through nested `CALL`s automatically (see
  `Portals.Callback.depth/0` and protocol/v1.md section 8).
- `MESSAGE` frames deliver safely-decoded PIDs via ordinary `send/2`
  (configurable `:wrapped`/`:raw` envelope).
- `sdk/python/portals`: `portals.callback(module, function, args)` blocks
  the calling handler's own thread for a BEAM-side result without
  stalling the socket reader or other in-flight calls; `portals.send_message/2`
  delivers values to a PID received as a call argument.

Phase 7 (Ruby and Node.js parity) is implemented:

- `sdk/ruby/` — the Ruby worker SDK (`Portals::Worker`): a dependency-free
  MessagePack codec with the Erlang value extensions, Unix-socket and
  framed-stdio transports, a bounded thread-pool dispatcher, reentrant
  callbacks, PID messaging, cooperative cancellation, and bidirectional
  streaming on its own thread pool.
- `sdk/node/` — the Node.js worker SDK (`Worker`): the same protocol
  surface, dependency-free, with async handlers, `AsyncLocalStorage`-backed
  call context, and a reader loop that never awaits handler execution.
- `test/support/worker_suite.ex` — the shared black-box integration suite
  every bundled SDK must pass, driven per SDK by
  `test/integration/{ruby,node}_worker_test.exs`.
- `test/conformance/sdk_conformance_test.exs` — replays
  `protocol/vectors/golden.exs` and `protocol/malformed/fixtures.exs`
  against all three SDKs over a language-neutral bridge, and asserts their
  version output and protocol-mismatch diagnostics agree.

Run the Elixir test suite with `mix test` (includes integration tests that
spawn real Python, Ruby and Node workers; requires `python3`, `ruby` and
`node` on `PATH`). Each SDK also has its own unit tests:

```sh
cd sdk/python && python3 -m unittest discover -s tests
cd sdk/ruby   && ruby -Ilib -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }'
cd sdk/node   && npm test
```
