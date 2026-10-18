<?php

declare(strict_types=1);

namespace Portals;

/**
 * Length-framed transport for the PHP worker side.
 *
 * Matches the BEAM's `{:packet, 4}` framing exactly: a 4-byte big-endian
 * length prefix followed by that many bytes of MessagePack-encoded
 * envelope. Both directions are non-blocking and driven by the `Loop`:
 * inbound bytes are reassembled into whole frames and handed to the
 * `onFrame` callback as they complete, and outbound frames are buffered and
 * flushed whenever the stream is writable, so a slow peer never blocks a
 * handler and the reader is never coupled to how fast handlers run.
 */
final class FramedConnection
{
    private string $inbound = '';
    private string $outbound = '';
    private bool $closed = false;
    private bool $closeWhenFlushed = false;
    /** @var callable(string): void */
    private $onFrame;
    /** @var callable(?\Throwable): void */
    private $onClose;

    /**
     * @param resource $readStream
     * @param resource $writeStream
     */
    public function __construct(
        private $readStream,
        private $writeStream,
        private readonly bool $ownsStreams,
        private readonly Loop $loop
    ) {
        stream_set_blocking($this->readStream, false);
        stream_set_blocking($this->writeStream, false);
        stream_set_write_buffer($this->writeStream, 0);
        stream_set_read_buffer($this->readStream, 0);
    }

    public static function connectUnix(string $path, ?Loop $loop = null): self
    {
        $socket = @stream_socket_client('unix://' . $path, $errno, $errstr, 10.0);
        if ($socket === false) {
            throw new ConnectionClosed("portals worker: cannot connect to {$path}: {$errstr} ({$errno})");
        }
        return new self($socket, $socket, true, $loop ?? Loop::get());
    }

    public static function stdio(?Loop $loop = null): self
    {
        return new self(STDIN, STDOUT, false, $loop ?? Loop::get());
    }

    /**
     * Start delivering frames. `$onFrame` receives each complete envelope;
     * `$onClose` is called once when the peer goes away (with an error if it
     * closed mid-frame).
     */
    public function start(callable $onFrame, callable $onClose): void
    {
        $this->onFrame = $onFrame;
        $this->onClose = $onClose;
        $this->loop->onReadable($this->readStream, fn () => $this->onReadable());
        // Frames that arrived together with READY are already buffered.
        $this->loop->defer(fn () => $this->drainFrames());
    }

    public function isClosed(): bool
    {
        return $this->closed;
    }

    public function sendFrame(string $payload): void
    {
        if ($this->closed || $this->closeWhenFlushed) {
            return;
        }
        $this->outbound .= pack('N', \strlen($payload)) . $payload;
        $this->flush();
    }

    /** Synchronously read one whole frame (used only for the handshake). */
    public function recvFrameBlocking(float $timeout = 30.0): ?string
    {
        $deadline = Loop::now() + $timeout;
        while (true) {
            $this->flushBlocking($deadline);
            $frame = $this->takeFrame();
            if ($frame !== null) {
                return $frame;
            }
            $remaining = $deadline - Loop::now();
            if ($remaining <= 0) {
                throw new TimeoutError('portals worker: timed out waiting for a frame');
            }
            $read = [$this->readStream];
            $write = $except = null;
            if (@stream_select($read, $write, $except, (int) $remaining, (int) (fmod($remaining, 1.0) * 1e6)) === false) {
                continue;
            }
            if ($read !== [] && !$this->readAvailable()) {
                return null;
            }
        }
    }

    /** Flush pending output, then close (used for SHUTDOWN). */
    public function closeAfterFlush(): void
    {
        $this->closeWhenFlushed = true;
        if ($this->outbound === '') {
            $this->close();
        }
    }

    public function close(): void
    {
        if ($this->closed) {
            return;
        }
        $this->closed = true;
        $this->loop->onReadable($this->readStream, null);
        $this->loop->onWritable($this->writeStream, null);
        if ($this->ownsStreams) {
            @fclose($this->readStream);
        }
    }

    // -- internals ----------------------------------------------------------

    private function onReadable(): void
    {
        $open = $this->readAvailable();
        $this->drainFrames();
        if (!$open && !$this->closed) {
            $error = $this->inbound === '' ? null : new ConnectionClosed('connection closed mid-frame');
            $this->close();
            ($this->onClose)($error);
        }
    }

    private function drainFrames(): void
    {
        while (!$this->closed && ($frame = $this->takeFrame()) !== null) {
            ($this->onFrame)($frame);
        }
    }

    /** Read whatever is available. Returns false once the peer has closed. */
    private function readAvailable(): bool
    {
        $chunk = @fread($this->readStream, 1 << 16);
        if ($chunk === false || ($chunk === '' && feof($this->readStream))) {
            return false;
        }
        $this->inbound .= $chunk;
        return true;
    }

    private function takeFrame(): ?string
    {
        if (\strlen($this->inbound) < 4) {
            return null;
        }
        $length = unpack('N', $this->inbound)[1];
        if (\strlen($this->inbound) < 4 + $length) {
            return null;
        }
        $frame = (string) substr($this->inbound, 4, $length);
        $this->inbound = (string) substr($this->inbound, 4 + $length);
        return $frame;
    }

    private function flush(): void
    {
        while ($this->outbound !== '') {
            $written = @fwrite($this->writeStream, $this->outbound);
            if ($written === false) {
                // The peer is gone; the read side will notice and close.
                $this->outbound = '';
                break;
            }
            if ($written === 0) {
                break;
            }
            $this->outbound = (string) substr($this->outbound, $written);
        }

        if ($this->outbound === '') {
            $this->loop->onWritable($this->writeStream, null);
            if ($this->closeWhenFlushed) {
                $this->close();
            }
        } elseif (!$this->closed) {
            $this->loop->onWritable($this->writeStream, fn () => $this->flush());
        }
    }

    private function flushBlocking(float $deadline): void
    {
        while ($this->outbound !== '' && Loop::now() < $deadline) {
            $this->flush();
            if ($this->outbound !== '') {
                $read = $except = null;
                $write = [$this->writeStream];
                @stream_select($read, $write, $except, 0, 50_000);
            }
        }
    }
}

/** `Portals.Connection` appends the socket path as the final CLI argument. */
function socket_path_from_argv(?array $argv = null): string
{
    $args = \array_slice($argv ?? $_SERVER['argv'] ?? [], 1);
    if ($args === []) {
        throw new \InvalidArgumentException('portals worker: expected the socket path as the last argument');
    }
    return (string) end($args);
}
