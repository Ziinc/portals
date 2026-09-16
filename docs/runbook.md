# Operational runbook

## Supervision

Every `Portals.Connection` (started directly via `Portals.start_worker/1`
or indirectly by `Portals.Pool`) traps exits and treats a worker crash,
transport failure, or protocol violation as a terminal event for that one
connection: every pending request receives a
`{:error, %Portals.Error{}}`, and the connection moves to `:closed`. It
never crashes its own caller and never crashes the BEAM.

- **Single-worker mode** (`Portals.start_worker/1`): the caller is
  responsible for supervising and restarting the returned `pid` — Portals
  does not restart it for you. Put it under your own `Supervisor` (or
  `DynamicSupervisor`) if you need automatic restart.
- **Pool mode** (`Portals.start_pool/1`): `Portals.Pool` monitors every
  worker; a crashed *base* worker is replaced automatically (logged via
  `Logger.error/1` if replacement itself fails). Crashed *overflow*
  workers are not replaced — that capacity is only created on demand in
  the first place.

## Health checks

Poll `Portals.Health.snapshot/1` (works for both a `Portals.Connection`
and a `Portals.Pool`) rather than parsing log output:

```elixir
Portals.Health.snapshot(conn)
# %{kind: :worker, status: :ready, in_flight: 2, in_flight_callbacks: 0,
#   open_streams: 0, max_streams: 8, worker_info: %Portals.Handshake.Hello{...}}

Portals.Health.snapshot(pool)
# %{kind: :pool, worker_count: 4, size: 4, max_overflow: 2, queue_depth: 0,
#   in_flight_total: 3, capacity_total: 256, workers: %{...}}
```

`status: :closed` on a single connection means it is dead and will not
recover on its own; restart it. `queue_depth > 0` sustained over time on
a pool means callers are waiting for checkout — either `checkout_timeout`
is too aggressive, or `size`/`max_overflow` need raising.

## Reading telemetry and log sink output

- `:telemetry` events (`docs/telemetry.md`) are the right source for
  metrics aggregation (attach a handler that forwards to StatsD/Prometheus/etc.).
  `[:portals, :worker, :crash]` firing repeatedly for the same connection
  is the leading indicator of a misbehaving worker command, missing
  dependency, or a script bug — check the worker's own stderr/exit code
  first.
- `Portals.LogSink` is for routing free-text operational events (not
  metrics) to a callback or file independently of `Logger`; attach it
  once at application boot if you want a separate audit trail from your
  usual application logs.

## Common failure modes

| Symptom | Likely cause | What to check |
|---|---|---|
| `{:error, %Portals.Error{kind: :checkout_timeout}}` | Pool saturated: every worker (base + overflow) is at its advertised `max_concurrency` | `Portals.Health.snapshot(pool).queue_depth`; raise `size`/`max_overflow` or reduce call latency |
| `{:error, %Portals.Error{kind: :worker_exit}}` | Worker process crashed, exited, or closed its socket | Worker's own stderr/logs; `[:portals, :worker, :crash]` telemetry metadata |
| `{:error, %Portals.Error{kind: :overload}}` on a single connection | `max_in_flight_requests` limit hit on that connection | Lower per-call concurrency, or move to `Portals.Pool` |
| `{:error, %Portals.Error{kind: :protocol}}` | Malformed frame received (bug in the worker SDK, or a version mismatch) | Confirm both sides are running the same protocol version (`protocol/v1.md`); the connection is now `:closed` and cannot recover |
| `{:handshake_failed, {:protocol_version_mismatch, ...}}` at startup | Worker SDK version doesn't match the Elixir side's expected protocol version | Update the mismatched side; Portals does not attempt cross-version compatibility |
| Calls hang past their `timeout:` | Almost always a bug in the *caller* awaiting the wrong request, not Portals; `Portals.await/2` always returns by its own timeout | Confirm you're awaiting the `%Portals.Request{}` returned by the matching `async/5` call |

## Examples for all three SDKs

See the bundled worker fixtures each SDK's own test suite drives (all
implement the same `bench_worker` surface so behavior is directly
comparable across languages):

- Python: `sdk/python/tests/fixtures/run_worker.py`
- Ruby: `sdk/ruby/test/fixtures/run_worker.rb`
- Node.js: `sdk/node/test/fixtures/run_worker.js`
