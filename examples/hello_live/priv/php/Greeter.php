<?php

declare(strict_types=1);

final class Greeter
{
    public static function hello(string $name): string
    {
        return "Hello, {$name}! I'm PHP " . PHP_VERSION . '.';
    }
}
