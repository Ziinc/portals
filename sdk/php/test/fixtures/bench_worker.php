<?php

declare(strict_types=1);

use Portals\Atom;
use Portals\Bin;
use Portals\Pid;
use Portals\Stream;
use Portals\StreamHandler;
use Portals\Tuple;

/**
 * Function targets used by the Elixir integration tests — the PHP mirror of
 * `sdk/python/tests/fixtures/bench_worker.py`.
 *
 * Handlers wait with `Portals\sleep()`, which suspends only their own fiber,
 * never `\sleep()`/`\usleep()`, which would block the whole worker.
 */
final class BenchWorker
{
    public static function echo(mixed $value): mixed
    {
        return $value;
    }

    public static function add(int|float $a, int|float $b): int|float
    {
        return $a + $b;
    }

    public static function raise_error(string $message): never
    {
        throw new InvalidArgumentException($message);
    }

    public static function sleep_ms(int $ms): int
    {
        Portals\sleep($ms / 1000);
        return $ms;
    }

    public static function crash_process(): never
    {
        exit(1);
    }

    /** Calls back into the BEAM to double a number: a reentrant round trip. */
    public static function double_via_callback(int $n): mixed
    {
        return Portals\callback('Elixir.Portals.Fixtures.CallbackTarget', 'double', [$n]);
    }

    /**
     * A callback target the Elixir side invokes; while running (still inside
     * the BEAM-side callback handler) it reports the reentrancy depth the
     * BEAM echoed back on this nested CALL.
     */
    public static function nested_call_then_callback(mixed $connMarker, int $n): array
    {
        return ['depth_seen' => Portals\current_callback_depth(), 'doubled' => $n * 2];
    }

    public static function callback_depth_probe(): int
    {
        return Portals\current_callback_depth();
    }

    public static function deadline_probe(): mixed
    {
        return Portals\current_deadline_ms();
    }

    public static function message_to_caller(Pid $pid, mixed $value): string
    {
        Portals\send_message($pid, $value);
        return 'sent';
    }

    public static function raise_callback_error(): mixed
    {
        return Portals\callback('Elixir.Portals.Fixtures.CallbackTarget', 'boom', []);
    }

    // Value-model probes: proves the Erlang extensions survive a round trip
    // through PHP untouched.

    public static function echo_term(mixed $value): mixed
    {
        return $value;
    }

    public static function describe_term(mixed $value): string
    {
        return get_debug_type($value);
    }

    public static function make_tuple(array $items): Tuple
    {
        return new Tuple($items);
    }

    public static function make_atom(string $text): Atom
    {
        return new Atom($text);
    }

    /** Cooperative cancellation: polls the flag the CANCEL frame raises. */
    public static function cancellable(int $ms): string
    {
        $deadline = hrtime(true) + $ms * 1_000_000;
        while (hrtime(true) < $deadline) {
            if (Portals\is_cancelled()) {
                return 'cancelled';
            }
            Portals\sleep(0.005);
        }
        return 'completed';
    }

    // -- Streaming targets --------------------------------------------------

    /** Echo every inbound chunk back out, then terminate with a count. */
    #[StreamHandler]
    public static function echo_stream(Stream $stream): int
    {
        $count = 0;
        foreach ($stream as $chunk) {
            $stream->send($chunk);
            $count++;
        }
        return $count;
    }

    /** Produce `count` chunks of `size` bytes each, blocking on the BEAM's credit window. */
    #[StreamHandler]
    public static function produce_stream(Stream $stream, int $count, int $size): int
    {
        $payload = str_repeat('x', $size);
        for ($i = 0; $i < $count; $i++) {
            $stream->send($payload, 10.0);
        }
        $stream->halfClose();
        return $count;
    }

    /** Consume everything the BEAM sends, optionally slowly. */
    #[StreamHandler]
    public static function drain_stream(Stream $stream, int $delayMs = 0): array
    {
        $chunks = 0;
        $bytes = 0;
        foreach ($stream as $chunk) {
            $chunks++;
            $bytes += strlen($chunk instanceof Bin ? $chunk->data : (string) $chunk);
            if ($delayMs > 0) {
                Portals\sleep($delayMs / 1000);
            }
        }
        return ['chunks' => $chunks, 'bytes' => $bytes];
    }

    /**
     * Never consume inbound chunks: the BEAM's sender must block on the
     * credit window rather than grow BEAM memory.
     */
    #[StreamHandler]
    public static function never_consume(Stream $stream, int $holdMs): string
    {
        Portals\sleep($holdMs / 1000);
        return 'held';
    }

    /**
     * Close only the worker's sending direction immediately, then keep
     * consuming — proving half-close is per-direction.
     */
    #[StreamHandler]
    public static function half_close_then_drain(Stream $stream): int
    {
        $stream->halfClose();
        $chunks = 0;
        while ($stream->recv() !== null) {
            $chunks++;
        }
        return $chunks;
    }

    /** Keep a stream open (and a stream slot busy), for unary/stream fairness tests. */
    #[StreamHandler]
    public static function hold_stream(Stream $stream, int $holdMs): string
    {
        Portals\sleep($holdMs / 1000);
        return 'done';
    }
}
