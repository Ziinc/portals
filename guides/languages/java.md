# Java

Run Java code from Elixir in supervised, pooled JVM processes. The
`portals_java` package bundles the dependency-free Java worker SDK as a
prebuilt `portals.jar` (compiled for Java 17) and puts it first on each
worker's classpath. Nothing comes from Maven. Your own classes and jars go
on the classpath after it.

**Requirements:** JDK 17 or newer: `javac` to compile your handlers, and
`java` on the machine that runs the workers. The SDK uses only the JDK
standard library, including `java.nio`'s Unix-domain sockets.

This page walks through a complete worker, a `TextTools` class that counts
words, parses integers, reports progress back to Elixir, messages a process
and streams text. The same example exists for every language, and the code
below is exactly the code Portals' own test suite runs.

## 1. Install

```elixir
# mix.exs
def deps do
  [
    {:portals_java, "~> 0.1.0"}
  ]
end
```

`portals_java` depends on `portals`, so this is the only line you need.

## 2. Write the handlers

Handlers are public static methods. Elixir calls them by wire name, which
matches the method name exactly or in camelCase (`"word_count"` ->
`wordCount`). Mark streaming targets with `@StreamHandler`.

```java
// priv/java/src/com/example/TextTools.java
package com.example;

import java.util.List;
import portals.Pid;
import portals.Portals;
import portals.Stream;
import portals.StreamHandler;

public final class TextTools {
  private TextTools() {}

  // The wire name "word_count" maps onto wordCount.
  public static long wordCount(String text) {
    String trimmed = text.strip();
    return trimmed.isEmpty() ? 0 : trimmed.split("\\s+").length;
  }

  public static long parseInt(String text) {
    return Long.parseLong(text); // a NumberFormatException becomes %Portals.Error{kind: :remote}
  }

  public static long progress(long steps) throws InterruptedException {
    for (long step = 1; step <= steps; step++) {
      // Blocks this handler's thread until MyApp.Progress.report/1 returns.
      Portals.callback("Elixir.MyApp.Progress", "report", List.of(step));
    }
    return steps;
  }

  public static String notify(Pid pid, String text) {
    Portals.sendMessage(pid, text.toUpperCase()); // fire-and-forget
    return "sent";
  }

  @StreamHandler
  public static long upcaseStream(Stream stream) throws InterruptedException {
    long count = 0;
    for (Object chunk : stream) { // ends when the BEAM half-closes its side
      stream.send(((String) chunk).toUpperCase()); // blocks while the BEAM's credit is used up
      count++;
    }
    return count; // the stream's final result
  }
}
```

## 3. Write the entry point

```java
// priv/java/src/com/example/RunWorker.java
package com.example;

import portals.Worker;

public final class RunWorker {
  private RunWorker() {}

  // Portals starts this class and appends the socket path as the last argument.
  public static void main(String[] args) throws Exception {
    new Worker()
        .maxConcurrency(8)
        .maxStreams(4)
        .register("text_tools", TextTools.class)
        .run(args);
    System.exit(0);
  }
}
```

`register(name, Class)` exposes that class's public static methods under
the module name Elixir uses. A registered object instance also exposes its
public instance methods, and `.function(module, name, lambda)` registers a
single lambda. `run(args)` blocks until the BEAM shuts the worker down;
`System.exit(0)` then ends the JVM even if a library left non-daemon
threads running. Unary calls run on a pool of `maxConcurrency` threads and
streams on a separate pool of `maxStreams`.

## 4. Compile against the bundled jar

`mix portals.sdk_path java` prints the path to `portals.jar` as its last
line of output (a first run may also print dependency compilation
messages, hence the `tail`):

```sh
javac --release 17 -d priv/java/classes \
  -cp "$(mix portals.sdk_path java | tail -n 1)" \
  $(find priv/java/src -name '*.java')
```

Run this whenever the Java sources change, for example from a Mix alias
before `compile`, or from your build image.

## 5. Start a pool

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Portals.Pool,
     Portals.Java.worker_opts(
       main: "com.example.RunWorker",
       classpath: [Application.app_dir(:my_app, "priv/java/classes")],
       name: MyApp.Java,
       size: 4
     )}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

| Option | Default | Use it for |
|---|---|---|
| `:main` | required | The class whose `main` runs the worker |
| `:classpath` | `[]` | Your class directories and jars, after `portals.jar` |
| `:java` | `"java"` | A specific JDK, e.g. `"/usr/lib/jvm/java-21/bin/java"` |
| `:java_args` | `[]` | JVM flags, e.g. `["-Xmx256m", "-XX:+UseSerialGC"]` |
| `:args` | `[]` | Arguments to `main` (before the socket path Portals appends) |
| `:env` | `[]` | Extra environment variables |

## 6. Call it

```elixir
iex> Portals.Pool.call(MyApp.Java, "text_tools", "word_count", ["hello world"])
{:ok, 2}

iex> Portals.Pool.call(MyApp.Java, "text_tools", "parse_int", ["12"])
{:ok, 12}
```

## 7. Errors

Any exception thrown by a handler becomes a structured error.
`exception_type` is the exception's fully qualified class name:

```elixir
iex> {:error, error} = Portals.Pool.call(MyApp.Java, "text_tools", "parse_int", ["nope"])
iex> error.kind
:remote
iex> error.remote["exception_type"]
"java.lang.NumberFormatException"
```

`error.message` holds the exception message and `error.stacktrace` the
worker-side stack trace as a list of strings. Use `Portals.Pool.call!/5` to
raise `Portals.CallError` instead.

## 8. Call back into Elixir

`Portals.callback(module, function, args)` runs an Elixir function and
returns its result. The `progress` handler above calls this module:

