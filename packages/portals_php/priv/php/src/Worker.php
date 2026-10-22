<?php

declare(strict_types=1);

namespace Portals;

/**
 * Per-call context: reentrancy depth, deadline, and a cooperative
 * cancellation flag, visible to the handler (through `Portals\...`
 * helpers) without threading an extra argument through user code.
 */
final class CallContext
{
    public bool $cancelled = false;

    public function __construct(public readonly int $depth, public readonly int|BigInt|null $deadlineMs)
    {
    }
}

/**
 * The PHP worker runtime: connects to the BEAM's Unix socket (or framed
 * stdio), completes the exact-version handshake, and dispatches `CALL`
 * frames to arbitrary module/function targets concurrently.
 *
 *     (new Portals\Worker(modules: ['my_handlers' => MyHandlers::class]))->run();
 *
 * Every CALL runs in its own `Fiber` on a single-threaded event loop. The
 * socket reader is the loop itself and never waits on handler execution: a
 * handler that waits — on a BEAM callback (`Portals\callback()`), stream
 * credit, or `Portals\sleep()` — suspends only its own fiber, so further
 * frames keep being read and other in-flight calls keep completing.
 * Concurrency is bounded by the `max_concurrency` advertised in `HELLO`,
 * with streams held to a separate `max_streams` budget so long-lived
 * streams cannot consume unary capacity.
 *
 * As in any cooperative runtime (Node.js included), a handler that blocks
 * the whole process — a native `sleep()`, blocking I/O, a long CPU loop —
 * stalls every other call until it returns. Use `Portals\sleep()` instead
 * of `sleep()`/`usleep()`.
 */
final class Worker
{
    public const DEFAULT_MAX_CONCURRENCY = 16;
    public const DEFAULT_MAX_STREAMS = 8;

    private static ?self $active = null;

    public array $limits = Protocol::DEFAULT_LIMITS;

    /** @var array<string, object|string|array> */
    private array $modules = [];
    /** @var array<string, array{0: callable, 1: bool}> */
    private array $targets = [];
    /** @var array<string, object> */
    private array $instances = [];
    /** @var array<string, Stream> */
    private array $streams = [];
    /** @var array<string, CallContext> */
    private array $pendingUnary = [];
    private int $activeCalls = 0;
    /** @var \SplQueue<array> */
    private \SplQueue $callQueue;
    private int $callbackId = 0;
    /** @var array<int, Deferred> */
    private array $pendingCallbacks = [];
    /** @var \WeakMap<\Fiber, CallContext> */
    private \WeakMap $contexts;
    /** @var callable(string): void */
    private $log;
    private ?FramedConnection $conn = null;
    private Loop $loop;

    /**
     * @param array<string, object|string|array> $modules wire module name =>
     *   handler object, class name, or array of `function name => callable`
     * @param list<string> $modulePaths directories searched for `<module>.php`
     * @param callable(string): void|null $logger
     */
    public function __construct(
        private readonly int $maxConcurrency = self::DEFAULT_MAX_CONCURRENCY,
        private readonly int $maxStreams = self::DEFAULT_MAX_STREAMS,
        private readonly ?string $socketPath = null,
        private readonly string $transport = 'unix',
        array $modules = [],
        private readonly ?array $modulePaths = null,
        // Overridable strictly so the version-mismatch diagnostics can be
        // exercised end to end; real workers always send the SDK's version.
        private readonly int $protocolVersion = Protocol::PROTOCOL_VERSION,
        ?callable $logger = null,
        ?Loop $loop = null
    ) {
        if (PHP_INT_SIZE < 8) {
            throw new \RuntimeException('the Portals PHP SDK requires a 64-bit PHP build');
        }
        foreach ($modules as $name => $module) {
            $this->register((string) $name, $module);
        }
        $this->callQueue = new \SplQueue();
        $this->contexts = new \WeakMap();
        $this->log = $logger ?? self::defaultLogger();
        $this->loop = $loop ?? Loop::get();
    }

