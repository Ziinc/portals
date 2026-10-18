<?php

declare(strict_types=1);

namespace Portals;

/** Raised by `Portals\callback()` when the BEAM-side handler fails. */
class RemoteError extends \RuntimeException
{
    public function __construct(public readonly Map|array $errorMap)
    {
        parent::__construct((string) ($errorMap['message'] ?? 'callback failed'));
    }
}

class ProtocolError extends \RuntimeException
{
}

class ConnectionClosed extends \RuntimeException
{
}

/**
 * Structured remote-error mapping (FR-4). Every uncaught throwable raised by
 * a called function becomes an `ERROR` frame carrying language, exception
 * class, message, and a normalized, bounded stack trace — never a raw
 * serialized object. The wire shape matches `%Portals.Error{}`:
 * `kind`/`message`/`details`/`remote`/`stacktrace`.
 */
final class Errors
{
    public const MAX_STACK_FRAMES = 64;
    public const MAX_MESSAGE_SIZE = 4096;

    public static function buildErrorMap(\Throwable $error): array
    {
        $message = $error->getMessage();
        if (\strlen($message) > self::MAX_MESSAGE_SIZE) {
            $message = mb_strcut($message, 0, self::MAX_MESSAGE_SIZE, 'UTF-8');
        }
        if (!mb_check_encoding($message, 'UTF-8')) {
            $message = mb_convert_encoding($message, 'UTF-8', 'UTF-8');
        }

        $frames = [$error->getFile() . ':' . $error->getLine()];
        foreach ($error->getTrace() as $frame) {
            $location = isset($frame['file']) ? $frame['file'] . ':' . ($frame['line'] ?? 0) : '[internal]';
            $function = isset($frame['class']) ? $frame['class'] . ($frame['type'] ?? '::') : '';
            $frames[] = "{$location} in {$function}{$frame['function']}";
        }

        return [
            'kind' => 'remote',
            'message' => $message === '' ? $error::class : $message,
            'details' => new Map(),
            'remote' => [
                'language' => 'php',
                'exception_type' => $error::class,
            ],
            'stacktrace' => \array_slice($frames, 0, self::MAX_STACK_FRAMES),
        ];
    }

    /**
     * A terminal `overload` error, used when the worker is at its advertised
     * stream or concurrency capacity.
     */
    public static function overloadErrorMap(string $message): array
    {
        return ['kind' => 'overload', 'message' => $message, 'details' => new Map(), 'remote' => ['language' => 'php']];
    }

    public static function protocolErrorMap(string $message): array
    {
        return ['kind' => 'protocol', 'message' => $message, 'details' => new Map(), 'remote' => ['language' => 'php']];
    }
}
