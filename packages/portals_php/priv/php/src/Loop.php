<?php

declare(strict_types=1);

namespace Portals;

/** Raised when a suspended wait (stream credit, callback, ...) times out. */
class TimeoutError extends \RuntimeException
{
}

/**
 * A minimal single-threaded event loop: deferred callbacks, monotonic
 * timers, and readable/writable stream watchers, multiplexed with
 * `stream_select`.
 *
 * PHP has no threads in a stock build, so the worker's concurrency model is
 * cooperative, like Node's: every CALL runs in its own `Fiber`, and anything
 * that would wait (a BEAM callback, stream credit, `Portals\sleep()`)
 * suspends only that fiber and hands control back to this loop, which keeps
 * reading frames. Resumption is always scheduled through `defer()` so a
 * fiber is never resumed from inside another fiber.
 */
final class Loop
{
    private static ?self $instance = null;

    /** @var \SplQueue<callable> */
    private \SplQueue $deferred;
    /** @var array<int, array{0: float, 1: callable}> */
    private array $timers = [];
    private int $nextTimerId = 0;
    /** @var array<int, array{0: resource, 1: callable}> */
    private array $readers = [];
    /** @var array<int, array{0: resource, 1: callable}> */
    private array $writers = [];
    private bool $stopped = false;

    public function __construct()
    {
        $this->deferred = new \SplQueue();
    }

    public static function get(): self
    {
        return self::$instance ??= new self();
    }

    /** Replace the process-wide loop (tests use a fresh one per case). */
    public static function reset(): self
    {
        return self::$instance = new self();
    }

    public static function now(): float
    {
        return hrtime(true) / 1e9;
    }

    public function defer(callable $callback): void
    {
        $this->deferred->enqueue($callback);
    }

    /** Run `$callback` after `$seconds`. Returns an id for `cancelTimer()`. */
    public function delay(float $seconds, callable $callback): int
    {
        $id = ++$this->nextTimerId;
        $this->timers[$id] = [self::now() + max($seconds, 0.0), $callback];
        return $id;
    }

    public function cancelTimer(?int $id): void
    {
        if ($id !== null) {
            unset($this->timers[$id]);
        }
    }

    /** @param resource $stream */
    public function onReadable($stream, ?callable $callback): void
    {
        $this->watch($this->readers, $stream, $callback);
    }

    /** @param resource $stream */
    public function onWritable($stream, ?callable $callback): void
    {
        $this->watch($this->writers, $stream, $callback);
    }

    private function watch(array &$set, $stream, ?callable $callback): void
    {
        $key = (int) $stream;
        if ($callback === null) {
            unset($set[$key]);
        } else {
            $set[$key] = [$stream, $callback];
        }
    }

    /** Start `$callback` in a new fiber on the next loop turn. */
    public function spawn(callable $callback, mixed ...$args): \Fiber
    {
        $fiber = new \Fiber($callback);
        $this->defer(static fn () => $fiber->start(...$args));
        return $fiber;
    }

    public function stop(): void
    {
        $this->stopped = true;
    }

    /** Run until `stop()`, or until there is nothing left to wait for. */
    public function run(): void
    {
        $this->stopped = false;
        while (!$this->stopped && $this->tick(true)) {
        }
    }

    /** Run until `$done()` is true (or nothing is left to wait for). */
    public function runUntil(callable $done): void
    {
        while (!$done() && $this->tick(true)) {
        }
    }

    /**
     * One loop iteration. Returns false when there is no pending work of any
     * kind, i.e. waiting would block forever.
     */
    public function tick(bool $block): bool
    {
        $count = $this->deferred->count();
        for ($i = 0; $i < $count; $i++) {
            ($this->deferred->dequeue())();
        }

        $this->fireTimers();

        if ($this->readers === [] && $this->writers === []) {
            if (!$this->deferred->isEmpty()) {
                return true;
            }
            if ($this->timers === []) {
                return false;
            }
            if ($block) {
                $wait = $this->untilNextTimer();
                if ($wait > 0) {
                    usleep((int) ceil($wait * 1e6));
                }
            }
            return true;
        }

        $timeout = (!$block || !$this->deferred->isEmpty()) ? 0.0 : $this->untilNextTimer();
        $read = array_column($this->readers, 0);
        $write = array_column($this->writers, 0);
        $except = null;
        $sec = $timeout === null ? null : (int) floor($timeout);
        $usec = $timeout === null ? 0 : (int) (($timeout - floor($timeout)) * 1e6);
        $ready = @stream_select($read, $write, $except, $sec, $usec);
        if ($ready === false) {
            // Interrupted (e.g. by a signal); just go round again.
            return true;
        }
        foreach ($write as $stream) {
            $watch = $this->writers[(int) $stream] ?? null;
            if ($watch !== null) {
                ($watch[1])($stream);
            }
        }
        foreach ($read as $stream) {
            $watch = $this->readers[(int) $stream] ?? null;
            if ($watch !== null) {
                ($watch[1])($stream);
            }
        }
        return true;
    }

    private function fireTimers(): void
    {
        if ($this->timers === []) {
            return;
        }
        $now = self::now();
        foreach ($this->timers as $id => [$at, $callback]) {
            if ($at <= $now) {
                unset($this->timers[$id]);
                $callback();
            }
        }
    }

    private function untilNextTimer(): ?float
    {
        if ($this->timers === []) {
            return null;
        }
        $next = min(array_column($this->timers, 0));
        return max($next - self::now(), 0.0);
    }
}

/**
 * A one-shot result a fiber can suspend on. `await()` suspends the current
 * fiber until `resolve()`/`reject()` (or the timeout); called outside any
 * fiber it drives the loop itself until settled.
 */
final class Deferred
{
    private bool $settled = false;
    private mixed $value = null;
    private ?\Throwable $error = null;
    private ?\Fiber $waiter = null;
    private ?int $timer = null;

    public function __construct(private readonly Loop $loop)
    {
    }

    public function isSettled(): bool
    {
        return $this->settled;
    }

    public function resolve(mixed $value = null): void
    {
        $this->settle($value, null);
    }

    public function reject(\Throwable $error): void
    {
        $this->settle(null, $error);
    }

    private function settle(mixed $value, ?\Throwable $error): void
    {
        if ($this->settled) {
            return;
        }
        $this->settled = true;
        $this->value = $value;
        $this->error = $error;
        $this->loop->cancelTimer($this->timer);
        $this->timer = null;

        $fiber = $this->waiter;
        $this->waiter = null;
        if ($fiber !== null) {
            $this->loop->defer(static function () use ($fiber): void {
                if ($fiber->isSuspended()) {
                    $fiber->resume();
                }
            });
        }
    }

    /** @param float|null $timeout seconds; null waits forever */
    public function await(?float $timeout = null, string $timeoutMessage = 'timed out'): mixed
    {
        if (!$this->settled && $timeout !== null) {
            $this->timer = $this->loop->delay(
                $timeout,
                fn () => $this->reject(new TimeoutError($timeoutMessage))
            );
        }

        if (!$this->settled) {
            $fiber = \Fiber::getCurrent();
            if ($fiber === null) {
                $this->loop->runUntil(fn () => $this->settled);
                if (!$this->settled) {
                    throw new \LogicException('deadlock: awaited outside a fiber with nothing left to run');
                }
            } else {
                $this->waiter = $fiber;
                \Fiber::suspend();
            }
        }

        if ($this->error !== null) {
            throw $this->error;
        }
        return $this->value;
    }
}
