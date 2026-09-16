'use strict';

// Pure-JavaScript MessagePack codec implementing the exact subset used by
// the Portals v1 wire protocol, including the Erlang-value extensions
// (protocol/v1.md §5). Deliberately dependency-free — like the Python SDK's
// `msgpack_codec.py` — so a bare trusted-worker environment needs no npm
// install, and so the ext-type semantics stay byte-for-byte identical to
// `lib/portals/codec/message_pack.ex`.

const { DEFAULT_LIMITS } = require('./protocol');
const { Atom, Pid, Ref, Tuple, ImproperList, Float } = require('./values');

const EXT_TUPLE = 0;
const EXT_ATOM = 1;
const EXT_PID = 2;
const EXT_REFERENCE = 3;
const EXT_BIGINT = 4;
const EXT_IMPROPER_LIST = 5;

const UINT64_LIMIT = 18446744073709551616n;
const INT_LOWER_BOUND = -1099511627776n;

const EXT_FIXED_BY_SIZE = { 1: 0xd4, 2: 0xd5, 4: 0xd6, 8: 0xd7, 16: 0xd8 };
const EXT_SIZE_BY_TAG = { 0xd4: 1, 0xd5: 2, 0xd6: 4, 0xd7: 8, 0xd8: 16 };
const KNOWN_HEADERS = new Set([
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8,
  0xd9, 0xda, 0xdb, 0xdc, 0xdd, 0xde, 0xdf,
]);

// Raised for every codec-level failure, on encode and decode alike: never a
// generic exception, and never anything that escapes past the offending
// connection.
class DecodeError extends Error {
  constructor(reason, detail) {
    super(`${reason}: ${String(detail)}`);
    this.name = 'DecodeError';
    this.reason = reason;
    this.detail = detail;
  }
}

function checkDepth(depth, limits) {
  if (depth > limits.max_nesting_depth) throw new DecodeError('max_depth_exceeded', depth);
}

function checkLength(count, limits) {
  if (count > limits.max_collection_length) throw new DecodeError('max_length_exceeded', count);
}

// -- Encoding ---------------------------------------------------------------

function encode(envelope, limits = DEFAULT_LIMITS) {
  const body = encodeTerm(envelope, 0, limits);
  if (body.length > limits.max_frame_size) throw new DecodeError('max_size_exceeded', body.length);
  return body;
}

function encodeTerm(term, depth, limits) {
  checkDepth(depth, limits);

  if (term === null || term === undefined) return Buffer.from([0xc0]);
  if (term === false) return Buffer.from([0xc2]);
  if (term === true) return Buffer.from([0xc3]);
  if (typeof term === 'bigint') return encodeInt(term);
  if (typeof term === 'number') {
    return Number.isInteger(term) ? encodeInt(BigInt(term)) : encodeFloat(term);
  }
  if (typeof term === 'string') return encodeStr(Buffer.from(term, 'utf8'));
  if (Buffer.isBuffer(term)) return encodeBin(term);
  if (term instanceof Uint8Array) return encodeBin(Buffer.from(term));
  if (term instanceof Float) return encodeFloat(term.value);
  if (term instanceof Atom) return encodeExt(EXT_ATOM, Buffer.from(term.name, 'utf8'));
  if (term instanceof Pid) return encodeExt(EXT_PID, term.raw);
  if (term instanceof Ref) return encodeExt(EXT_REFERENCE, term.raw);
  if (term instanceof Tuple) {
    checkLength(term.items.length, limits);
    return encodeExt(EXT_TUPLE, encodeArray(term.items, depth + 1, limits));
  }
  if (term instanceof ImproperList) {
    return encodeExt(EXT_IMPROPER_LIST, encodeArray([term.items, term.tail], depth + 1, limits));
  }
  if (Array.isArray(term)) {
    checkLength(term.length, limits);
    return encodeArray(term, depth + 1, limits);
  }
  if (term instanceof Map) {
    checkLength(term.size, limits);
    return encodeMap([...term.entries()], depth, limits);
  }
  if (typeof term === 'object') {
    const entries = Object.entries(term);
    checkLength(entries.length, limits);
    return encodeMap(entries, depth, limits);
  }

  throw new DecodeError('invalid_encoding', `unsupported type ${typeof term}`);
}

function encodeFloat(value) {
  const out = Buffer.allocUnsafe(9);
  out[0] = 0xcb;
  out.writeDoubleBE(value, 1);
  return out;
}

