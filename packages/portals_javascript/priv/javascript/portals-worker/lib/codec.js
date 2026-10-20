'use strict';

// The wire codec this worker speaks, chosen by the BEAM through the
// PORTALS_CODEC environment variable: `etf` (the default) or `msgpack`
// (protocol/v1.md §5.4). Read once, when the SDK is loaded; any other value
// fails startup. Handlers never see it: values arrive and leave as the same
// JavaScript types under either codec.

const etfCodec = require('./etfCodec');
const msgpackCodec = require('./msgpackCodec');

const CODECS = { etf: etfCodec, msgpack: msgpackCodec };

const NAME = process.env.PORTALS_CODEC ?? 'etf';

if (!Object.prototype.hasOwnProperty.call(CODECS, NAME)) {
  throw new Error(`PORTALS_CODEC=${JSON.stringify(NAME)} is not a codec this SDK speaks (etf, msgpack)`);
}

const { encode, decode, DecodeError } = CODECS[NAME];

module.exports = { NAME, encode, decode, DecodeError };
