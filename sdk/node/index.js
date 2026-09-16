'use strict';

// Portals Node.js worker SDK.
//
// Full parity with the reference Python SDK: Unix-socket transport with a
// framed stdio fallback, a dependency-free MessagePack codec including the
// Erlang value extensions, the exact-version HELLO/READY handshake,
// concurrent arbitrary module/function dispatch, structured error frames,
// reentrant callbacks, PID messaging, and bidirectional streaming with
// byte-credit windows, frame-count caps and per-direction half-close.
//
// See `protocol/v1.md` for the wire protocol.

const protocol = require('./lib/protocol');
const values = require('./lib/values');
const codec = require('./lib/msgpackCodec');
const errors = require('./lib/errors');
const transport = require('./lib/transport');
const streams = require('./lib/streams');
const worker = require('./lib/worker');

module.exports = {
  VERSION: '1.0.0',
  PROTOCOL_VERSION: protocol.PROTOCOL_VERSION,
  protocol,
  codec,
  errors,
  transport,
  ...values,
  ...streams,
  ...worker,
};