function encodeStr(bytes) {
  const n = bytes.length;
  if (n < 32) return Buffer.concat([Buffer.from([0xa0 | n]), bytes]);
  if (n < 256) return Buffer.concat([Buffer.from([0xd9, n]), bytes]);
  if (n < 65536) {
    const header = Buffer.allocUnsafe(3);
    header[0] = 0xda;
    header.writeUInt16BE(n, 1);
    return Buffer.concat([header, bytes]);
  }
  const header = Buffer.allocUnsafe(5);
  header[0] = 0xdb;
  header.writeUInt32BE(n, 1);
  return Buffer.concat([header, bytes]);
}

function encodeBin(bytes) {
  const n = bytes.length;
  if (n < 256) return Buffer.concat([Buffer.from([0xc4, n]), bytes]);
  if (n < 65536) {
    const header = Buffer.allocUnsafe(3);
    header[0] = 0xc5;
    header.writeUInt16BE(n, 1);
    return Buffer.concat([header, bytes]);
  }
  const header = Buffer.allocUnsafe(5);
  header[0] = 0xc6;
  header.writeUInt32BE(n, 1);
  return Buffer.concat([header, bytes]);
}

function arrayHeader(n) {
  if (n < 16) return Buffer.from([0x90 | n]);
  if (n < 65536) {
    const header = Buffer.allocUnsafe(3);
    header[0] = 0xdc;
    header.writeUInt16BE(n, 1);
    return header;
  }
  const header = Buffer.allocUnsafe(5);
  header[0] = 0xdd;
  header.writeUInt32BE(n, 1);
  return header;
}

function mapHeader(n) {
  if (n < 16) return Buffer.from([0x80 | n]);
  if (n < 65536) {
    const header = Buffer.allocUnsafe(3);
    header[0] = 0xde;
    header.writeUInt16BE(n, 1);
    return header;
  }
  const header = Buffer.allocUnsafe(5);
  header[0] = 0xdf;
  header.writeUInt32BE(n, 1);
  return header;
}

function encodeArray(items, depth, limits) {
  const parts = [arrayHeader(items.length)];
  for (const item of items) parts.push(encodeTerm(item, depth, limits));
  return Buffer.concat(parts);
}

function encodeMap(entries, depth, limits) {
  const parts = [mapHeader(entries.length)];
  for (const [key, value] of entries) {
    parts.push(encodeStr(Buffer.from(String(key), 'utf8')));
    parts.push(encodeTerm(value, depth + 1, limits));
  }
  return Buffer.concat(parts);
}

function encodeInt(n) {
  if (n < INT_LOWER_BOUND || n >= UINT64_LIMIT) return encodeExt(EXT_BIGINT, encodeBigint(n));

  if (n >= 0n && n < 128n) return Buffer.from([Number(n)]);
  if (n >= -32n && n < 0n) return Buffer.from([0xe0 | Number(n + 32n)]);
  if (n >= 0n && n < 256n) return Buffer.from([0xcc, Number(n)]);
  if (n >= 0n && n < 65536n) {
    const out = Buffer.allocUnsafe(3);
    out[0] = 0xcd;
    out.writeUInt16BE(Number(n), 1);
    return out;
  }
  if (n >= 0n && n < 4294967296n) {
    const out = Buffer.allocUnsafe(5);
    out[0] = 0xce;
    out.writeUInt32BE(Number(n), 1);
    return out;
  }
  if (n >= 0n) {
    const out = Buffer.allocUnsafe(9);
    out[0] = 0xcf;
    out.writeBigUInt64BE(n, 1);
    return out;
  }
  if (n >= -128n) {
    const out = Buffer.allocUnsafe(2);
    out[0] = 0xd0;
    out.writeInt8(Number(n), 1);
    return out;
  }
  if (n >= -32768n) {
    const out = Buffer.allocUnsafe(3);
    out[0] = 0xd1;
    out.writeInt16BE(Number(n), 1);
    return out;
  }
  if (n >= -2147483648n) {
    const out = Buffer.allocUnsafe(5);
    out[0] = 0xd2;
    out.writeInt32BE(Number(n), 1);
    return out;
  }
  const out = Buffer.allocUnsafe(9);
  out[0] = 0xd3;
  out.writeBigInt64BE(n, 1);
  return out;
}

function encodeBigint(n) {
  const sign = n < 0n ? 1 : 0;
  let magnitude = n < 0n ? -n : n;
  const digits = [];
  while (magnitude > 0n) {
    digits.unshift(Number(magnitude & 0xffn));
    magnitude >>= 8n;
  }
  if (digits.length === 0) digits.push(0);
  return Buffer.from([sign, ...digits]);
}

