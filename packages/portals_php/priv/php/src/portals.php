<?php

declare(strict_types=1);

/*
 * Portals PHP worker SDK.
 *
 * Full parity with the reference Python SDK: Unix-socket transport with a
 * framed stdio fallback, dependency-free ETF and MessagePack codecs
 * (selected by `PORTALS_CODEC`) including the Erlang value extensions, the
 * exact-version HELLO/READY handshake, concurrent arbitrary module/function
 * dispatch on Fibers, structured error frames, reentrant callbacks, PID
 * messaging, cooperative cancellation, and bidirectional streaming with
 * byte-credit windows, frame-count caps and per-direction half-close.
 *
 * `Portals.PHP.worker_opts/1` loads this file with `auto_prepend_file`;
 * without it, use:
 *
 *     require_once getenv('PORTALS_SDK_PATH') . '/portals.php';
 *
 * See `protocol/v1.md` for the wire protocol.
 */

namespace Portals;

require_once __DIR__ . '/Protocol.php';
require_once __DIR__ . '/Values.php';
require_once __DIR__ . '/MsgpackCodec.php';
require_once __DIR__ . '/EtfCodec.php';
require_once __DIR__ . '/Codec.php';
require_once __DIR__ . '/Errors.php';
require_once __DIR__ . '/Loop.php';
require_once __DIR__ . '/Transport.php';
require_once __DIR__ . '/Stream.php';
require_once __DIR__ . '/Worker.php';
require_once __DIR__ . '/functions.php';

const VERSION = '0.1.0';
const PROTOCOL_VERSION = Protocol::PROTOCOL_VERSION;

// Read once, at startup: an unknown codec fails here, before connecting.
Codec::select(getenv('PORTALS_CODEC'));
