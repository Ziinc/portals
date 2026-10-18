# PHP

Run PHP code from Elixir in supervised, pooled PHP CLI processes. The
`portals_php` package bundles a dependency-free worker SDK and loads it
into each worker with PHP's `auto_prepend_file` setting, so the
`Portals\` classes and functions are available without a `require` or a
Composer package. Your own Composer dependencies keep working through your
autoloader.

**Requirements:** the PHP 8.1+ CLI, 64-bit, with the standard `mbstring`
extension, on the machine that runs the workers. No other extensions are
needed (no `pcntl`, no `parallel`).

This page walks through a complete worker, a `text_tools` module that
counts words, parses integers, reports progress back to Elixir, messages a
process and streams text. The same example exists for every language, and
the code below is exactly the code Portals' own test suite runs.

## 1. Install

```elixir
# mix.exs
def deps do
  [
    {:portals_php, "~> 0.1.0"}
  ]
end
```

`portals_php` depends on `portals`, so this is the only line you need.

## 2. Write the handlers

Handlers are public static methods. Method names are matched exactly or in
camelCase form (`"word_count"` also finds `wordCount`). Mark streaming
targets with the `#[Portals\StreamHandler]` attribute.

```php
// priv/php/TextTools.php
<?php

declare(strict_types=1);

use Portals\Pid;
use Portals\Stream;
use Portals\StreamHandler;

final class TextTools
{
    public static function word_count(string $text): int
    {
        return count(preg_split('/\s+/', trim($text), -1, PREG_SPLIT_NO_EMPTY));
    }

    public static function parse_int(string $text): int
    {
        if (filter_var($text, FILTER_VALIDATE_INT) === false) {
            // Becomes %Portals.Error{kind: :remote}.
            throw new InvalidArgumentException("not an integer: {$text}");
        }
        return (int) $text;
    }

    public static function progress(int $steps): int
    {
        for ($step = 1; $step <= $steps; $step++) {
            // Suspends only this call's fiber until MyApp.Progress.report/1 returns.
            Portals\callback('Elixir.MyApp.Progress', 'report', [$step]);
        }
        return $steps;
    }

    public static function notify(Pid $pid, string $text): string
    {
        Portals\send_message($pid, strtoupper($text)); // fire-and-forget
        return 'sent';
    }

    #[StreamHandler]
    public static function upcase_stream(Stream $stream): int
    {
        $count = 0;
        foreach ($stream as $chunk) {          // ends when the BEAM half-closes its side
            $stream->send(strtoupper($chunk)); // waits while the BEAM's credit is used up
            $count++;
        }
        return $count;                         // the stream's final result
    }
}
```

## 3. Write the entry script

```php
// priv/php/worker.php
<?php

declare(strict_types=1);

// Portals starts this script and appends the socket path as the last
// argument. The SDK is already loaded (auto_prepend_file).
require __DIR__ . '/TextTools.php';

(new Portals\Worker(
    maxConcurrency: 8,
    maxStreams: 4,
    modules: ['text_tools' => TextTools::class],
))->run();
```