function encodeExt(typeCode, payload) {
  const n = payload.length;
  const code = typeCode & 0xff;
  const fixed = EXT_FIXED_BY_SIZE[n];
  if (fixed !== undefined) return Buffer.concat([Buffer.from([fixed, code]), payload]);
  if (n < 256) return Buffer.concat([Buffer.from([0xc7, n, code]), payload]);
  if (n < 65536) {
    const header = Buffer.allocUnsafe(4);
    header[0] = 0xc8;
    header.writeUInt16BE(n, 1);
    header[3] = code;
    return Buffer.concat([header, payload]);
  }
  const header = Buffer.allocUnsafe(6);
  header[0] = 0xc9;
  header.writeUInt32BE(n, 1);
  header[5] = code;
  return Buffer.concat([header, payload]);
}

// -- Decoding ---------------------------------------------------------------

// Returns `[term, rest]`, where `rest` is a Buffer of any bytes left over.
function decode(data, limits = DEFAULT_LIMITS) {
  const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (buffer.length > limits.max_frame_size) throw new DecodeError('max_size_exceeded', buffer.length);

  const [term, pos] = decodeTerm(buffer, 0, 0, limits);
  return [Array.isArray(term) ? term : [term], buffer.subarray(pos)];
}

function need(data, pos, count) {
  if (data.length - pos < count) throw new DecodeError('truncated', Math.max(data.length - pos, 0));
}

// Integers stay Numbers while they are exactly representable and become
// BigInts beyond 2^53, so no precision is ever silently lost.
function safeNumber(value) {
  return value >= -9007199254740991n && value <= 9007199254740991n ? Number(value) : value;
}

function decodeTerm(data, pos, depth, limits) {
  checkDepth(depth, limits);
  need(data, pos, 1);
  const b0 = data[pos];

  switch (b0) {
    case 0xc0: return [null, pos + 1];
    case 0xc2: return [false, pos + 1];
    case 0xc3: return [true, pos + 1];
    case 0xcc: need(data, pos, 2); return [data[pos + 1], pos + 2];
    case 0xcd: need(data, pos, 3); return [data.readUInt16BE(pos + 1), pos + 3];
    case 0xce: need(data, pos, 5); return [data.readUInt32BE(pos + 1), pos + 5];
    case 0xcf: need(data, pos, 9); return [safeNumber(data.readBigUInt64BE(pos + 1)), pos + 9];
    case 0xd0: need(data, pos, 2); return [data.readInt8(pos + 1), pos + 2];
    case 0xd1: need(data, pos, 3); return [data.readInt16BE(pos + 1), pos + 3];
    case 0xd2: need(data, pos, 5); return [data.readInt32BE(pos + 1), pos + 5];
    case 0xd3: need(data, pos, 9); return [safeNumber(data.readBigInt64BE(pos + 1)), pos + 9];
    case 0xcb: need(data, pos, 9); return [data.readDoubleBE(pos + 1), pos + 9];
    case 0xc4: return decodeBin(data, pos, 1);
    case 0xc5: return decodeBin(data, pos, 2);
    case 0xc6: return decodeBin(data, pos, 4);
    case 0xd9: return decodeStr(data, pos, 1);
    case 0xda: return decodeStr(data, pos, 2);
    case 0xdb: return decodeStr(data, pos, 4);
    case 0xdc: need(data, pos, 3); return decodeArray(data.readUInt16BE(pos + 1), data, pos + 3, depth, limits);
    case 0xdd: need(data, pos, 5); return decodeArray(data.readUInt32BE(pos + 1), data, pos + 5, depth, limits);
    case 0xde: need(data, pos, 3); return decodeMap(data.readUInt16BE(pos + 1), data, pos + 3, depth, limits);
    case 0xdf: need(data, pos, 5); return decodeMap(data.readUInt32BE(pos + 1), data, pos + 5, depth, limits);
    case 0xc7: need(data, pos, 2); return decodeExtAt(data, pos, data[pos + 1], 2, depth, limits);
    case 0xc8: need(data, pos, 3); return decodeExtAt(data, pos, data.readUInt16BE(pos + 1), 3, depth, limits);
    case 0xc9: need(data, pos, 5); return decodeExtAt(data, pos, data.readUInt32BE(pos + 1), 5, depth, limits);
    default: break;
  }

  if (b0 < 0x80) return [b0, pos + 1];
  if (b0 >= 0xe0) return [b0 - 256, pos + 1];
  if (b0 >= 0xa0 && b0 <= 0xbf) return decodeStrFixed(data, pos + 1, b0 & 0x1f);
  if (b0 >= 0x90 && b0 <= 0x9f) return decodeArray(b0 & 0x0f, data, pos + 1, depth, limits);
  if (b0 >= 0x80 && b0 <= 0x8f) return decodeMap(b0 & 0x0f, data, pos + 1, depth, limits);

  const extSize = EXT_SIZE_BY_TAG[b0];
  if (extSize !== undefined) return decodeExtAt(data, pos, extSize, 1, depth, limits);

  if (KNOWN_HEADERS.has(b0)) throw new DecodeError('truncated', data.length - pos);
  throw new DecodeError('invalid_encoding', b0);
}

