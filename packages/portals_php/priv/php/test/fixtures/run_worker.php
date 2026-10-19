<?php

declare(strict_types=1);

// Entry point launched by Portals as the direct worker process (the socket
// path is appended as the final CLI argument by `Portals.Connection`).
// The SDK is already loaded: `Portals.PHP.worker_opts/1` prepends it with
// `auto_prepend_file`, exactly as for an application's worker. Registers the
// fixture modules under the names the BEAM uses in `CALL`, then runs the
// worker loop.

require __DIR__ . '/bench_worker.php';
require __DIR__ . '/conformance_worker.php';

$env = static fn (string $name, string $default): string => getenv($name) !== false ? getenv($name) : $default;

(new Portals\Worker(
    maxConcurrency: (int) $env('PORTALS_MAX_CONCURRENCY', '64'),
    maxStreams: (int) $env('PORTALS_MAX_STREAMS', '8'),
    transport: $env('PORTALS_TRANSPORT', 'unix'),
    modules: [
        'bench_worker' => BenchWorker::class,
        'conformance_worker' => ConformanceWorker::class,
    ],
    modulePaths: [__DIR__],
    protocolVersion: (int) $env('PORTALS_PROTOCOL_VERSION', (string) Portals\PROTOCOL_VERSION),
))->run();