    /**
     * Logging goes to a file or a callable, never over the RPC protocol.
     * `PORTALS_LOG_FILE` picks a file; otherwise stderr, which the BEAM
     * captures out of band.
     */
    public static function defaultLogger(): callable
    {
        $path = getenv('PORTALS_LOG_FILE');
        $sink = $path ? fopen($path, 'ab') : STDERR;
        return static function (string $message) use ($sink): void {
            @fwrite($sink, $message . "\n");
        };
    }

    public static function active(): ?self
    {
        return self::$active;
    }

    /** Register a module under the name the BEAM will use in `CALL`. */
    public function register(string $name, object|string|array $module): self
    {
        $this->modules[$name] = $module;
        unset($this->instances[$name]);
        $this->targets = array_filter(
            $this->targets,
            static fn (string $key) => !str_starts_with($key, $name . "\0"),
            ARRAY_FILTER_USE_KEY
        );
        return $this;
    }

    public function run(): void
    {
        $this->conn = $this->transport === 'stdio'
            ? FramedConnection::stdio($this->loop)
            : FramedConnection::connectUnix($this->socketPath ?? socket_path_from_argv(), $this->loop);

        $this->handshake();
        self::$active = $this;

        try {
            $this->conn->start(
                fn (string $payload) => $this->handleFrame($payload),
                function (?\Throwable $error): void {
                    if ($error !== null) {
                        ($this->log)('portals worker: ' . $error->getMessage());
                    }
                }
            );
            $conn = $this->conn;
            $this->loop->runUntil(static fn () => $conn->isClosed());
        } finally {
            if (self::$active === $this) {
                self::$active = null;
            }
            $this->cancelAllStreams();
            $this->conn->close();
        }
    }

    // -- Handshake ----------------------------------------------------------

    private function handshake(): void
    {
        $hello = [Protocol::HELLO, $this->protocolVersion, 'php' . PHP_VERSION, $this->maxConcurrency, $this->maxStreams, []];
        $this->conn->sendFrame(Codec::encode($hello, $this->limits));

        $payload = $this->conn->recvFrameBlocking();
        if ($payload === null) {
            throw new ConnectionClosed('connection closed during handshake');
        }

        [$envelope, $rest] = Codec::decode($payload, $this->limits);
        if ($rest !== '') {
            throw new ProtocolError('trailing bytes after READY');
        }

        [$tag, $version, $limits] = $envelope + [null, null, null];
        if ($tag !== Protocol::READY) {
            throw new ProtocolError("expected READY, got frame tag {$tag}");
        }
        if ($version !== Protocol::PROTOCOL_VERSION) {
            throw new ProtocolError(
                'protocol version mismatch: worker=' . Protocol::PROTOCOL_VERSION . " beam={$version}"
            );
        }
        if ($limits instanceof Map) {
            $this->limits = array_merge($this->limits, $limits->toArray());
        }
    }

    // -- Reentrant callbacks and messaging ----------------------------------

    public function callCallback(string $module, string $function, array $args = [], ?float $timeout = null): mixed
    {
        if (\Fiber::getCurrent() === null) {
            throw new \LogicException('Portals\\callback() must be called from within a CALL handler');
        }
        $depth = $this->currentCallbackDepth() + 1;
        $id = ++$this->callbackId;
        $deferred = new Deferred($this->loop);
        $this->pendingCallbacks[$id] = $deferred;
        $this->sendEnvelope([Protocol::CALLBACK, $id, $module, $function, $args, $depth]);

        try {
            return $deferred->await($timeout, "callback {$module}.{$function} timed out");
        } finally {
            unset($this->pendingCallbacks[$id]);
        }
    }

    public function sendMessage(Pid $target, mixed $value): void
    {
        $this->sendEnvelope([Protocol::MESSAGE, $target, $value]);
    }

    public function currentContext(): ?CallContext
    {
        $fiber = \Fiber::getCurrent();
        return $fiber === null ? null : ($this->contexts[$fiber] ?? null);
    }

    public function currentCallbackDepth(): int
    {
        return $this->currentContext()?->depth ?? 0;
    }

    private function resolveCallback(mixed $id, bool $ok, mixed $value): void
    {
        $deferred = \is_int($id) ? ($this->pendingCallbacks[$id] ?? null) : null;
        if ($deferred === null) {
            ($this->log)("portals worker: unknown callback_id {$this->display($id)} in response");
            return;
        }
        unset($this->pendingCallbacks[$id]);
        if ($ok) {
            $deferred->resolve($value);
        } else {
            $deferred->reject(new RemoteError($value instanceof Map ? $value : new Map()));
        }
    }