function readLength(data, pos, headerSize) {
  if (headerSize === 1) return data[pos];
  if (headerSize === 2) return data.readUInt16BE(pos);
  return data.readUInt32BE(pos);
}

function decodeBin(data, pos, headerSize) {
  need(data, pos, 1 + headerSize);
  const n = readLength(data, pos + 1, headerSize);
  const start = pos + 1 + headerSize;
  need(data, start, n);
  return [Buffer.from(data.subarray(start, start + n)), start + n];
}

function decodeStr(data, pos, headerSize) {
  need(data, pos, 1 + headerSize);
  const n = readLength(data, pos + 1, headerSize);
  return decodeStrFixed(data, pos + 1 + headerSize, n);
}

function decodeStrFixed(data, start, n) {
  need(data, start, n);
  return [data.toString('utf8', start, start + n), start + n];
}

function decodeArray(count, data, pos, depth, limits) {
  checkLength(count, limits);
  const items = new Array(count);
  let cursor = pos;
  for (let i = 0; i < count; i += 1) {
    const [item, next] = decodeTerm(data, cursor, depth + 1, limits);
    items[i] = item;
    cursor = next;
  }
  return [items, cursor];
}

function decodeMap(count, data, pos, depth, limits) {
  checkLength(count, limits);
  const result = {};
  let cursor = pos;
  for (let i = 0; i < count; i += 1) {
    const [key, afterKey] = decodeTerm(data, cursor, depth + 1, limits);
    const [value, afterValue] = decodeTerm(data, afterKey, depth + 1, limits);
    result[String(key)] = value;
    cursor = afterValue;
  }
  return [result, cursor];
}

function signed8(byte) {
  return byte >= 128 ? byte - 256 : byte;
}

function decodeExtAt(data, pos, payloadSize, headerSize, depth, limits) {
  const typePos = pos + headerSize;
  need(data, typePos, 1 + payloadSize);
  const typeCode = signed8(data[typePos]);
  const payload = data.subarray(typePos + 1, typePos + 1 + payloadSize);
  return [decodeExt(typeCode, payload, depth, limits), typePos + 1 + payloadSize];
}

function decodeExt(typeCode, payload, depth, limits) {
  switch (typeCode) {
    case EXT_BIGINT: {
      if (payload.length < 1) throw new DecodeError('invalid_extension', 'bigint');
      const sign = payload[0];
      let magnitude = 0n;
      for (let i = 1; i < payload.length; i += 1) magnitude = (magnitude << 8n) | BigInt(payload[i]);
      const value = sign === 1 ? -magnitude : magnitude;
      return safeNumber(value);
    }
    case EXT_ATOM: {
      // JavaScript has no BEAM atom table, so §5.3's unsafe-atom concern
      // does not apply; the text round-trips as an opaque Atom.
      const text = payload.toString('utf8');
      if (!Buffer.from(text, 'utf8').equals(payload)) {
        throw new DecodeError('invalid_extension', 'atom');
      }
      return new Atom(text);
    }
    case EXT_PID: return new Pid(payload);
    case EXT_REFERENCE: return new Ref(payload);
    case EXT_TUPLE: {
      const [items, pos] = decodeTerm(payload, 0, depth + 1, limits);
      if (!Array.isArray(items) || pos !== payload.length) {
        throw new DecodeError('invalid_extension', 'tuple');
      }
      return new Tuple(items);
    }
    case EXT_IMPROPER_LIST: {
      const [pair, pos] = decodeTerm(payload, 0, depth + 1, limits);
      if (!Array.isArray(pair) || pair.length !== 2 || pos !== payload.length) {
        throw new DecodeError('invalid_extension', 'improper_list');
      }
      return new ImproperList(pair[0], pair[1]);
    }
    default:
      throw new DecodeError('invalid_extension', typeCode);
  }
}

module.exports = {
  encode,
  decode,
  DecodeError,
  EXT_TUPLE,
  EXT_ATOM,
  EXT_PID,
  EXT_REFERENCE,
  EXT_BIGINT,
  EXT_IMPROPER_LIST,
};
