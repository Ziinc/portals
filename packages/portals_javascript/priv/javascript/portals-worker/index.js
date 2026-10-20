'use strict';

// Portals Node.js worker SDK.
//
// Full parity with the reference Python SDK: Unix-socket transport with a
// framed stdio fallback, dependency-free ETF (the default) and MessagePack
// codecs selected by PORTALS_CODEC, the exact-version HELLO/READY handshake,
// concurrent arbitrary module/function dispatch, structured error frames,
// reentrant callbacks, PID messaging, and bidirectional streaming with
// byte-credit windows, frame-count caps and per-direction half-close.
//
// See `protocol/v1.md` for the wire protocol.

const protocol = require('./lib/protocol');
const values = require('./lib/values');
const codec = require('./lib/codec');
const etfCodec = require('./lib/etfCodec');
const msgpackCodec = require('./lib/msgpackCodec');
const errors = require('./lib/errors');
const transport = require('./lib/transport');
const streams = require('./lib/streams');
const worker = require('./lib/worker');
const { runtime } = require('./lib/runtime');

module.exports = {
  VERSION: '0.1.0',
  PROTOCOL_VERSION: protocol.PROTOCOL_VERSION,
  protocol,
  // The codec this worker selected (PORTALS_CODEC), and each codec by name.
  codec,
  etfCodec,
  msgpackCodec,
  errors,
  transport,
  ...values,
  ...streams,
  ...worker,
  runtime,
};
