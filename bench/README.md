# Benchmarks

How Portals compares with the other ways to call Python from Elixir, and
with the codecs and transports underneath. Every comparison runs against
the same Python functions (`python/bench_handlers.py`: `echo` and `add`)
on the same interpreter.

| Part | Script | Compares |
|---|---|---|
| RPC | `rpc.exs` | One call at a time from the BEAM: Portals (MessagePack or ETF, Unix socket or stdio), zerorpc and ErlPort |
| Concurrency | `concurrency.exs` | 1,000 calls with 64 in flight: Portals (one worker, pool of 4), zerorpc, ErlPort (one or four interpreters) |
| Startup | `startup.exs` | Start a worker, one call, stop |
| Transports | `transports.exs` | Raw frame round trips with no codec: Unix socket, TCP loopback, stdio Port, ZeroMQ |
| BEAM codecs | `codecs.exs` | Encode + decode of one frame on the BEAM: Portals MessagePack, ETF, Msgpax, Jason |
| Python codecs | `python/codec_bench.py` | The same on the Python side: Portals MessagePack and ETF, ErlPort's ETF, msgpack (C), pickle, json |

The workloads are an `add(1, 2)` call and `echo` of 1 KiB of text, 64 KiB
and 1 MiB of random bytes, a list of 1,000 integers and a list of 100
small records (maps of strings, numbers, booleans and a list).

## Running

```sh
bench/setup.sh               # .venv with zerorpc, msgpack, pyzmq; mix deps.get
bench/run.sh                 # everything, about 20 minutes
bench/run.sh rpc startup     # just these parts
BENCH_TIME=1 bench/run.sh    # shorter, noisier
```

Each part's output is saved to `bench/results/<part>.txt`, next to
`environment.txt` (CPU, OS, Elixir, OTP and Python versions). The
*Benchmarks* workflow (`.github/workflows/bench.yml`) runs the same thing
on demand on a GitHub runner and keeps the results as an artifact.

`mix test` in `bench/` (run by CI) checks that every target and transport
returns exactly what it was sent, so a benchmark never times a failing
call.

## What is being compared

- **Portals** runs with its production codec, MessagePack, and with
  `Portals.Codec.ETFBench`, a benchmark-only codec that sends the Erlang
  External Term Format instead (the Python SDK implements it under
  `PORTALS_CODEC=etf`). The ETF path passes the same conformance suite as
  MessagePack (`packages/portals_python/test/etf_worker_suite_test.exs`),
  so both measure the same behaviour. Each runs over a Unix socket and
  over the framed stdio fallback.
- **zerorpc** is the Python zerorpc 0.6.3 server (gevent, pyzmq, msgpack
  C extension) called from Elixir by `Bench.ZeroRPC`, a minimal zerorpc
  client over chumak (pure-Erlang ZeroMQ) and Msgpax. chumak only speaks
  TCP, so zerorpc runs over TCP loopback.
- **ErlPort** 0.11 (ETF over a stdio Port, the library Portals succeeds),
  with its bundled Python side.

Binary payloads use each library's binary type: `%Portals.Codec.Bin{}`,
`%Msgpax.Bin{}`, or a plain binary for ETF and ErlPort, which hand Python
`bytes` either way.

## Caveats

- Results are from one machine (see `environment.txt`); compare numbers
  within a run, not across machines. Shared CI runners are noisy.
- The RPC and concurrency numbers are wall-clock times seen by the calling
  BEAM process. Memory is only measured for the BEAM codecs, where the
  caller is the whole story.
- Portals does more per call than the others: request ids, deadlines,
  cancellation, credit-based streams and a thread pool in the worker. The
  RPC numbers include that cost on purpose.
- zerorpc's client here is `Bench.ZeroRPC`, not the Python client, and
  ZeroMQ is reached through chumak; a libzmq NIF would be faster on the
  BEAM side.
