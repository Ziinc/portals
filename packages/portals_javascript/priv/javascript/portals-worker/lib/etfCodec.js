'use strict';

// Pure-JavaScript codec for the Erlang External Term Format, the default
// wire codec (protocol/v1.md §5.4) and the JavaScript side of
// `lib/portals/codec/etf.ex`. Dependency-free, like `msgpackCodec.js`, and
// mirroring the Python SDK's `etf_codec.py`.
//
// Terms decode to exactly the JavaScript values the MessagePack codec
// produces, so handlers never see which codec is in use:
//
// * binaries are strings (UTF-8), and `%Portals.Codec.Bin{}` structs are
//   Buffers (and Buffers encode as that struct);
// * the atoms `nil`, `true` and `false` are `null`, `true` and `false`, and
//   other atoms are `Atom`;
// * tuples are `Tuple`, improper lists are `ImproperList`, and maps are
//   plain objects with text keys (atom and integer keys become their text,
//   as the MessagePack encoders do);
// * PIDs and references are opaque `Pid` / `Ref` wrapping their ETF bytes,
//   which are written back verbatim.

const { DEFAULT_LIMITS } = require('./protocol');
const { Atom, Pid, Ref, Tuple, ImproperList, Float } = require('./values');
// One error type for both codecs, so `instanceof DecodeError` holds
// whichever codec the worker selected.
const { DecodeError } = require('./msgpackCodec');

const VERSION = 131;

const NEW_FLOAT = 70;
const BIT_BINARY = 77;
const NEW_PID = 88;
const NEWER_REFERENCE = 90;
const SMALL_INTEGER = 97;
const INTEGER = 98;
const ATOM = 100;
const PID = 103;
const SMALL_TUPLE = 104;
const LARGE_TUPLE = 105;
const NIL = 106;
const STRING = 107;
const LIST = 108;
const BINARY = 109;
const SMALL_BIG = 110;
const LARGE_BIG = 111;
const NEW_REFERENCE = 114;
const SMALL_ATOM = 115;
const MAP = 116;
const ATOM_UTF8 = 118;
const SMALL_ATOM_UTF8 = 119;

const BIN_STRUCT = 'Elixir.Portals.Codec.Bin';

function smallAtom(name) {
  const text = Buffer.from(name, 'utf8');
  return Buffer.concat([Buffer.from([SMALL_ATOM_UTF8, text.length]), text]);
}

const NIL_ATOM = smallAtom('nil');
const TRUE_ATOM = smallAtom('true');
const FALSE_ATOM = smallAtom('false');
// How Buffers are encoded: `%Portals.Codec.Bin{data: ...}`, up to the data
// binary itself.
const BIN_PREFIX = Buffer.concat([
  Buffer.from([MAP, 0, 0, 0, 2]),
  smallAtom('__struct__'),
  smallAtom(BIN_STRUCT),
  smallAtom('data'),
]);

function checkDepth(depth, limits) {
  if (depth > limits.max_nesting_depth) throw new DecodeError('max_depth_exceeded', depth);
}

function checkLength(count, limits) {
  if (count > limits.max_collection_length) throw new DecodeError('max_length_exceeded', count);
}

// -- Encoding ---------------------------------------------------------------

// A growable output buffer, so a frame is written in one pass with no
// per-term allocations.
class Writer {
  constructor() {
    this.buf = Buffer.allocUnsafe(256);
    this.pos = 0;
  }

  ensure(count) {
    if (this.pos + count <= this.buf.length) return;
    const grown = Buffer.allocUnsafe(Math.max(this.buf.length * 2, this.pos + count));
    grown.set(this.buf.subarray(0, this.pos));
    this.buf = grown;
  }

  byte(value) {
    this.ensure(1);
    this.buf[this.pos] = value;
    this.pos += 1;
  }

  tagged32(tag, value) {
    this.ensure(5);
    this.buf[this.pos] = tag;
    this.buf.writeUInt32BE(value, this.pos + 1);
    this.pos += 5;
  }

  bytes(bytes) {
    this.ensure(bytes.length);
    this.buf.set(bytes, this.pos);
    this.pos += bytes.length;
  }

  // `BINARY_EXT` of the text's UTF-8 bytes, written in place.
  text(text) {
    // UTF-8 needs at most 3 bytes per UTF-16 code unit.
    this.ensure(5 + text.length * 3);
    const n = this.buf.write(text, this.pos + 5, 'utf8');
    this.buf[this.pos] = BINARY;
    this.buf.writeUInt32BE(n, this.pos + 1);
    this.pos += 5 + n;
  }
}

