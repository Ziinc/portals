<?php

declare(strict_types=1);

namespace Portals;

/**
 * Thrown when sending on a cancelled/terminated stream, or on a direction
 * this side already half-closed.
 */
class StreamClosed extends \RuntimeException
{
}

/** The peer exceeded its documented byte or frame allowance. */
class StreamProtocolError extends \RuntimeException
{
}

/** Marks a method as a streaming target (protocol/v1.md §9.1). */
#[\Attribute(\Attribute::TARGET_METHOD | \Attribute::TARGET_FUNCTION)]
final class StreamHandler
{
}

/**
 * Bidirectional streaming for the PHP worker SDK (protocol/v1.md §9).
 *
 * A stream is opened by the BEAM as an ordinary `CALL` whose target is
 * marked `#[Portals\StreamHandler]`; the call's `request_id` doubles as the
 * `stream_id`. The handler receives a `Stream` as its first argument and
 * runs against a dedicated stream-capacity budget, kept separate from the
 * unary call budget so long-lived streams can never exhaust the concurrency
 * this worker advertised for unary calls.
 *
 * Backpressure is an encoded-byte credit window, independent per direction,
 * charged against the complete encoded frame size (4-byte length prefix
 * included), plus a hard cap on queued-but-unconsumed frames so a flood of
 * tiny frames cannot evade the byte window. `recv()` and `send()` suspend
 * only the calling handler's fiber, never the socket reader.
 */
final class Stream implements \IteratorAggregate
{
    private int $sendCredit = 0;
    private int $sendFrames = 0;
    private int $recvCredit = 0;
    private int $recvBytes = 0;
    /** @var \SplQueue<array{0: mixed, 1: int}> */
    private \SplQueue $inbox;
    private bool $outboundOpen = true;
    private bool $inboundOpen = true;
    private bool $cancelled = false;
    /** @var list<Deferred> */
    private array $waiters = [];
    private Loop $loop;

    /**
     * @param callable(string): void $sendFrame writes one encoded envelope
     * @param callable(array): string $encode encodes one envelope
     */
    public function __construct(
        public readonly int|BigInt $id,
        private readonly int $maxCredit,
        private readonly int $maxFrames,
        private $sendFrame,
        private $encode,
        ?Loop $loop = null
    ) {
        $this->inbox = new \SplQueue();
        $this->loop = $loop ?? Loop::get();
    }

    public function isCancelled(): bool
    {
        return $this->cancelled;
    }

    // -- receive side -------------------------------------------------------

    /**
     * Bytes to grant the BEAM up front; also the replenishment amount after
     * consumption. Returns 0 when nothing is owed.
     */
    public function initialGrant(): int
    {
        $bytes = $this->maxCredit - $this->recvCredit - $this->recvBytes;
        if ($bytes <= 0) {
            return 0;
        }
        $this->recvCredit += $bytes;
        return $bytes;
    }

    /**
     * Account for one inbound STREAM_DATA frame. Throws
     * `StreamProtocolError` when the peer exceeded its allowance.
     */
    public function recordInbound(mixed $chunk, int $frameSize): void
    {
        if (!$this->inboundOpen) {
            throw new StreamProtocolError('STREAM_DATA after HALF_CLOSE');
        }
        if ($this->inbox->count() >= $this->maxFrames) {
            throw new StreamProtocolError('queued stream frame limit exceeded');
        }
        if ($frameSize > $this->recvCredit) {
            throw new StreamProtocolError('stream byte credit exceeded');
        }

        $this->recvCredit -= $frameSize;
        $this->recvBytes += $frameSize;
        $this->inbox->enqueue([$chunk, $frameSize]);
        $this->notifyAll();
    }

