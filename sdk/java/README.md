# Portals Java worker SDK

A Java worker for [Portals](../../README.md), implementing the v1 wire
protocol in [`protocol/v1.md`](../../protocol/v1.md) with full parity with
the Python, Ruby and Node.js SDKs.

No dependencies and no build tool: everything, including the MessagePack
codec with the Erlang value extensions (`src/portals/MsgpackCodec.java`),
uses only the JDK standard library. JDK 17+ is required (Unix-domain
sockets come from `java.nio`'s `UnixDomainSocketAddress`).

## Writing a worker

```java
// MyHandlers.java
import java.util.List;
import java.util.Map;
import portals.Pid;
import portals.Portals;
import portals.Stream;
import portals.StreamHandler;

public final class MyHandlers {
  public static Map<String, Object> encode(String text) {
    return Map.of("length", text.length());
  }

  // Wire name "with_progress" maps onto withProgress.
  public static long withProgress(long n) throws InterruptedException {
    // Reentrant callback back into the BEAM; blocks this handler's thread,
    // never the socket reader.
    Portals.callback("MyApp.Progress", "report", List.of(n));
    return n * 2;
  }

  public static String notify(Pid pid, Object value) {
    Portals.sendMessage(pid, value); // fire-and-forget to a BEAM PID
    return "ok";
  }

  @StreamHandler
  public static long echoStream(Stream stream) throws InterruptedException {
    long count = 0;
    for (Object chunk : stream) {  // blocks until credit-backed data arrives
      stream.send(chunk);          // blocks until the BEAM grants credit
      count++;
    }
    return count;                  // becomes the stream's terminal RETURN
  }
}
```

```java
// RunWorker.java — Portals appends the socket path as the last CLI argument
import portals.Worker;

public final class RunWorker {
  public static void main(String[] args) throws Exception {
    new Worker()
        .maxConcurrency(16)
        .maxStreams(8)
        .register("my_handlers", MyHandlers.class)
        .run(args);
    System.exit(0);
  }
}
```

From Elixir:

```elixir
{:ok, conn} =
  Portals.start_worker(command: "java", args: ["-cp", "classes:portals.jar", "RunWorker"])

{:ok, %{"length" => 5}} = Portals.call(conn, "my_handlers", "encode", ["hello"])
{:ok, stream} = Portals.open_stream(conn, "my_handlers", "echo_stream", [])
```

## Dispatch

`CALL`'s `module` names a registered module, a fully qualified class name,
or a class in one of the worker's `modulePackage(...)`s whose PascalCased
name matches (`"my_handlers"` -> `MyHandlers`). A registered `Class`
exposes its public static methods; a registered object also exposes its
public instance methods. The `function` name matches a method either
exactly or camelCased (`"sleep_ms"` -> `sleepMs`).

Overloads are chosen by argument count, which doubles as default
arguments. Decoded arguments are adapted to the declared parameter types:
integers to `long`/`int`/`short`/`byte`/`BigInteger` when they fit, numbers
to `double`/`float`, atoms to `String`; anything else must already be an
instance of the declared type (declare `Object` to take any term).

Lambdas can be registered directly too:

```java
new Worker()
    .function("math", "add", args -> (Long) args.get(0) + (Long) args.get(1))
    .streamFunction("math", "count", (stream, args) -> { ... })
```

## Value model

| Wire | Java |
|---|---|
| `nil` / booleans | `null` / `Boolean` |
| integers | `Long`, or `BigInteger` beyond 64-bit signed range (bigints included) |
| floats | `Double` (an integral `double` still encodes as a float) |
| `str` | `String` |
| `bin` | `byte[]` (encode a `byte[]` or `Bin` to force `bin`) |
| arrays | `List<Object>` |
| maps | string-keyed `Map<String, Object>` |
| tuple / atom / improper list | `Tuple` / `Atom` / `ImproperList` |
| pid / reference | opaque `Pid` / `Ref` (store and echo back, never construct) |

`Values.termsEqual` compares decoded terms structurally.

## Handler context

| Helper | Meaning |
|---|---|
| `Portals.callback(mod, fun, args[, timeoutMs])` | Reentrant call back into the BEAM |
| `Portals.sendMessage(pid, value)` | Fire-and-forget message to a BEAM PID |
| `Portals.currentCallbackDepth()` | Reentrancy depth of the current CALL |
| `Portals.currentDeadlineMs()` | Deadline the BEAM attached to this CALL, or `null` |
| `Portals.isCancelled()` | True once the BEAM sent `CANCEL` for this CALL |

Unary calls run on a fixed pool of `maxConcurrency` threads and streams on
a separate pool of `maxStreams` threads, so neither budget can starve the
other; the socket reader never runs a handler. Cancellation is cooperative:
poll `Portals.isCancelled()`. Cancelling a stream unblocks its handler's
pending `send`/`recv`.

## Logging

Never over the RPC protocol: set `PORTALS_LOG_FILE` for a file sink, or pass
`.logger(message -> ...)`; otherwise log lines go to stderr. Under the stdio
transport `System.out` is redirected to stderr, so stray `println`s cannot
corrupt the frame stream.

## Transports

`Worker.Transport.UNIX` (default) or `Worker.Transport.STDIO` for the framed
stdin/stdout fallback.

## Building and tests

```sh
./build.sh   # javac into build/classes (no-op when up to date)
./test.sh    # the SDK's unit tests (JDK only, no test framework)
```

The fixtures in `test/fixtures/` (`BenchWorker`, `ConformanceWorker`,
`RunWorker`, `RunWorkerStdio`) are launched through `run_worker.sh` /
`run_worker_stdio.sh`, which compile on first use, so the cross-language
suites on the Elixir side need only `java`/`javac` on `PATH`:
`mix test test/conformance/sdk_conformance_test.exs
test/integration/java_worker_test.exs`.
