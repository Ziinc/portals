'use strict';

// Frame tag registry and default limits for the Portals v1 protocol.
//
// Mirrors `lib/portals/protocol.ex` and `sdk/python/portals/protocol.py`.
// See `protocol/v1.md` for the authoritative specification.

const PROTOCOL_VERSION = 1;

const HELLO = 1;
const READY = 2;
const CALL = 3;
const RETURN = 4;
const ERROR = 5;
const CANCEL = 6;
const CALLBACK = 7;
const CALLBACK_RETURN = 8;
const CALLBACK_ERROR = 9;
const MESSAGE = 10;
const STREAM_DATA = 11;
const CREDIT = 12;
const HALF_CLOSE = 13;
const PING = 14;
const PONG = 15;
const SHUTDOWN = 16;

const FRAME_NAMES = {
  [HELLO]: 'hello',
  [READY]: 'ready',
  [CALL]: 'call',
  [RETURN]: 'return',
  [ERROR]: 'error',
  [CANCEL]: 'cancel',
  [CALLBACK]: 'callback',
  [CALLBACK_RETURN]: 'callback_return',
  [CALLBACK_ERROR]: 'callback_error',
  [MESSAGE]: 'message',
  [STREAM_DATA]: 'stream_data',
  [CREDIT]: 'credit',
  [HALF_CLOSE]: 'half_close',
  [PING]: 'ping',
  [PONG]: 'pong',
  [SHUTDOWN]: 'shutdown',
};

const DEFAULT_LIMITS = Object.freeze({
  max_frame_size: 16 * 1024 * 1024,
  max_nesting_depth: 32,
  max_collection_length: 65536,
  max_metadata_size: 65536,
  max_callback_depth: 16,
  max_in_flight_callbacks: 256,
  max_in_flight_requests: 4096,
  max_stream_byte_credit: 4 * 1024 * 1024,
  max_queued_stream_frames: 1024,
});

module.exports = {
  PROTOCOL_VERSION,
  HELLO,
  READY,
  CALL,
  RETURN,
  ERROR,
  CANCEL,
  CALLBACK,
  CALLBACK_RETURN,
  CALLBACK_ERROR,
  MESSAGE,
  STREAM_DATA,
  CREDIT,
  HALF_CLOSE,
  PING,
  PONG,
  SHUTDOWN,
  FRAME_NAMES,
  DEFAULT_LIMITS,
};
