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

Run the Elixir test suite with `mix test` (includes integration tests that
spawn the real Python worker; requires `python3` on `PATH`). Run the Python
SDK's own unit tests with `cd sdk/python && python3 -m unittest discover -s tests`.
