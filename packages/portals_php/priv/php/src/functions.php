<?php

declare(strict_types=1);

namespace Portals;

/*
 * Handler-context helpers. Each acts on the CALL running in the current
 * fiber of the process's active `Worker`.
 */

/**
 * Invoke a BEAM callback from within a CALL handler and wait for its
 * result. Suspends only this handler's fiber, never the socket reader, so
 * a nested CALL dispatched back into this worker while the callback is
 * outstanding is still served. Throws `RemoteError` if the BEAM-side
 * handler fails, `TimeoutError` after `$timeout` seconds.
 */
function callback(string $module, string $function, array $args = [], ?float $timeout = null): mixed
{
    return active_worker('callback')->callCallback($module, $function, $args, $timeout);
}

/** Send a value to a BEAM PID (typically received as a CALL argument). Fire-and-forget. */
function send_message(Pid $target, mixed $value): void
{
    active_worker('send_message')->sendMessage($target, $value);
}

/** Reentrancy depth of the current CALL (0 for a top-level call). */
function current_callback_depth(): int
{
    return Worker::active()?->currentCallbackDepth() ?? 0;
}

/** The deadline (ms) the BEAM attached to the current CALL, if any. */
function current_deadline_ms(): int|BigInt|null
{
    return Worker::active()?->currentContext()?->deadlineMs;
}

/** Cooperative cancellation: true once the BEAM sent CANCEL for the current CALL. */
function is_cancelled(): bool
{
    return Worker::active()?->currentContext()?->cancelled ?? false;
}

/**
 * Cooperative sleep: suspends only the current fiber, letting the worker
 * keep serving other calls. Use instead of `\sleep()`/`\usleep()` inside
 * handlers. Outside a fiber it simply blocks.
 */
function sleep(float $seconds): void
{
    if (\Fiber::getCurrent() === null) {
        usleep((int) max($seconds * 1e6, 0));
        return;
    }
    $loop = Loop::get();
    $deferred = new Deferred($loop);
    $loop->delay($seconds, static fn () => $deferred->resolve());
    $deferred->await();
}

/** @internal */
function active_worker(string $helper): Worker
{
    return Worker::active()
        ?? throw new \LogicException("Portals\\{$helper}() called with no active Worker in this process");
}
