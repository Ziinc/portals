<?php

declare(strict_types=1);

namespace Portals\Tests;

use Portals\Deferred;
use Portals\Loop;
use Portals\MsgpackCodec;
use Portals\Protocol;
use Portals\Stream;
use Portals\StreamClosed;
use Portals\StreamHandler;
use Portals\StreamProtocolError;
use Portals\TimeoutError;

/**
 * Mirrors `packages/portals_ruby/priv/ruby/test/test_streams.rb`: the credit window, the
 * independent queued-frame cap, per-direction half-close, and
 * cancellation. Blocking senders run in fibers on the event loop where the
 * Ruby tests use threads.
 */
final class StreamTest extends TestCase
{
    private const WINDOW = 1024;
    private const MAX_FRAMES = 4;

    /** @var list<string> */
    private array $sent = [];
    private Stream $stream;
    private Loop $loop;

    public function setUp(): void
    {
        $this->loop = Loop::get();
        $this->stream = new Stream(
            7,
            self::WINDOW,
            self::MAX_FRAMES,
            function (string $bytes): void {
                $this->sent[] = $bytes;
            },
            static fn (array $envelope) => MsgpackCodec::encode($envelope, Protocol::DEFAULT_LIMITS),
            $this->loop
        );
    }

    private function sentFrames(): array
    {
        return array_map(static fn (string $bytes) => MsgpackCodec::decode($bytes)[0], $this->sent);
    }

    /** Run `$callback` in a fiber; returns a Deferred settled with its outcome. */
    private function inFiber(callable $callback): Deferred
    {
        $done = new Deferred($this->loop);
        $this->loop->spawn(static function () use ($callback, $done): void {
            try {
                $done->resolve($callback());
            } catch (\Throwable $e) {
                $done->reject($e);
            }
        });
        return $done;
    }

    /** Let the loop run briefly so parked fibers get a chance to proceed. */
    private function settle(float $seconds = 0.02): void
    {
        $until = Loop::now() + $seconds;
        $this->loop->runUntil(static fn () => Loop::now() >= $until);
        $this->loop->tick(false);
    }

    public function testInitialGrantOffersTheWholeWindowOnce(): void
    {
        $this->assertSame(self::WINDOW, $this->stream->initialGrant());
        $this->assertSame(0, $this->stream->initialGrant());
    }

    public function testInboundBeyondTheGrantedWindowIsRejected(): void
    {
        $this->stream->initialGrant();
        $this->stream->recordInbound('a', 512);
        $this->assertThrows(StreamProtocolError::class, fn () => $this->stream->recordInbound('b', 600));
    }

    public function testTinyFrameFloodHitsTheFrameLimitWhileBytesRemain(): void
    {
        $this->stream->initialGrant();
        for ($i = 0; $i < self::MAX_FRAMES; $i++) {
            $this->stream->recordInbound((string) $i, 8);
        }
        $this->assertThrows(StreamProtocolError::class, fn () => $this->stream->recordInbound('one too many', 8));
    }

    public function testConsumingReplenishesExactlyWhatWasConsumed(): void
    {
        $this->stream->initialGrant();
        $this->stream->recordInbound('chunk', 100);

        $this->assertSame('chunk', $this->stream->recv());
        $credit = $this->sentFrames()[\count($this->sent) - 1];
        $this->assertSame([Protocol::CREDIT, 7, 100, 1], $credit);
    }

    public function testRecvReturnsNullAfterThePeerHalfCloses(): void
    {
        $this->stream->peerHalfClosed();
        $this->assertNull($this->stream->recv());
    }

    public function testRecvWaitsForInboundData(): void
    {
        $this->stream->initialGrant();
        $received = $this->inFiber(fn () => $this->stream->recv());
        $this->settle();
        $this->assertFalse($received->isSettled());

        $this->stream->recordInbound('late', 16);
        $this->assertSame('late', $received->await(2.0));
    }

    public function testRecvTimesOut(): void
    {
        $received = $this->inFiber(fn () => $this->stream->recv(0.01));
        $this->assertThrows(TimeoutError::class, fn () => $received->await(2.0));
    }

    public function testInboundAfterHalfCloseIsAProtocolError(): void
    {
        $this->stream->initialGrant();
        $this->stream->peerHalfClosed();
        $this->assertThrows(StreamProtocolError::class, fn () => $this->stream->recordInbound('late', 8));
    }

