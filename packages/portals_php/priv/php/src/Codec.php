<?php

declare(strict_types=1);

namespace Portals;

/**
 * The wire codec this worker speaks, chosen by the BEAM through the
 * `PORTALS_CODEC` environment variable: `etf` (the default, `EtfCodec`) or
 * `msgpack` (`MsgpackCodec`). It is read once when the SDK loads, and any
 * other value stops the worker before it connects (protocol/v1.md §5.4).
 * Every frame in both directions, `HELLO` included, goes through it;
 * handlers never see it, since values arrive and leave as the same PHP
 * types under either codec.
 */
final class Codec
{
    public const CODECS = ['etf' => EtfCodec::class, 'msgpack' => MsgpackCodec::class];

    private static string $name = 'etf';
    /** @var class-string<EtfCodec|MsgpackCodec> */
    private static string $class = EtfCodec::class;

    /** Select the codec named by `$name` (`getenv()` result; `false` when unset means `etf`). */
    public static function select(string|false $name): void
    {
        $name = $name === false ? 'etf' : $name;
        if (!isset(self::CODECS[$name])) {
            throw new \RuntimeException(
                'PORTALS_CODEC=' . var_export($name, true) . ' is not a codec this SDK speaks (etf, msgpack)'
            );
        }
        self::$name = $name;
        self::$class = self::CODECS[$name];
    }

    public static function name(): string
    {
        return self::$name;
    }

    public static function encode(mixed $envelope, array $limits = Protocol::DEFAULT_LIMITS): string
    {
        return self::$class::encode($envelope, $limits);
    }

    /** @return array{0: mixed, 1: string} `[term, rest]`, as each codec's `decode()` */
    public static function decode(string $data, array $limits = Protocol::DEFAULT_LIMITS): array
    {
        return self::$class::decode($data, $limits);
    }
}
