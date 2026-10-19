<?php

declare(strict_types=1);

namespace Portals\Tests;

final class AssertionFailed extends \RuntimeException
{
}

/** The handful of assertions the SDK's own tests need. */
abstract class TestCase
{
    public function setUp(): void
    {
    }

    protected function assertTrue(mixed $value, string $message = 'expected true'): void
    {
        if ($value !== true) {
            throw new AssertionFailed($message);
        }
    }

    protected function assertFalse(mixed $value, string $message = 'expected false'): void
    {
        $this->assertTrue($value === false, $message);
    }

    protected function assertSame(mixed $expected, mixed $actual, string $message = ''): void
    {
        if ($expected !== $actual) {
            throw new AssertionFailed(trim($message . ' expected ' . self::show($expected) . ', got ' . self::show($actual)));
        }
    }

    /** Structural equality (`==` compares objects property by property). */
    protected function assertEquals(mixed $expected, mixed $actual, string $message = ''): void
    {
        if ($expected != $actual) {
            throw new AssertionFailed(trim($message . ' expected ' . self::show($expected) . ', got ' . self::show($actual)));
        }
    }

    protected function assertNull(mixed $value): void
    {
        $this->assertSame(null, $value);
    }

    protected function assertInstanceOf(string $class, mixed $value): void
    {
        if (!$value instanceof $class) {
            throw new AssertionFailed("expected an instance of {$class}, got " . get_debug_type($value));
        }
    }

    /** @return \Throwable the caught exception */
    protected function assertThrows(string $class, callable $callback): \Throwable
    {
        try {
            $callback();
        } catch (\Throwable $e) {
            if ($e instanceof $class) {
                return $e;
            }
            throw new AssertionFailed("expected {$class}, got " . $e::class . ': ' . $e->getMessage());
        }
        throw new AssertionFailed("expected {$class} to be thrown");
    }

    private static function show(mixed $value): string
    {
        $text = var_export($value, true);
        return \strlen($text) > 200 ? substr($text, 0, 200) . '...' : $text;
    }
}
