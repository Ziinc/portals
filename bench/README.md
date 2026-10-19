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

## Results

One run of `bench/run.sh` on 2026-10-19: 4-core Intel Xeon @ 2.80GHz,
Linux, Elixir 1.18.4 on OTP 25, Python 3.13.16. Medians (Benchee reports
mean, deviation and 99th percentile too; see `results/`). Lower is better.

### RPC: one call at a time

| | `add(1, 2)` | 1 KiB text | 64 KiB bytes | 1 MiB bytes | 1,000 integers | 100 records |
|---|---|---|---|---|---|---|
| Portals: MessagePack, Unix socket | 179 µs | 198 µs | 396 µs | 10.65 ms | 2.40 ms | 4.32 ms |
| Portals: MessagePack, stdio | 175 µs | 178 µs | 584 µs | 11.86 ms | 2.31 ms | 4.64 ms |
| Portals: ETF, Unix socket | 190 µs | 195 µs | **342 µs** | **4.14 ms** | 1.75 ms | 3.73 ms |
| Portals: ETF, stdio | 155 µs | 155 µs | 482 µs | 5.95 ms | 1.82 ms | 3.64 ms |
| zerorpc: MessagePack, ZeroMQ/TCP | 894 µs | 835 µs | 1363 µs | 9.67 ms | **1.38 ms** | **1.73 ms** |
| ErlPort: ETF, stdio | **82 µs** | **83 µs** | 356 µs | 7.74 ms | 1.74 ms | 3.88 ms |

### Concurrency: 1,000 `add` calls, 64 in flight

| | Time per batch | Calls/s |
|---|---|---|
| Portals: 1 worker | 206 ms | ~4,800 |
| Portals: pool of 4 | 111 ms | ~9,000 |
| zerorpc: 1 server | 541 ms | ~1,850 |
| ErlPort: 1 interpreter | **27 ms** | **~36,600** |
| ErlPort: 4 interpreters | 33 ms | ~29,900 |

### Startup: start, one call, stop

| | |
|---|---|
| `python -c pass` (the interpreter alone) | 23 ms |
| Portals: stdio | 72 ms |
| Portals: Unix socket | 78 ms |
| ErlPort | 71 ms |
| zerorpc | 183 ms |

### Raw transports: one frame there and back, no codec

| | 64 B | 4 KiB | 64 KiB | 1 MiB |
|---|---|---|---|---|
| stdio (Port) | **46 µs** | **48 µs** | 246 µs | 6.53 ms |
| Unix socket | 69 µs | 97 µs | 192 µs | **3.52 ms** |
| TCP loopback | 60 µs | 96 µs | **147 µs** | 3.64 ms |
| ZeroMQ/TCP (chumak) | 154 µs | 180 µs | 541 µs | 4.87 ms |

### BEAM codecs: encode + decode one frame

| | `[1, 2]` | 1 KiB text | 64 KiB bytes | 1 MiB bytes | 1,000 integers | 100 records |
|---|---|---|---|---|---|---|
| Portals MessagePack | 2.2 µs | 3.2 µs | 7.9 µs | 1,270 µs | 331 µs | 1,047 µs |
| ETF (`term_to_binary`) | **0.3 µs** | **0.6 µs** | 5.5 µs | 161 µs | **21 µs** | **55 µs** |
| Msgpax | 1.1 µs | 1.2 µs | **4.2 µs** | **64 µs** | 198 µs | 342 µs |
| Jason (bytes as base64) | 1.1 µs | 9.5 µs | 696 µs | 11,870 µs | 464 µs | 593 µs |

### Python codecs: encode + decode one frame (best of 5)

| | `[1, 2]` | 1 KiB text | 64 KiB bytes | 1 MiB bytes | 1,000 integers | 100 records |
|---|---|---|---|---|---|---|
| Portals MessagePack (pure Python) | 9.1 µs | 7.7 µs | 20 µs | 667 µs | 1,661 µs | 2,491 µs |
| Portals ETF (pure Python) | 9.0 µs | 7.6 µs | 19 µs | 256 µs | 1,212 µs | 2,704 µs |
| ErlPort ETF (pure Python) | 8.0 µs | 7.7 µs | 27 µs | 2,874 µs | 1,319 µs | 2,846 µs |
| msgpack (C extension) | 1.1 µs | 1.3 µs | 6.3 µs | 248 µs | 53 µs | 149 µs |
| pickle (protocol 5) | 1.7 µs | 1.6 µs | 6.3 µs | 153 µs | 45 µs | 104 µs |
| json (bytes as base64) | 4.8 µs | 10 µs | 421 µs | 8,087 µs | 181 µs | 283 µs |

## What the numbers say

- **Small calls: ErlPort is about twice as fast, and the Portals worker's
  thread pool is why.** Each Portals call is handed from the reader thread
  to a `ThreadPoolExecutor` and the reply back, which costs CPython two
  thread switches and GIL handoffs; ErlPort runs the function on the
  thread that read the request. With that one thing changed (a worker
  subclass that dispatches inline), Portals over ETF and stdio measured
  103 µs per `add` against ErlPort's 99 µs, and 33.6 ms per 1,000-call
  batch against ErlPort's 34.8 ms; with the thread pool it was 181 µs
  and 207 ms. The pool is what lets handlers block, run concurrently, be
  cancelled and call back into Elixir (an inline callback would deadlock,
  since the reader thread receives its reply), so it is not free to drop.
- **Concurrency doesn't help one Portals worker.** 64 calls in flight run
  no faster than one at a time (about 5,000 calls/s either way): the
  reader thread and the pool threads contend for the GIL. A pool of 4
  workers roughly doubles it. ErlPort pipelines calls through one
  interpreter at over 30,000 calls/s.
- **Large binaries: Portals over ETF is the fastest.** 1 MiB round trips
  in 4.1 ms (Unix socket) against 7.7 ms for ErlPort, whose Python codec
  is slow on large binaries, and 10.7 ms for Portals over MessagePack.
- **Portals' MessagePack codec is the slow part on both sides.** On the
  BEAM it is the slowest of the four codecs for large binaries (20x
  Msgpax on 1 MiB) and records (3x Msgpax). In Python, the pure-Python
  codecs (Portals' two and ErlPort's) are 15 to 30 times slower than the
  msgpack C extension on structured data, which is why zerorpc, slow
  everywhere else, is fastest on integers and records.
- **Transports matter little next to the rest.** stdio has the lowest
  latency for small frames, Unix sockets and TCP win for large ones, and
  every one of them is a fraction of the RPC numbers above. ZeroMQ via
  chumak adds about 100 µs per round trip over plain TCP.
- **zerorpc's per-call cost is its Python side.** Its server sets up a
  channel, heartbeat and buffer (on gevent) for every call; the Python
  zerorpc client calling the same server measured 1.8 ms per `add`, twice
  the Elixir client's 0.9 ms.
- **Startup is mostly the interpreter.** Python itself takes 23 ms;
  Portals and ErlPort both start, call and stop in about 75 ms. zerorpc
  takes 183 ms, nearly all of it imports: `python -c "import zerorpc"`
  takes 162 ms against 18 ms for `python -c pass`.

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
