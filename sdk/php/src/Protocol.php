<?php

declare(strict_types=1);

namespace Portals;

/**
 * Frame tag registry and default limits for the Portals v1 protocol.
 *
 * Mirrors `lib/portals/protocol.ex`, `sdk/ruby/lib/portals/protocol.rb` and
 * `sdk/node/lib/protocol.js`. See `protocol/v1.md` for the authoritative
 * specification.
 */
final class Protocol
{
    public const PROTOCOL_VERSION = 1;

    public const HELLO = 1;
    public const READY = 2;
    public const CALL = 3;
    public const RETURN = 4;
    public const ERROR = 5;
    public const CANCEL = 6;
    public const CALLBACK = 7;
    public const CALLBACK_RETURN = 8;
    public const CALLBACK_ERROR = 9;
    public const MESSAGE = 10;
    public const STREAM_DATA = 11;
    public const CREDIT = 12;
    public const HALF_CLOSE = 13;
    public const PING = 14;
    public const PONG = 15;
    public const SHUTDOWN = 16;

    public const FRAME_NAMES = [
        self::HELLO => 'hello',
        self::READY => 'ready',
        self::CALL => 'call',
        self::RETURN => 'return',
        self::ERROR => 'error',
        self::CANCEL => 'cancel',
        self::CALLBACK => 'callback',
        self::CALLBACK_RETURN => 'callback_return',
        self::CALLBACK_ERROR => 'callback_error',
        self::MESSAGE => 'message',
        self::STREAM_DATA => 'stream_data',
        self::CREDIT => 'credit',
        self::HALF_CLOSE => 'half_close',
        self::PING => 'ping',
        self::PONG => 'pong',
        self::SHUTDOWN => 'shutdown',
    ];

    public const DEFAULT_LIMITS = [
        'max_frame_size' => 16 * 1024 * 1024,
        'max_nesting_depth' => 32,
        'max_collection_length' => 65536,
        'max_metadata_size' => 65536,
        'max_callback_depth' => 16,
        'max_in_flight_callbacks' => 256,
        'max_in_flight_requests' => 4096,
        'max_stream_byte_credit' => 4 * 1024 * 1024,
        'max_queued_stream_frames' => 1024,
    ];

    /** Bytes of transport framing (the 4-byte big-endian length prefix). */
    public const FRAME_PREFIX_BYTES = 4;
}