    // -- Frame dispatch -----------------------------------------------------

    private function handleFrame(string $payload): void
    {
        try {
            [$envelope, $rest] = Codec::decode($payload, $this->limits);
        } catch (DecodeError $e) {
            ($this->log)("portals worker: dropping malformed frame: {$e->getMessage()}");
            return;
        }
        if ($rest !== '') {
            ($this->log)('portals worker: dropping frame with trailing bytes');
            return;
        }

        $tag = $envelope[0] ?? null;
        $frameSize = \strlen($payload) + Protocol::FRAME_PREFIX_BYTES;

        switch ($tag) {
            case Protocol::CALL:
                $this->submitCall(\array_slice($envelope, 1));
                break;
            case Protocol::CANCEL:
                $this->cancelRequest($envelope[1] ?? null);
                break;
            case Protocol::STREAM_DATA:
                $this->handleStreamData($envelope[1] ?? null, $envelope[2] ?? null, $frameSize);
                break;
            case Protocol::CREDIT:
                $stream = $this->streams[$this->key($envelope[1] ?? null)] ?? null;
                if ($stream !== null && \is_int($envelope[2] ?? null)) {
                    $frames = \count($envelope) > 3 && \is_int($envelope[3]) ? $envelope[3] : 1;
                    $stream->addSendCredit($envelope[2], $frames);
                }
                break;
            case Protocol::HALF_CLOSE:
                $this->streams[$this->key($envelope[1] ?? null)]?->peerHalfClosed();
                break;
            case Protocol::CALLBACK_RETURN:
                $this->resolveCallback($envelope[1] ?? null, true, $envelope[2] ?? null);
                break;
            case Protocol::CALLBACK_ERROR:
                $this->resolveCallback($envelope[1] ?? null, false, $envelope[2] ?? null);
                break;
            case Protocol::PING:
                $this->sendEnvelope([Protocol::PONG, $envelope[1] ?? null]);
                break;
            case Protocol::PONG:
                break;
            case Protocol::SHUTDOWN:
                // Already-queued RETURN/ERROR frames still flush first.
                $this->conn->closeAfterFlush();
                break;
            default:
                ($this->log)("portals worker: ignoring unsupported frame tag {$this->display($tag)}");
        }
    }

    // -- Dispatch -----------------------------------------------------------

    /**
     * Route a CALL to the unary budget, or — when its target is marked
     * `#[StreamHandler]` — to the separate stream budget with a `Stream`
     * bound to the call's request_id.
     */
    private function submitCall(array $fields): void
    {
        [$requestId, $module, $function] = $fields + [null, null, null];

        try {
            [, $isStream] = $this->resolveTarget($module, $function);
        } catch (\Throwable) {
            // An unresolvable target is reported properly by the unary path.
            $isStream = false;
        }

        if (!$isStream) {
            $this->enqueueUnary($fields);
            return;
        }

        if ($this->maxStreams <= 0) {
            $this->sendEnvelope([Protocol::ERROR, $requestId, Errors::overloadErrorMap('worker advertises no streams')]);
            return;
        }
        if (\count($this->streams) >= $this->maxStreams) {
            $this->sendEnvelope([Protocol::ERROR, $requestId, Errors::overloadErrorMap('max_streams exceeded')]);
            return;
        }

        $stream = new Stream(
            $requestId,
            (int) $this->limits['max_stream_byte_credit'],
            (int) $this->limits['max_queued_stream_frames'],
            fn (string $bytes) => $this->conn->sendFrame($bytes),
            fn (array $envelope) => Codec::encode($envelope, $this->limits),
            $this->loop
        );
        $this->streams[$this->key($requestId)] = $stream;

        $grant = $stream->initialGrant();
        if ($grant > 0) {
            $this->sendEnvelope([Protocol::CREDIT, $requestId, $grant, 0]);
        }

        $this->loop->spawn(fn () => $this->runStream($stream, $fields));
    }