```elixir
defmodule MyApp.Progress do
  require Logger

  def report(step) do
    Logger.info("text_tools progress: step #{step}")
    :ok
  end
end
```

```elixir
iex> Portals.Pool.call(MyApp.Java, "text_tools", "progress", [3])
{:ok, 3}
```

The callback blocks only the handler's own thread. An overload takes a
timeout in milliseconds. A failing Elixir function throws
`portals.RemoteException` and a timeout `portals.CallbackTimeoutException`,
both unchecked.

## 9. Send messages to Elixir processes

A PID passed as an argument arrives as an opaque `portals.Pid`:

```elixir
iex> Portals.Pool.call(MyApp.Java, "text_tools", "notify", [self(), "hi"])
{:ok, "sent"}
iex> flush()
{:portals_message, #PID<0.312.0>, "HI"}
```

## 10. Stream

A `@StreamHandler` method receives a `portals.Stream` first. Iterating it
yields inbound chunks until Elixir half-closes its side, and `send` blocks
while Elixir's credit window is full. The return value is the stream's
final result.

```elixir
{:ok, worker} = Portals.start_worker(Portals.Java.worker_opts(main: "com.example.RunWorker", classpath: [Application.app_dir(:my_app, "priv/java/classes")]))

{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 3} = Portals.Stream.await(stream)
```

Streams also have `recv()` / `recv(timeoutMs)` (returns `null` at the end),
`sendAll(chunks)` and `halfClose()`.

## 11. Deploy

- Compile your classes into `priv/java/classes` (or package a jar into
  `priv/java/`) before `mix release`, and build paths with
  `Application.app_dir/2`. The release copies `priv/`, including
  `portals.jar` from `portals_java`.
- The release machine needs a Java 17+ runtime (a JRE is enough at
  run time).
- Point your IDE's project libraries at `mix portals.sdk_path java` to get
  completion for `portals.*`.

## Values

| Elixir | Java | Back to Elixir |
|---|---|---|
| `nil`, `true`, `false` | `null`, `Boolean` | same |
| integer | `Long`, or `BigInteger` beyond 64-bit | integer (`int`, `long`, `BigInteger`, ...) |
| float | `Double` | float (an integral `double` still encodes as a float) |
| string | `String` | string |
| `%Portals.Codec.Bin{data: bytes}` | `byte[]` | `byte[]` becomes `%Portals.Codec.Bin{}` |
| list | `List<Object>` | any `List` |
| map | `Map<String, Object>` | map with string keys |
| tuple / atom | `portals.Tuple` / `portals.Atom` | tuple / atom (if it already exists) |
| PID / reference | `portals.Pid` / `portals.Ref` (opaque) | the same PID / reference |
| improper list | `portals.ImproperList` | improper list |

Arguments are adapted to the declared parameter types: integers to
`long`/`int`/`short`/`byte`/`BigInteger` when they fit, numbers to
`double`/`float`, atoms to `String`. Anything else must already be an
instance of the declared type, so declare `Object` to accept any term.
Overloads are chosen by argument count.

## Handler API

| Method | Meaning |
|---|---|
| `Portals.callback(mod, fun, args[, timeoutMs])` | Call an Elixir function and wait for its result |
| `Portals.sendMessage(pid, value)` | Fire-and-forget message to a PID |
| `Portals.isCancelled()` | `true` once Elixir has cancelled the current call |
| `Portals.currentDeadlineMs()` | The `:deadline_ms` the caller attached, or `null` |
| `Portals.currentCallbackDepth()` | How deeply nested in callbacks the current call is |

## Gotchas

- **JVM startup counts against the connect timeout.** A worker must start,
  load your classes and connect within `connect_timeout:` (default 5
  seconds), and the same applies on every restart. Keep `main` light, and
  for fast starts consider
  `java_args: ["-XX:TieredStopAtLevel=1", "-Xshare:auto"]`.
- **Every worker is a whole JVM.** A pool of 8 is 8 heaps. Set `-Xmx` in
  `:java_args` and size pools for memory, not just CPU.
- **Compile against the bundled jar.** At run time `portals.jar` from
  `portals_java` is first on the classpath, so classes compiled against
  some other copy of the SDK can fail with `NoSuchMethodError`. Always
  compile with `-cp "$(mix portals.sdk_path java | tail -n 1)"`, and never
  put a second `portals` jar on `:classpath`.
- **Wrap raw bytes in `%Portals.Codec.Bin{}`.** A plain Elixir binary that
  is not valid UTF-8 is decoded as a `String` with the invalid bytes
  replaced by U+FFFD, so the data is silently corrupted. Wrapped bytes arrive
  as `byte[]`.
- **`System.out` goes nowhere.** stdout and stderr are discarded under the
  default transport. Set `PORTALS_LOG_FILE`, or pass `.logger(message ->
  ...)` to the `Worker`.
- **Lambda-registered handlers bypass type adaptation.** Handlers
  registered with `.function(...)` receive raw decoded `List<Object>`
  arguments (`Long`, `String`, ...); cast them yourself.
- **Cancellation is cooperative.** Poll `Portals.isCancelled()` in long
  loops. Cancelling a stream does interrupt a pending `send`/`recv`.

## Best practices

- Keep handler classes stateless with static methods. Use instance
  registration (`register("cache", new CacheHandlers(...))`) when you need
  shared, thread-safe state such as a connection pool.
- Do expensive initialization in `main` before `run(args)`, within the
  connect timeout, so the first call doesn't pay for it.
- Declare precise parameter types (`String`, `long`) to get automatic
  conversion and clear errors, and `Object` only where any term is valid.
- Return `Map`, `List`, `String`, numbers and `byte[]`, not domain
  objects.