    /**
     * Next inbound chunk, or `null` once the BEAM has half-closed its
     * sending direction (or the stream was cancelled). Consuming a chunk is
     * what replenishes the BEAM's credit.
     *
     * @param float|null $timeout seconds
     */
    public function recv(?float $timeout = null): mixed
    {
        while (true) {
            if (!$this->inbox->isEmpty()) {
                [$chunk, $frameSize] = $this->inbox->dequeue();
                $this->recvBytes -= $frameSize;
                $grant = $this->initialGrant();
                if ($grant > 0) {
                    ($this->sendFrame)(($this->encode)([Protocol::CREDIT, $this->id, $grant, 1]));
                }
                return $chunk;
            }
            if ($this->cancelled || !$this->inboundOpen) {
                return null;
            }
            $this->wait($timeout, "stream {$this->id} receive timed out");
        }
    }

    /** Iterate inbound chunks until the BEAM half-closes. */
    public function getIterator(): \Generator
    {
        while (($chunk = $this->recv()) !== null) {
            yield $chunk;
        }
    }

    // -- send side ----------------------------------------------------------

    /**
     * Send one chunk, suspending only this handler (never the socket
     * reader) until the BEAM has granted enough credit.
     *
     * @param float|null $timeout seconds
     */
    public function send(mixed $chunk, ?float $timeout = null): void
    {
        $payload = ($this->encode)([Protocol::STREAM_DATA, $this->id, $chunk]);
        $frameSize = \strlen($payload) + Protocol::FRAME_PREFIX_BYTES;

        if ($frameSize > $this->maxCredit) {
            throw new StreamProtocolError(
                "chunk of {$frameSize} bytes exceeds the stream window of {$this->maxCredit}"
            );
        }

        while (true) {
            if ($this->cancelled) {
                throw new StreamClosed("stream {$this->id} was cancelled");
            }
            if (!$this->outboundOpen) {
                throw new StreamClosed("stream {$this->id} outbound direction is half-closed");
            }
            if ($this->sendFrames < $this->maxFrames && $frameSize <= $this->sendCredit) {
                $this->sendCredit -= $frameSize;
                $this->sendFrames += 1;
                break;
            }
            $this->wait($timeout, "stream {$this->id} send timed out waiting for credit");
        }

        ($this->sendFrame)($payload);
    }

    /** Send every chunk, then (by default) half-close. */
    public function sendAll(iterable $chunks, ?float $timeout = null, bool $halfClose = true): void
    {
        foreach ($chunks as $chunk) {
            $this->send($chunk, $timeout);
        }
        if ($halfClose) {
            $this->halfClose();
        }
    }

    /** Close only this side's sending direction. Idempotent. */
    public function halfClose(): void
    {
        if (!$this->outboundOpen || $this->cancelled) {
            return;
        }
        $this->outboundOpen = false;
        $this->notifyAll();
        ($this->sendFrame)(($this->encode)([Protocol::HALF_CLOSE, $this->id]));
    }

    // -- peer events --------------------------------------------------------

    public function addSendCredit(int $bytes, int $frames): void
    {
        $this->sendCredit = min($this->sendCredit + $bytes, $this->maxCredit);
        $this->sendFrames = max($this->sendFrames - $frames, 0);
        $this->notifyAll();
    }

    public function peerHalfClosed(): void
    {
        $this->inboundOpen = false;
        $this->notifyAll();
    }

    /** Release every piece of local state and unblock the handler. */
    public function cancel(): void
    {
        $this->cancelled = true;
        $this->outboundOpen = false;
        $this->inboundOpen = false;
        $this->inbox = new \SplQueue();
        $this->notifyAll();
    }

    // -- internals ----------------------------------------------------------

    private function wait(?float $timeout, string $message): void
    {
        $waiter = new Deferred($this->loop);
        $this->waiters[] = $waiter;
        try {
            $waiter->await($timeout, $message);
        } finally {
            $this->waiters = array_values(array_filter($this->waiters, static fn ($w) => $w !== $waiter));
        }
    }

    private function notifyAll(): void
    {
        $waiters = $this->waiters;
        $this->waiters = [];
        foreach ($waiters as $waiter) {
            $waiter->resolve();
        }
    }
}
