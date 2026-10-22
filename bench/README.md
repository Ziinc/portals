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

- **Portals** runs with both of its codecs: the Erlang External Term
  Format (`codec: :etf`, the default) and MessagePack (`codec: :msgpack`).
  Both pass the same conformance suites, so both measure the same
  behaviour. Each runs over a Unix socket and over the framed stdio
  fallback.
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

Runs of `bench/run.sh` on 2026-10-19: 4-core Intel Xeon @ 2.80GHz, Linux,
Elixir 1.18.4 on OTP 25, Python 3.13.16. Medians (Benchee reports mean,
deviation and 99th percentile too; see `results/`). Lower is better. The
RPC and codec tables are from the run after ETF became the default codec;
the rest are from the first run.

### RPC: one call at a time

| | `add(1, 2)` | 1 KiB text | 64 KiB bytes | 1 MiB bytes | 1,000 integers | 100 records |
|---|---|---|---|---|---|---|
| Portals: ETF, Unix socket (default) | 180 µs | 192 µs | 362 µs | **4.02 ms** | 1.79 ms | 4.64 ms |
| Portals: ETF, stdio | 164 µs | 175 µs | 606 µs | 6.08 ms | 1.87 ms | 4.00 ms |
| Portals: MessagePack, Unix socket | 184 µs | 194 µs | 485 µs | 10.07 ms | 2.60 ms | 4.70 ms |
| Portals: MessagePack, stdio | 183 µs | 171 µs | 689 µs | 12.33 ms | 2.69 ms | 4.47 ms |
| zerorpc: MessagePack, ZeroMQ/TCP | 956 µs | 976 µs | 1513 µs | 11.15 ms | **1.49 ms** | **1.78 ms** |
| ErlPort: ETF, stdio | **81 µs** | **102 µs** | **341 µs** | 8.58 ms | 1.78 ms | 3.61 ms |

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
| Portals ETF (default) | 0.7 µs | 0.9 µs | 6.5 µs | 216 µs | 40 µs | 127 µs |
| `term_to_binary` (raw ETF) | **0.6 µs** | 0.9 µs | 5.9 µs | 231 µs | **23 µs** | **63 µs** |
| Portals MessagePack | 2.1 µs | 2.3 µs | 7.4 µs | 1,136 µs | 187 µs | 1,218 µs |
| Msgpax | 1.0 µs | 1.1 µs | **3.9 µs** | **68 µs** | 199 µs | 206 µs |
| Jason (bytes as base64) | 1.1 µs | 9.2 µs | 689 µs | 11,535 µs | 328 µs | 566 µs |

Portals ETF is `term_to_binary/1` plus a walk that enforces the protocol
limits before encoding, which is what costs the extra on large lists.

### Python codecs: encode + decode one frame (best of 5)

| | `[1, 2]` | 1 KiB text | 64 KiB bytes | 1 MiB bytes | 1,000 integers | 100 records |
|---|---|---|---|---|---|---|
| Portals ETF (pure Python, default) | 9.2 µs | 7.6 µs | 20 µs | 272 µs | 1,184 µs | 2,910 µs |
| Portals MessagePack (pure Python) | 9.1 µs | 7.7 µs | 20 µs | 588 µs | 1,507 µs | 2,468 µs |
| ErlPort ETF (pure Python) | 8.0 µs | 8.0 µs | 28 µs | 2,718 µs | 1,361 µs | 2,722 µs |
| msgpack (C extension) | 1.2 µs | 1.4 µs | 6.5 µs | 227 µs | 53 µs | 149 µs |
| pickle (protocol 5) | 1.7 µs | 1.6 µs | 5.9 µs | 132 µs | 49 µs | 107 µs |
| json (bytes as base64) | 4.8 µs | 10 µs | 450 µs | 8,193 µs | 184 µs | 331 µs |

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
- **ETF is the default codec because it is faster.** Against Portals'
  MessagePack it cuts a 1 MiB round trip from 10.1 ms to 4.0 ms (ErlPort:
  8.6 ms), 1,000 integers from 2.6 to 1.8 ms and 64 KiB from 485 to
  362 µs, and is level elsewhere. On the BEAM it encodes and decodes up to
  10 times faster than Portals' MessagePack codec (records), and level on
  64 KiB binaries.
- **The pure-Python codecs are the slow part on structured data.** Portals'
  two and ErlPort's are 15 to 30 times slower than the msgpack C extension
  on integers and records, which is why zerorpc, slow everywhere else, is
  fastest on those.
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
