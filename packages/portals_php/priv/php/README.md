# Portals PHP worker SDK

A PHP worker for [Portals](../../../../README.md), implementing the v1 wire
protocol in [`protocol/v1.md`](../../../../protocol/v1.md) with full parity with
the reference Python SDK.

This SDK ships inside the `portals_php` Hex package, which also puts it
on the worker's import path. **Application developers should start with the
[PHP guide](../../../../guides/languages/php.md)**; this README documents the
SDK itself.

Requires PHP 8.1+ (64-bit) and nothing else: no Composer packages and no
optional extensions. The MessagePack codec (including the Erlang value
extensions and arbitrary-precision bigints) is pure PHP in
`src/MsgpackCodec.php`; only core features and the `mbstring` extension
that every standard build bundles are used.

## Concurrency model

Stock PHP has no threads, so — like the Node SDK — the worker is a
single-threaded event loop (`stream_select`) and every `CALL` runs in its
own [`Fiber`](https://www.php.net/manual/en/language.fibers.php). A handler
that waits on a BEAM callback, on stream credit, or on `Portals\sleep()`
suspends only its own fiber, so the socket reader keeps reading frames and
other in-flight calls keep completing. `max_concurrency` and `max_streams`
bound how many fibers run at once, independently.

Because scheduling is cooperative, a handler that blocks the whole
process — native `sleep()`/`usleep()`, blocking I/O, a long CPU loop —
stalls every other call until it returns. Use `Portals\sleep()` to wait,
and run CPU-heavy work in a pool of workers (`Portals.start_pool/1`) rather
than relying on in-process parallelism. Neither `pcntl` nor `parallel` is
needed.

## Writing a worker

```php
<?php
// my_handlers.php
use Portals\Pid;
use Portals\Stream;
use Portals\StreamHandler;

final class MyHandlers
{
    public static function encode(string $text): array
    {
        return ['length' => strlen($text)];
    }

    public static function with_progress(int $n): int
    {
        // Reentrant callback back into the BEAM; suspends this handler's
        // fiber, never the socket reader.
        Portals\callback('Elixir.MyApp.Progress', 'report', [$n]);
        return $n * 2;
    }

    public static function notify(Pid $pid, mixed $value): string
    {
        Portals\send_message($pid, $value); // fire-and-forget to a BEAM PID
        return 'ok';
    }

    #[StreamHandler]
    public static function echo_stream(Stream $stream): int
    {
        $count = 0;
        foreach ($stream as $chunk) {   // waits for credit-backed data
            $stream->send($chunk);      // waits for the BEAM's credit grant
            $count++;
        }
        return $count;                  // becomes the stream's terminal RETURN
    }
}
```

```php
<?php
// run_worker.php — Portals appends the socket path as the last CLI argument.
// Portals.PHP.worker_opts/1 preloads the SDK with auto_prepend_file.
require __DIR__ . '/my_handlers.php';

(new Portals\Worker(
    maxConcurrency: 16,
    maxStreams: 8,
    modules: ['my_handlers' => MyHandlers::class],
))->run();
```

From Elixir:

```elixir
{:ok, conn} = Portals.start_worker(Portals.PHP.worker_opts(script: "run_worker.php"))
{:ok, %{"length" => 5}} = Portals.call(conn, "my_handlers", "encode", ["hello"])
{:ok, stream} = Portals.open_stream(conn, "my_handlers", "echo_stream", [])
```

## Dispatch

`CALL`'s `module` names a registered module, an already-loaded (or
autoloadable) class, or a `<module>.php` file in one of `modulePaths`
(default: the working directory) defining that class. Names are camelized
per segment, dots becoming namespace separators: `"my_handlers"` ->
`MyHandlers`, `"MyApp.Handlers"` -> `MyApp\Handlers`. A registered module
may be a class name, an object, or an array of `function name => callable`.

`function` matches a public method exactly or by its camelCase form
(`"sleep_ms"` -> `sleepMs`). Static methods are called statically; for
instance methods of a class name, one instance is created (no-argument
constructor) and reused. Mark streaming targets with
`#[Portals\StreamHandler]` (closures may carry the attribute too).

## Value mapping

| BEAM | PHP |
|---|---|
| `nil`, booleans, floats | `null`, `bool`, `float` |
| integers | `int`; beyond 64-bit signed range, `Portals\BigInt` |
| `"text"` (MessagePack `str`) | `string` |
| `%Portals.Codec.Bin{}` (MessagePack `bin`) | `Portals\Bin` |
| lists | list `array` |
| maps | `Portals\Map` (array-like); any non-list `array` encodes as a map |
| tuples / atoms | `Portals\Tuple` / `Portals\Atom` |
| PIDs / references | opaque `Portals\Pid` / `Portals\Reference` |
| improper lists | `Portals\ImproperList` |

Decoded maps are `Map` objects rather than arrays so that an empty map, or
one with numeric-looking keys, is never sent back as a list. Plain PHP
strings are always sent as `str`; wrap bytes in `new Portals\Bin(...)` to
send `bin`.

## Handler context

| Helper | Meaning |
|---|---|
| `Portals\callback($mod, $fun, $args, $timeout)` | Reentrant call back into the BEAM |
| `Portals\send_message($pid, $value)` | Fire-and-forget message to a BEAM PID |
| `Portals\current_callback_depth()` | Reentrancy depth of the current CALL |
| `Portals\current_deadline_ms()` | Deadline the BEAM attached to this CALL |
| `Portals\is_cancelled()` | True once the BEAM sent `CANCEL` for this CALL |
| `Portals\sleep($seconds)` | Cooperative sleep (suspends only this call) |

Timeouts (`callback`, `Stream::send`, `Stream::recv`) are in seconds.

## Logging

Never over the RPC protocol: set `PORTALS_LOG_FILE` for a file sink, or pass
`logger: fn (string $message) => ...` to `new Worker(...)`. The default is
stderr.

## Transports

`transport: 'unix'` (default) or `transport: 'stdio'` for the framed
stdin/stdout fallback.

## Tests

```sh
php test/run.php          # plain-PHP runner; no Composer or PHPUnit
```

The cross-language conformance and integration suites live on the Elixir
side: run `mix test` in `packages/portals_php`, or
`scripts/test_all.sh php` from the repository root.
