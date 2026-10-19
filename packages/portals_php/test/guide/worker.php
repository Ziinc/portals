<?php

declare(strict_types=1);

// Portals starts this script and appends the socket path as the last
// argument. The SDK is already loaded (auto_prepend_file).
require __DIR__ . '/TextTools.php';

(new Portals\Worker(
    maxConcurrency: 8,
    maxStreams: 4,
    modules: ['text_tools' => TextTools::class],
))->run();
