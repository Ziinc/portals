# Migrating from ErlPort

Portals targets *behavioral*, not source-level, compatibility with
ErlPort (`hdima/erlport`). Every application will need to change call
sites; this guide maps ErlPort's Erlang API and behavior to Portals'
Elixir API one concept at a time.

## Starting a worker

| ErlPort | Portals |
|---|---|
| `erlport:start(python, [{python, "python3"}])` (Erlang) | `Portals.start_worker(command: "python3", args: [...])` |
| One process, manually supervised | `Portals.start_worker/1` returns one `Portals.Connection`; wrap it in a `Supervisor` child spec, or use `Portals.start_pool/1` for a supervised pool with overflow (no ErlPort equivalent) |

## Calling a function

| ErlPort | Portals |
|---|---|
| `erlport:call(Pid, Module, Function, Args)` | `Portals.call(conn, module, function, args)` — returns `{:ok, term} \| {:error, %Portals.Error{}}` instead of raising/returning a raw term |
| No async primitive; callers block | `Portals.async/5` + `Portals.await/2` for explicit async, and `Portals.cancel/1` for cooperative cancellation (no ErlPort equivalent) |
| No per-call timeout enforcement beyond the outer receive | `timeout:` and `deadline_ms:` options on every call |

## Error handling

ErlPort raises an Erlang exception (`{Class, Reason}` reconstructed from
the Python side) on a remote failure; catching it means wrapping every
call in `try/catch`. Portals never raises from `Portals.call/5` — it
returns `{:error, %Portals.Error{kind: ..., message: ..., remote: ...,
stacktrace: ...}}`, a structured value you pattern-match on. Use
`Portals.call!/5` if you want ErlPort-style raise-on-failure behavior; it
raises `Portals.CallError`, wrapping the same `%Portals.Error{}`.

## The value model

Both systems tag values through their own type system rather than
inventing a shared format on the wire — ErlPort uses ETF directly and its
Python/Ruby adapters implement BEAM-specific tagging by hand; Portals
uses MessagePack plus its own extensions (`Portals.TermExtensions`) so
non-BEAM SDKs never need to understand ETF at all. Atoms, tuples, PIDs,
references, and bignums all still round-trip; see `protocol/v1.md` and
`docs/security-review.md` for the exact decode-safety guarantees (atoms
are never fabricated from untrusted bytes in either system, but Portals
makes that an explicit, tested contract).

## Reverse callbacks (worker calling back into the BEAM)

ErlPort has no first-class reverse-callback mechanism; applications
typically build ad hoc message-passing on top of `erlport:cast`. Portals
has a dedicated `CALLBACK` frame: a worker can call back into an
explicit, application-supplied allowlist of `{module, function, arity}`
and get a real return value, including reentrant nested calls tracked via
callback depth. See Phase 5 in `docs/prd.md` and
`Portals.Connection`'s `callback_allowlist` option.

## Streaming

ErlPort has no bidirectional streaming primitive. Portals' `Portals.Stream`
gives explicit send/half-close/receive plus credit-based backpressure in
both directions, and an `Enumerable` view for lazy consumption
(`Portals.Stream.to_enumerable/2`).

## Pooling and overflow

ErlPort applications typically hand-roll a pool of `erlport:start/2`
processes with `:poolboy` or similar. `Portals.Pool` is a first-class,
supervised replacement: base workers plus temporary overflow workers,
least-in-flight scheduling, and a `checkout_timeout` that returns a
structured `%Portals.Error{kind: :checkout_timeout}` instead of hanging
indefinitely.

## Observability

ErlPort exposes no telemetry or health-inspection surface. Portals adds
`:telemetry` events (`docs/telemetry.md`), `Portals.Health` point-in-time
snapshots, and `Portals.LogSink` configurable log routing — none of which
have an ErlPort equivalent to migrate from; they're new capability, not a
compatibility gap to close.

## What does *not* change

The trust model is unchanged: both systems assume the external process is
a trusted collaborator (it can crash your calls, it cannot escape its
process boundary or forge BEAM-internal identity beyond replaying values
you handed it — see `docs/security-review.md`).