    private function runStream(Stream $stream, array $fields): void
    {
        [$requestId, $module, $function, $args, $deadlineMs, $depth] = $fields + [null, null, null, [], null, 0];
        $this->contexts[\Fiber::getCurrent()] = new CallContext(\is_int($depth) ? $depth : 0, $deadlineMs);
        $key = $this->key($requestId);

        try {
            [$target] = $this->resolveTarget($module, $function);
            $result = $target($stream, ...$this->argList($args));
            $stream->halfClose();
            unset($this->streams[$key]);
            if (!$stream->isCancelled()) {
                $this->sendEnvelope([Protocol::RETURN, $requestId, $result]);
            }
        } catch (\Throwable $e) {
            unset($this->streams[$key]);
            if (!$stream->isCancelled()) {
                $this->sendEnvelope([Protocol::ERROR, $requestId, Errors::buildErrorMap($e)]);
            }
        }
    }

    /**
     * Bounded unary execution: run now if the advertised concurrency allows,
     * otherwise queue. Either way the reader keeps going.
     */
    private function enqueueUnary(array $fields): void
    {
        if ($this->activeCalls < $this->maxConcurrency) {
            $this->activeCalls++;
            $this->loop->spawn(fn () => $this->runUnary($fields));
        } else {
            $this->callQueue->enqueue($fields);
        }
    }

    private function runUnary(array $fields): void
    {
        [$requestId, $module, $function, $args, $deadlineMs, $depth] = $fields + [null, null, null, [], null, 0];
        $context = new CallContext(\is_int($depth) ? $depth : 0, $deadlineMs);
        $this->contexts[\Fiber::getCurrent()] = $context;
        $key = $this->key($requestId);
        $this->pendingUnary[$key] = $context;

        try {
            [$target] = $this->resolveTarget($module, $function);
            $result = $target(...$this->argList($args));
            $this->sendEnvelope([Protocol::RETURN, $requestId, $result]);
        } catch (\Throwable $e) {
            $this->sendEnvelope([Protocol::ERROR, $requestId, Errors::buildErrorMap($e)]);
        } finally {
            unset($this->pendingUnary[$key]);
            if ($this->callQueue->isEmpty()) {
                $this->activeCalls--;
            } else {
                // Hand this slot straight to the next queued call.
                $next = $this->callQueue->dequeue();
                $this->loop->spawn(fn () => $this->runUnary($next));
            }
        }
    }

    private function argList(mixed $args): array
    {
        if ($args instanceof Map) {
            return array_values($args->toArray());
        }
        return \is_array($args) ? array_values($args) : [$args];
    }

    /**
     * Resolve a wire module/function to a callable and whether it is a
     * stream handler. Modules are looked up as: an explicitly registered
     * module; an existing class (`"my_handlers"` -> `MyHandlers`,
     * `"MyApp.Handlers"` -> `MyApp\Handlers`); or a `<module>.php` file in
     * one of the configured module paths that defines that class.
     * Functions match the method name exactly, or its camelCase form
     * (`"sleep_ms"` -> `sleepMs`).
     *
     * @return array{0: callable, 1: bool}
     */
    private function resolveTarget(mixed $module, mixed $function): array
    {
        if (!\is_string($module) || !\is_string($function)) {
            throw new \InvalidArgumentException('CALL module and function must be strings');
        }
        $cacheKey = $module . "\0" . $function;
        if (isset($this->targets[$cacheKey])) {
            return $this->targets[$cacheKey];
        }

        $handler = $this->resolveModule($module);
        $candidates = array_unique([$function, lcfirst(str_replace('_', '', ucwords($function, '_')))]);

        if (\is_array($handler)) {
            foreach ($candidates as $name) {
                if (isset($handler[$name]) && \is_callable($handler[$name])) {
                    $callable = $handler[$name];
                    $reflection = new \ReflectionFunction(\Closure::fromCallable($callable));
                    return $this->targets[$cacheKey] = [$callable, self::isStreamHandler($reflection)];
                }
            }
            throw new \BadFunctionCallException("no such function {$module}.{$function}");
        }

        foreach ($candidates as $name) {
            if (!method_exists($handler, $name)) {
                continue;
            }
            $method = new \ReflectionMethod($handler, $name);
            if (!$method->isPublic() || $method->isConstructor() || $method->isDestructor()) {
                continue;
            }
            if ($method->isStatic()) {
                $callable = [\is_object($handler) ? $handler::class : $handler, $name];
            } else {
                $instance = \is_object($handler)
                    ? $handler
                    : ($this->instances[$module] ??= new $handler());
                $callable = [$instance, $name];
            }
            return $this->targets[$cacheKey] = [$callable, self::isStreamHandler($method)];
        }
        throw new \BadFunctionCallException("no such function {$module}.{$function}");
    }

