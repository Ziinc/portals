<?php

declare(strict_types=1);

use Portals\Bin;
use Portals\Codec;
use Portals\DecodeError;
use Portals\Protocol;

/**
 * Black-box conformance bridge (protocol/v1.md §10, FR-7).
 *
 * The BEAM-side conformance test drives this module as an ordinary worker:
 * `echo_term` proves every golden vector survives a full decode/encode
 * round trip through this SDK's codec, and `decode_reason` reports how this
 * SDK classifies each malformed fixture — without the test knowing
 * anything about PHP internals.
 */
final class ConformanceWorker
{
    /**
     * Decoded by the SDK on the way in, re-encoded on the way out. The BEAM
     * compares the result to the term it sent.
     */
    public static function echo_term(mixed $value): mixed
    {
        return $value;
    }

    /**
     * Classify raw bytes exactly as the frame reader would, with the codec
     * the BEAM selected for this worker. Returns the rejection reason name,
     * or "ok" when the bytes are accepted.
     */
    public static function decode_reason(Bin|string $bytes): string
    {
        try {
            [, $rest] = Codec::decode($bytes instanceof Bin ? $bytes->data : $bytes, Protocol::DEFAULT_LIMITS);
            return $rest === '' ? 'ok' : 'trailing_bytes';
        } catch (DecodeError $e) {
            return $e->reason;
        }
    }

    /**
     * The SDK's identity: protocol version and runtime string, so version
     * diagnostics can be compared across SDKs.
     */
    public static function version_info(): array
    {
        return [
            'protocol_version' => Portals\PROTOCOL_VERSION,
            'language' => 'php',
            'sdk_version' => Portals\VERSION,
        ];
    }
}
