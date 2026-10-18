<?php

declare(strict_types=1);

/*
 * Dependency-free test runner: no Composer, no PHPUnit. Loads every
 * `test/*Test.php`, runs each public `test*` method of each `TestCase`
 * subclass on a fresh instance (and a fresh event loop), and exits non-zero
 * on any failure.
 *
 *     php test/run.php            # all tests
 *     php test/run.php Stream     # only test classes whose name contains "Stream"
 */

require __DIR__ . '/../src/portals.php';
require __DIR__ . '/TestCase.php';

foreach (glob(__DIR__ . '/*Test.php') as $file) {
    require_once $file;
}

$filter = $argv[1] ?? '';
$passed = 0;
$failures = [];

foreach (get_declared_classes() as $class) {
    if (!is_subclass_of($class, Portals\Tests\TestCase::class) || ($filter !== '' && !str_contains($class, $filter))) {
        continue;
    }
    foreach (get_class_methods($class) as $method) {
        if (!str_starts_with($method, 'test')) {
            continue;
        }
        Portals\Loop::reset();
        try {
            $case = new $class();
            $case->setUp();
            $case->$method();
            $passed++;
            echo '.';
        } catch (Throwable $e) {
            $failures[] = sprintf(
                "%s::%s\n  %s: %s\n  at %s:%d",
                $class,
                $method,
                $e::class,
                $e->getMessage(),
                $e->getFile(),
                $e->getLine()
            );
            echo 'F';
        }
    }
}

echo "\n\n";
foreach ($failures as $i => $failure) {
    echo ($i + 1) . ') ' . $failure . "\n\n";
}
printf("%d tests, %d failures\n", $passed + count($failures), count($failures));
exit($failures === [] ? 0 : 1);