    private function resolveModule(string $name): object|string|array
    {
        if (isset($this->modules[$name])) {
            return $this->modules[$name];
        }

        $class = implode('\\', array_map(
            static fn (string $part) => str_replace('_', '', ucwords($part, '_')),
            explode('.', $name)
        ));
        if (class_exists($class)) {
            return $this->modules[$name] = $class;
        }

        if (preg_match('/^[A-Za-z0-9_.\-]+$/', $name) && !str_contains($name, '..')) {
            foreach ($this->modulePaths ?? [getcwd() ?: '.'] as $base) {
                $file = rtrim($base, '/') . '/' . $name . '.php';
                if (is_file($file)) {
                    require_once $file;
                    if (class_exists($class)) {
                        return $this->modules[$name] = $class;
                    }
                }
            }
        }
        throw new \BadFunctionCallException("no such module {$name}");
    }

    private static function isStreamHandler(\ReflectionFunctionAbstract $reflection): bool
    {
        return $reflection->getAttributes(StreamHandler::class) !== [];
    }

    // -- Cancellation and streaming -----------------------------------------

    /**
     * `CANCEL` shares the `request_id` space with streams: it cancels the
     * stream outright, or raises the cooperative cancellation flag for an
     * in-flight unary call.
     */
    private function cancelRequest(mixed $requestId): void
    {
        $key = $this->key($requestId);
        if (isset($this->streams[$key])) {
            $this->streams[$key]->cancel();
            unset($this->streams[$key]);
            return;
        }
        if (isset($this->pendingUnary[$key])) {
            $this->pendingUnary[$key]->cancelled = true;
        }
    }

    private function handleStreamData(mixed $streamId, mixed $chunk, int $frameSize): void
    {
        $key = $this->key($streamId);
        $stream = $this->streams[$key] ?? null;
        if ($stream === null) {
            return;
        }

        try {
            $stream->recordInbound($chunk, $frameSize);
        } catch (StreamProtocolError $e) {
            // A peer that exceeds its allowance loses only that stream.
            $stream->cancel();
            unset($this->streams[$key]);
            $this->sendEnvelope([Protocol::ERROR, $streamId, Errors::protocolErrorMap($e->getMessage())]);
        }
    }

    private function cancelAllStreams(): void
    {
        foreach ($this->streams as $stream) {
            $stream->cancel();
        }
        $this->streams = [];
    }

    private function sendEnvelope(array $envelope): void
    {
        try {
            $this->conn?->sendFrame(Codec::encode($envelope, $this->limits));
        } catch (\Throwable $e) {
            ($this->log)("portals worker: send failed: {$e->getMessage()}");
            // A result that cannot be encoded must still terminate its call.
            $tag = $envelope[0] ?? null;
            if ($tag === Protocol::RETURN || $tag === Protocol::ERROR) {
                $fallback = [
                    Protocol::ERROR,
                    $envelope[1],
                    Errors::buildErrorMap(new \RuntimeException('result could not be encoded: ' . $e->getMessage())),
                ];
                try {
                    $this->conn?->sendFrame(Codec::encode($fallback, $this->limits));
                } catch (\Throwable) {
                    // Nothing more can be done for this call.
                }
            }
        }
    }

    /** Array key for a request/stream id (ids above PHP_INT_MAX are BigInts). */
    private function key(mixed $id): string
    {
        return \is_int($id) || $id instanceof BigInt ? (string) $id : '?' . get_debug_type($id);
    }

    private function display(mixed $value): string
    {
        return \is_scalar($value) || $value instanceof \Stringable ? (string) $value : get_debug_type($value);
    }
}