function encode(envelope, limits = DEFAULT_LIMITS) {
  const out = new Writer();
  out.byte(VERSION);
  encodeTerm(envelope, out, 0, limits);
  if (out.pos > limits.max_frame_size) throw new DecodeError('max_size_exceeded', out.pos);
  return out.buf.subarray(0, out.pos);
}

function encodeTerm(term, out, depth, limits) {
  checkDepth(depth, limits);

  if (term === null || term === undefined) return out.bytes(NIL_ATOM);
  if (term === false) return out.bytes(FALSE_ATOM);
  if (term === true) return out.bytes(TRUE_ATOM);
  if (typeof term === 'number') {
    return Number.isInteger(term) ? encodeInt(term, out) : encodeFloat(term, out);
  }
  if (typeof term === 'bigint') return encodeInt(term, out);
  if (typeof term === 'string') return out.text(term);
  if (term instanceof Uint8Array) {
    out.bytes(BIN_PREFIX);
    out.tagged32(BINARY, term.length);
    return out.bytes(term);
  }
  if (term instanceof Float) return encodeFloat(term.value, out);
  if (term instanceof Atom) return encodeAtom(term.name, out);
  if (term instanceof Pid || term instanceof Ref) return out.bytes(term.raw);
  if (term instanceof Tuple) {
    const n = term.items.length;
    checkLength(n, limits);
    if (n < 256) {
      out.byte(SMALL_TUPLE);
      out.byte(n);
    } else {
      out.tagged32(LARGE_TUPLE, n);
    }
    for (const item of term.items) encodeTerm(item, out, depth + 1, limits);
    return undefined;
  }
  if (term instanceof ImproperList) {
    const items = Array.isArray(term.items) ? term.items : [term.items];
    checkLength(items.length, limits);
    out.tagged32(LIST, items.length);
    for (const item of items) encodeTerm(item, out, depth + 1, limits);
    return encodeTerm(term.tail, out, depth + 1, limits);
  }
  if (Array.isArray(term)) {
    checkLength(term.length, limits);
    if (term.length > 0) {
      out.tagged32(LIST, term.length);
      for (const item of term) encodeTerm(item, out, depth + 1, limits);
    }
    return out.byte(NIL);
  }
  if (term instanceof Map) {
    checkLength(term.size, limits);
    return encodeMap(term.entries(), term.size, out, depth, limits);
  }
  if (typeof term === 'object') {
    const entries = Object.entries(term);
    checkLength(entries.length, limits);
    return encodeMap(entries, entries.length, out, depth, limits);
  }

  throw new DecodeError('invalid_encoding', `unsupported type ${typeof term}`);
}

// Keys are sent as text, as under MessagePack.
function encodeMap(entries, size, out, depth, limits) {
  out.tagged32(MAP, size);
  for (const [key, value] of entries) {
    checkDepth(depth + 1, limits);
    out.text(String(key));
    encodeTerm(value, out, depth + 1, limits);
  }
}

function encodeAtom(name, out) {
  const text = Buffer.from(name, 'utf8');
  if (text.length < 256) {
    out.byte(SMALL_ATOM_UTF8);
    out.byte(text.length);
  } else {
    out.ensure(3);
    out.buf[out.pos] = ATOM_UTF8;
    out.buf.writeUInt16BE(text.length, out.pos + 1);
    out.pos += 3;
  }
  out.bytes(text);
}

function encodeFloat(value, out) {
  out.ensure(9);
  out.buf[out.pos] = NEW_FLOAT;
  out.buf.writeDoubleBE(value, out.pos + 1);
  out.pos += 9;
}

function encodeInt(value, out) {
  // BigInts are compared only with BigInts: QuickJS misorders mixed
  // comparisons for BigInts beyond the double range.
  const n = typeof value === 'bigint' && value >= -2147483648n && value <= 2147483647n
    ? Number(value)
    : value;
  if (typeof n === 'number' && n >= 0 && n < 256) {
    out.byte(SMALL_INTEGER);
    out.byte(n);
    return;
  }
  if (typeof n === 'number' && n >= -2147483648 && n <= 2147483647) {
    out.ensure(5);
    out.buf[out.pos] = INTEGER;
    out.buf.writeInt32BE(n, out.pos + 1);
    out.pos += 5;
    return;
  }

  // Sign byte, then the magnitude least significant byte first.
  let magnitude = BigInt(n);
  const sign = magnitude < 0n ? 1 : 0;
  if (sign) magnitude = -magnitude;
  const digits = [];
  while (magnitude > 0n) {
    digits.push(Number(magnitude & 0xffn));
    magnitude >>= 8n;
  }
  if (digits.length < 256) {
    out.byte(SMALL_BIG);
    out.byte(digits.length);
  } else {
    out.tagged32(LARGE_BIG, digits.length);
  }
  out.byte(sign);
  out.bytes(digits);
}

