<?php

declare(strict_types=1);

// Same worker as `run_worker.php`, over the framed stdio fallback transport.

require __DIR__ . '/../../src/portals.php';
require __DIR__ . '/bench_worker.php';
require __DIR__ . '/conformance_worker.php';

(new Portals\Worker(
    maxConcurrency: 16,
    maxStreams: 8,
    transport: 'stdio',
    modules: [
        'bench_worker' => BenchWorker::class,
        'conformance_worker' => ConformanceWorker::class,
    ],
    modulePaths: [__DIR__],
))->run();
