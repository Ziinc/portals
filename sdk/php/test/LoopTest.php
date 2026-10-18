<?php

declare(strict_types=1);

namespace Portals\Tests;

use Portals\Deferred;
use Portals\Loop;
use Portals\TimeoutError;

/** The cooperative scheduler every CALL handler runs on. */
final class LoopTest extends TestCase
{
    public function testCooperativeSleepsOverlapInsteadOfSerialising(): void
    {
        $loop = Loop::get();
        $order = [];
        foreach ([0.15, 0.05, 0.10] as $seconds) {
            $loop->spawn(static function () use ($seconds, &$order): void {
                \Portals\sleep($seconds);
                $order[] = $seconds;
            });
        }

        $started = Loop::now();
        $loop->run();
        $elapsed = Loop::now() - $started;

        $this->assertSame([0.05, 0.10, 0.15], $order);
        $this->assertTrue($elapsed < 0.28, "sleeps ran serially ({$elapsed}s)");
    }

    public function testDeferredResolvesASuspendedFiber(): void
    {
        $loop = Loop::get();
        $deferred = new Deferred($loop);
        $result = null;
        $loop->spawn(static function () use ($deferred, &$result): void {
            $result = $deferred->await();
        });
        $loop->delay(0.01, static fn () => $deferred->resolve('done'));
        $loop->run();
        $this->assertSame('done', $result);
    }

    public function testDeferredTimesOut(): void
    {
        $deferred = new Deferred(Loop::get());
        $this->assertThrows(TimeoutError::class, fn () => $deferred->await(0.01, 'too slow'));
    }
}