// -- Decoding ---------------------------------------------------------------

// Returns `[term, rest]`, where `rest` is a Buffer of any bytes left over.
function decode(data, limits = DEFAULT_LIMITS) {
  const buffer = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (buffer.length > limits.max_frame_size) throw new DecodeError('max_size_exceeded', buffer.length);
  if (buffer.length === 0) throw new DecodeError('truncated', 0);
  if (buffer[0] !== VERSION) throw new DecodeError('invalid_encoding', buffer[0]);

  const [term, pos] = decodeTerm(buffer, 1, 0, limits);
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

// Every invalid UTF-8 sequence decodes to U+FFFD, so only text containing
// one needs the (copying) check that it really was in the input.
function decodeText(data, start, end) {
  const text = data.toString('utf8', start, end);
  if (text.includes('�') && !Buffer.from(text, 'utf8').equals(data.subarray(start, end))) {
    throw new DecodeError('invalid_encoding', 'binary is not UTF-8');
  }
  return text;
}

function decodeTerm(data, pos, depth, limits) {
  checkDepth(depth, limits);
  need(data, pos, 1);
  const tag = data[pos];

  switch (tag) {
    case SMALL_INTEGER: need(data, pos, 2); return [data[pos + 1], pos + 2];
    case INTEGER: need(data, pos, 5); return [data.readInt32BE(pos + 1), pos + 5];
    case NEW_FLOAT: need(data, pos, 9); return [data.readDoubleBE(pos + 1), pos + 9];
    case SMALL_ATOM_UTF8:
    case SMALL_ATOM:
    case ATOM_UTF8:
    case ATOM: {
      const [name, next] = decodeAtom(data, pos);
      if (name === 'nil') return [null, next];
      if (name === 'true') return [true, next];
      if (name === 'false') return [false, next];
      return [new Atom(name), next];
    }
    case BINARY: {
      need(data, pos, 5);
      const start = pos + 5;
      const end = start + data.readUInt32BE(pos + 1);
      need(data, start, end - start);
      return [decodeText(data, start, end), end];
    }
    case NIL: return [[], pos + 1];
    case LIST: return decodeList(data, pos, depth, limits);
    case STRING: {
      need(data, pos, 3);
      const n = data.readUInt16BE(pos + 1);
      checkLength(n, limits);
      if (n > 0) checkDepth(depth + 1, limits);
      need(data, pos + 3, n);
      return [Array.from(data.subarray(pos + 3, pos + 3 + n)), pos + 3 + n];
    }
    case SMALL_TUPLE: need(data, pos, 2); return decodeTuple(data[pos + 1], data, pos + 2, depth, limits);
    case LARGE_TUPLE: need(data, pos, 5); return decodeTuple(data.readUInt32BE(pos + 1), data, pos + 5, depth, limits);
    case MAP: return decodeMap(data, pos, depth, limits);
    case SMALL_BIG: need(data, pos, 2); return decodeBig(data[pos + 1], data, pos + 2);
    case LARGE_BIG: need(data, pos, 5); return decodeBig(data.readUInt32BE(pos + 1), data, pos + 5);
    case NEW_PID:
    case PID: {
      const end = skipAtom(data, pos + 1) + (tag === NEW_PID ? 12 : 9);
      need(data, pos, end - pos);
      return [new Pid(data.subarray(pos, end)), end];
    }
    case NEWER_REFERENCE:
    case NEW_REFERENCE: {
      need(data, pos, 3);
      const words = data.readUInt16BE(pos + 1);
      const creation = tag === NEWER_REFERENCE ? 4 : 1;
      const end = skipAtom(data, pos + 3) + creation + 4 * words;
      need(data, pos, end - pos);
      return [new Ref(data.subarray(pos, end)), end];
    }
    // Bitstrings, funs, ports, exports, compressed terms, old floats.
    case BIT_BINARY:
    default:
      throw new DecodeError('invalid_encoding', tag);
  }
}

function decodeList(data, pos, depth, limits) {
  need(data, pos, 5);
  const count = data.readUInt32BE(pos + 1);
  checkLength(count, limits);
  const items = new Array(count);
  let cursor = pos + 5;
  for (let i = 0; i < count; i += 1) {
    const [item, next] = decodeTerm(data, cursor, depth + 1, limits);
    items[i] = item;
    cursor = next;
  }
  need(data, cursor, 1);
  if (data[cursor] === NIL) return [items, cursor + 1];
  const [tail, next] = decodeTerm(data, cursor, depth + 1, limits);
  return [new ImproperList(items, tail), next];
}

function decodeTuple(count, data, pos, depth, limits) {
  checkLength(count, limits);
  const items = new Array(count);
  let cursor = pos;
  for (let i = 0; i < count; i += 1) {
    const [item, next] = decodeTerm(data, cursor, depth + 1, limits);
    items[i] = item;
    cursor = next;
  }
  return [new Tuple(items), cursor];
}

function decodeBig(count, data, pos) {
  need(data, pos, 1 + count);
  const sign = data[pos];
  let value;
  if (count <= 6) {
    // Fits in 48 bits: no BigInt needed.
    let magnitude = 0;
    for (let i = count; i > 0; i -= 1) magnitude = magnitude * 256 + data[pos + i];
    value = sign ? -magnitude : magnitude;
  } else {
    let magnitude = 0n;
    for (let i = count; i > 0; i -= 1) magnitude = (magnitude << 8n) | BigInt(data[pos + i]);
    value = safeNumber(sign ? -magnitude : magnitude);
  }
  return [value, pos + 1 + count];
}

// The Bin struct is recognised on the raw atom keys (in either order)
// before the keys become text. The `data` binary is held as a byte range
// until then, as it is a Buffer in a Bin struct and text anywhere else.
function decodeMap(data, pos, depth, limits) {
  need(data, pos, 5);
  const count = data.readUInt32BE(pos + 1);
  checkLength(count, limits);
  const result = {};
  let cursor = pos + 5;
  let isBin = false;
  let raw = null;

  for (let i = 0; i < count; i += 1) {
    need(data, cursor, 1);
    const keyTag = data[cursor];
    const [key, afterKey] = decodeTerm(data, cursor, depth + 1, limits);
    const name = keyText(key, keyTag);
    cursor = afterKey;

    if (key instanceof Atom && name === 'data' && data[cursor] === BINARY) {
      checkDepth(depth + 1, limits);
      need(data, cursor, 5);
      const start = cursor + 5;
      const end = start + data.readUInt32BE(cursor + 1);
      need(data, start, end - start);
      raw = [start, end];
      result[name] = null;
      cursor = end;
    } else {
      const [value, afterValue] = decodeTerm(data, cursor, depth + 1, limits);
      if (key instanceof Atom && name === '__struct__' && value instanceof Atom && value.name === BIN_STRUCT) {
        isBin = true;
      }
      result[name] = value;
      cursor = afterValue;
    }
  }

  if (raw !== null) {
    // A `%Portals.Codec.Bin{}` struct comes back as a Buffer.
    if (count === 2 && isBin) return [Buffer.from(data.subarray(raw[0], raw[1])), cursor];
    result.data = decodeText(data, raw[0], raw[1]);
  }
  return [result, cursor];
}

// Keys become text, as under MessagePack (Elixir's to_string/1): binaries
// as themselves, atoms as their name (`nil` as ""), integers in decimal.
function keyText(key, tag) {
  if (typeof key === 'string') return key;
  if (key instanceof Atom) return key.name;
  if (key === null) return ''; // Elixir's to_string(nil)
  if (typeof key === 'boolean') return String(key);
  if (typeof key === 'bigint' || (typeof key === 'number' && tag !== NEW_FLOAT)) return String(key);
  throw new DecodeError('invalid_encoding', `unsupported map key tag ${tag}`);
}

function decodeAtom(data, pos) {
  const tag = data[pos];
  let n;
  let start;
  if (tag === SMALL_ATOM_UTF8 || tag === SMALL_ATOM) {
    need(data, pos, 2);
    n = data[pos + 1];
    start = pos + 2;
  } else {
    need(data, pos, 3);
    n = data.readUInt16BE(pos + 1);
    start = pos + 3;
  }
  need(data, start, n);
  if (tag === SMALL_ATOM_UTF8 || tag === ATOM_UTF8) return [decodeText(data, start, start + n), start + n];

  // Latin-1: one character per byte.
  let name = '';
  for (let i = start; i < start + n; i += 1) name += String.fromCharCode(data[i]);
  return [name, start + n];
}

// The node-name atom inside a PID or reference; returns where it ends.
function skipAtom(data, pos) {
  need(data, pos, 1);
  const tag = data[pos];
  if (tag !== SMALL_ATOM_UTF8 && tag !== SMALL_ATOM && tag !== ATOM_UTF8 && tag !== ATOM) {
    throw new DecodeError('invalid_encoding', tag);
  }
  return decodeAtom(data, pos)[1];
}

module.exports = { encode, decode, DecodeError, VERSION };
