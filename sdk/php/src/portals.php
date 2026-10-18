<?php

declare(strict_types=1);

/*
 * Portals PHP worker SDK.
 *
 * Full parity with the reference Python SDK: Unix-socket transport with a
 * framed stdio fallback, a dependency-free MessagePack codec including the
 * Erlang value extensions, the exact-version HELLO/READY handshake,
 * concurrent arbitrary module/function dispatch on Fibers, structured error
 * frames, reentrant callbacks, PID messaging, cooperative cancellation, and
 * bidirectional streaming with byte-credit windows, frame-count caps and
 * per-direction half-close.
 *
 *     require 'path/to/sdk/php/src/portals.php';
 *
 * See `protocol/v1.md` for the wire protocol.
 */

namespace Portals;

require_once __DIR__ . '/Protocol.php';
require_once __DIR__ . '/Values.php';
require_once __DIR__ . '/MsgpackCodec.php';
require_once __DIR__ . '/Errors.php';
require_once __DIR__ . '/Loop.php';
require_once __DIR__ . '/Transport.php';
require_once __DIR__ . '/Stream.php';
require_once __DIR__ . '/Worker.php';
require_once __DIR__ . '/functions.php';

const VERSION = '0.1.0';
const PROTOCOL_VERSION = Protocol::PROTOCOL_VERSION;