    public function testSendBlocksUntilCreditArrives(): void
    {
        $sending = $this->inFiber(fn () => $this->stream->send('payload'));
        $this->settle();
        $this->assertSame(0, \count($this->sent));

        $this->stream->addSendCredit(self::WINDOW, 0);
        $sending->await(2.0);

        $this->assertSame(1, \count($this->sent));
        $this->assertSame([Protocol::STREAM_DATA, 7, 'payload'], $this->sentFrames()[0]);
    }

    public function testSendIsChargedTheFullFrameSize(): void
    {
        $payload = MsgpackCodec::encode([Protocol::STREAM_DATA, 7, 'payload']);
        $frameSize = \strlen($payload) + Protocol::FRAME_PREFIX_BYTES;

        $this->stream->addSendCredit($frameSize, 0);
        $this->stream->send('payload');

        // Exactly one frame's worth of credit was granted, so the next send
        // parks until more arrives.
        $second = $this->inFiber(function () {
            try {
                $this->stream->send('payload');
                return 'sent';
            } catch (StreamClosed) {
                return 'unblocked';
            }
        });
        $this->settle();
        $this->assertSame(1, \count($this->sent));
        $this->stream->cancel();
        $this->assertSame('unblocked', $second->await(2.0));
    }

    public function testSendRespectsTheUnacknowledgedFrameLimit(): void
    {
        $this->stream->addSendCredit(self::WINDOW, 0);
        for ($i = 0; $i < self::MAX_FRAMES; $i++) {
            $this->stream->send('x');
        }
        $this->assertSame(self::MAX_FRAMES, \count($this->sent));

        $parked = $this->inFiber(fn () => $this->stream->send('x'));
        $this->settle();
        $this->assertSame(self::MAX_FRAMES, \count($this->sent));

        $this->stream->addSendCredit(0, self::MAX_FRAMES);
        $parked->await(2.0);
        $this->assertSame(self::MAX_FRAMES + 1, \count($this->sent));
    }

    public function testAChunkLargerThanTheWindowCanNeverBeSent(): void
    {
        $this->stream->addSendCredit(self::WINDOW, 0);
        $this->assertThrows(StreamProtocolError::class, fn () => $this->stream->send(str_repeat('x', self::WINDOW * 2)));
    }

    public function testHalfCloseIsPerDirectionAndIdempotent(): void
    {
        $this->stream->initialGrant();
        $this->stream->halfClose();
        $this->stream->halfClose();

        $halfCloses = array_filter($this->sentFrames(), static fn ($frame) => $frame[0] === Protocol::HALF_CLOSE);
        $this->assertSame(1, \count($halfCloses));
        $this->assertThrows(StreamClosed::class, fn () => $this->stream->send('late'));

        // The receiving direction is untouched.
        $this->stream->recordInbound('still-arriving', 32);
        $this->assertSame('still-arriving', $this->stream->recv());
    }

    public function testCancelReleasesStateAndUnblocksAParkedSender(): void
    {
        $this->stream->initialGrant();
        $this->stream->recordInbound('queued', 32);

        $parked = $this->inFiber(fn () => $this->stream->send('parked'));
        $this->settle();
        $this->stream->cancel();

        $this->assertThrows(StreamClosed::class, fn () => $parked->await(2.0));
        $this->assertTrue($this->stream->isCancelled());
        $this->assertNull($this->stream->recv());
    }

    public function testIteratingYieldsChunksUntilHalfClose(): void
    {
        $this->stream->initialGrant();
        $this->stream->recordInbound('a', 16);
        $this->stream->recordInbound('b', 16);
        $this->stream->peerHalfClosed();
        $this->assertSame(['a', 'b'], iterator_to_array($this->stream, false));
    }

    public function testStreamHandlerAttributeMarksMethods(): void
    {
        $handlers = new class () {
            #[StreamHandler]
            public function marked(Stream $stream): Stream
            {
                return $stream;
            }

            public function unmarked(): void
            {
            }
        };

        $marked = new \ReflectionMethod($handlers, 'marked');
        $unmarked = new \ReflectionMethod($handlers, 'unmarked');
        $this->assertSame(1, \count($marked->getAttributes(StreamHandler::class)));
        $this->assertSame(0, \count($unmarked->getAttributes(StreamHandler::class)));
    }
}
