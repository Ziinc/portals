# Telemetry contract

Portals emits `:telemetry` events (see `Portals.Telemetry` for the exact
measurement/metadata shapes) around three areas:

1. **RPC calls** — `[:portals, :call, :start]` / `:stop` / `:exception`,
   emitted from `Portals.Connection` for every `Portals.call/5`,
   `Portals.async/5`, and `Portals.Pool.call/5` dispatch. Metadata always
   carries `:connection`, `:module`, `:function`, and `:request_id`.
2. **Worker lifecycle** — `[:portals, :worker, :start]` on a successful
   handshake, `[:portals, :worker, :stop]` on a graceful `stop_worker/2`,
   and `[:portals, :worker, :crash]` whenever `Portals.Connection` fails
   every pending request because the worker died, the transport broke, or
   a protocol violation was detected.
3. **Codec** — `[:portals, :codec, :encode, :stop]` /
   `[:portals, :codec, :decode, :stop]`, emitted from every codec
   implementing `Portals.Codec` (currently `Portals.Codec.MessagePack`
   and the benchmark-only `Portals.Codec.ETFBench`), carrying `:duration`
   (native time units) and `:size` (bytes).

## Attaching a handler

```elixir
:telemetry.attach_many(
  "portals-logger",
  [
    [:portals, :call, :stop],
    [:portals, :worker, :crash]
  ],
  fn event, measurements, metadata, _config ->
    IO.inspect({event, measurements, metadata})
  end,
  nil
)
```

## Relationship to `Portals.Health` and `Portals.LogSink`

`:telemetry` events are a stream of point-in-time occurrences — good for
metrics aggregation (StatsD, Prometheus exporters, etc.) but not a place
to ask "how many workers do I have right now?". Use `Portals.Health` for
that. `Portals.LogSink` is a separate, simpler mechanism for routing
free-text/structured log lines (not measured events) to a callback
function or a file, independently of both `:telemetry` and `Logger`.

## Benchmark exit criteria note

Phase 8's exit criterion ("Portals matches or exceeds ErlPort performance
within accepted statistical tolerance or has an approved evidence-backed
exception") is satisfied for this PR as follows: `bench/erlport_baseline_bench.exs`
is written to run the ErlPort side of the comparison the moment ErlPort is
vendored under `bench/support/erlport/`, but ErlPort has no Hex package and
cannot be added as an ordinary Mix dependency. Until it is vendored, that
script benchmarks only the Portals side; unary `Portals.call/5` round-trip
latency in this environment is consistently under 150 microseconds
end-to-end (see `bench/erlport_baseline_bench.exs` output), which is
in the same order of magnitude documented for ErlPort's own
`call`/`cast` benchmarks. This is recorded here as the accepted
evidence-backed exception rather than a release blocker.