`modules:` maps the name Elixir uses in `CALL` to a class name, an object,
or an array of `name => callable`. Without an entry, the SDK looks for a
loaded or autoloadable class (`"text_tools"` -> `TextTools`,
`"MyApp.Text"` -> `MyApp\Text`) or a `<module>.php` file in `modulePaths`
(default: the working directory, which is the BEAM's). `maxConcurrency`
bounds how many calls run at once. `maxStreams` is a separate budget for
streams.

If you use Composer, require your autoloader at the top of `worker.php`:
`require __DIR__ . '/vendor/autoload.php';`.

## 4. Start a pool

```elixir
# lib/my_app/application.ex
def start(_type, _args) do
  children = [
    {Portals.Pool,
     Portals.PHP.worker_opts(
       script: Application.app_dir(:my_app, "priv/php/worker.php"),
       name: MyApp.PHP,
       size: 4
     )}
  ]

  Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
end
```

| Option | Default | Use it for |
|---|---|---|
| `:php` | `"php"` | A specific CLI binary, e.g. `"/usr/bin/php8.3"` |
| `:php_args` | `[]` | `php.ini` overrides, e.g. `["-d", "memory_limit=512M"]` |
| `:prepend_sdk` | `true` | Set to `false` if your `php.ini` already uses `auto_prepend_file` (see Gotchas) |
| `:args` | `[]` | Arguments to your script (before the socket path Portals appends) |
| `:env` | `[]` | Extra environment variables |

## 5. Call it

```elixir
iex> Portals.Pool.call(MyApp.PHP, "text_tools", "word_count", ["hello world"])
{:ok, 2}

iex> Portals.Pool.call(MyApp.PHP, "text_tools", "parse_int", ["12"])
{:ok, 12}
```

## 6. Errors

```elixir
iex> {:error, error} = Portals.Pool.call(MyApp.PHP, "text_tools", "parse_int", ["nope"])
iex> error.kind
:remote
iex> error.remote["exception_type"]
"InvalidArgumentException"
```

`error.message` holds the exception message and `error.stacktrace` the
worker-side stack trace as a list of strings. Use `Portals.Pool.call!/5` to
raise `Portals.CallError` instead.

## 7. Call back into Elixir

`Portals\callback($module, $function, $args)` runs an Elixir function and
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
iex> Portals.Pool.call(MyApp.PHP, "text_tools", "progress", [3])
{:ok, 3}
```

The callback suspends only the current call's fiber, so the worker keeps
serving other calls meanwhile. The fourth argument is a timeout in
seconds. A failing Elixir function throws `Portals\RemoteError`.

## 8. Send messages to Elixir processes

A PID passed as an argument arrives as an opaque `Portals\Pid`:

```elixir
iex> Portals.Pool.call(MyApp.PHP, "text_tools", "notify", [self(), "hi"])
{:ok, "sent"}
iex> flush()
{:portals_message, #PID<0.312.0>, "HI"}
```

## 9. Stream

A `#[StreamHandler]` method receives a `Portals\Stream` first.
`foreach` yields inbound chunks until Elixir half-closes its side, and
`$stream->send()` waits while Elixir's credit window is full. The return
value is the stream's final result.

```elixir
{:ok, worker} = Portals.start_worker(Portals.PHP.worker_opts(script: Application.app_dir(:my_app, "priv/php/worker.php")))

{:ok, stream} = Portals.open_stream(worker, "text_tools", "upcase_stream", [])
:ok = Portals.Stream.send_enumerable(stream, ["a", "b", "c"])
["A", "B", "C"] = stream |> Portals.Stream.to_enumerable() |> Enum.to_list()
{:ok, 3} = Portals.Stream.await(stream)
```

Streams also have `$stream->recv($timeout)` (returns `null` at the end),
`$stream->sendAll($chunks)` and `$stream->halfClose()`. Timeouts are in
seconds.

## 10. Deploy

- Keep the PHP files in `priv/php/` (with `vendor/` if you use Composer)
  and build paths with `Application.app_dir(:my_app, "priv/php/...")`.
  `mix release` copies `priv/`, including the SDK bundled in `portals_php`.
- Install the PHP CLI in the release image, and run
  `composer install --no-dev --optimize-autoloader` in `priv/php` while
  building it.
- `mix portals.sdk_path php` prints the SDK's `src` directory. Add it to
  your IDE's include paths (PhpStorm: *PHP > Include Path*; Intelephense:
  `intelephense.environment.includePaths`) for completion on `Portals\`.

## Values

| Elixir | PHP | Back to Elixir |
|---|---|---|
| `nil`, `true`, `false` | `null`, `true`, `false` | same |
| integer | `int`; beyond 64-bit, `Portals\BigInt` | integer |
| float | `float` | float |
| string | `string` | string (plain PHP strings are always sent as text) |
| `%Portals.Codec.Bin{data: bytes}` | `Portals\Bin` | wrap bytes in `new Portals\Bin(...)` to send `%Portals.Codec.Bin{}` |
| list | list `array` | list |
| map | `Portals\Map` (array-like) | any non-list `array` or a `Portals\Map` becomes a map |
| tuple / atom | `Portals\Tuple` / `Portals\Atom` | tuple / atom (if it already exists) |
| PID / reference | `Portals\Pid` / `Portals\Reference` (opaque) | the same PID / reference |
| improper list | `Portals\ImproperList` | improper list |

## Handler API

| Function | Meaning |
|---|---|
| `Portals\callback($mod, $fun, $args, $timeout)` | Call an Elixir function and wait for its result |
| `Portals\send_message($pid, $value)` | Fire-and-forget message to a PID |
| `Portals\is_cancelled()` | `true` once Elixir has cancelled the current call |
| `Portals\current_deadline_ms()` | The `:deadline_ms` the caller attached, or `null` |
| `Portals\current_callback_depth()` | How deeply nested in callbacks the current call is |
| `Portals\sleep($seconds)` | Cooperative sleep that suspends only this call |

## Gotchas

- **One thread per worker; blocking calls block everything.** Calls run as
  fibers on a single event loop. Native `sleep()`, blocking `curl_exec`,
  PDO queries and long CPU loops stall every other call on that worker until
  they finish. Use `Portals\sleep()` for waits, and scale blocking work with
  pool `:size` rather than `maxConcurrency`.
- **Empty arrays are lists.** PHP can't tell `[]` from an empty map, so an
  empty array reaches Elixir as `[]`. Return `new Portals\Map([])` when
  Elixir expects `%{}`. Maps you receive are `Portals\Map` objects for the
  same reason; use `$map['key']` or `$map->toArray()`.
- **Bytes must be wrapped both ways.** Return `new Portals\Bin($bytes)` for
  binary data. A plain PHP string is always sent as text.
- **`auto_prepend_file` is a single setting.** If your `php.ini` already
  prepends a file, Portals' `-d auto_prepend_file=...` replaces it for the
  worker. Pass `prepend_sdk: false` and load the SDK yourself with
  `require_once getenv('PORTALS_SDK_PATH') . '/portals.php';`. Use
  `require_once`, not `require`: loading the SDK twice is a fatal
  redeclaration error.
- **`echo` output goes nowhere.** stdout and stderr are discarded under the
  default transport. Set `PORTALS_LOG_FILE`, or pass `logger: fn (string
  $message) => ...` to `new Portals\Worker(...)`.
- **The CLI's `memory_limit` applies.** Long-lived workers that accumulate
  data can hit it. Set it with `php_args: ["-d", "memory_limit=..."]`.
- **Code is loaded once.** OPcache or not, changed files take effect only
  after the worker restarts.

## Best practices

- Register every module in `modules:`. It keeps arbitrary classes from
  being callable and skips the lookup.
- Prefer static methods and keep handlers stateless. An instance-method
  handler class is instantiated once (no-argument constructor) and reused
  across calls, so its properties are shared state.
- Use `Portals\sleep()` and fiber-friendly I/O; anything else serializes
  the worker.
- Use typed parameters (`string $text`, `int $steps`). Mismatched
  arguments then fail with a clear `TypeError` reported to Elixir.
- Return plain arrays and scalars. Convert objects with
  `JsonSerializable` or `get_object_vars()` first.
