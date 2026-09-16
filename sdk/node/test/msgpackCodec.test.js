'use strict';

// Mirrors `sdk/python/tests/test_msgpack_codec.py` and
// `sdk/ruby/test/test_msgpack_codec.rb` so all three codecs are held to the
// same contract.

const test = require('node:test');
const assert = require('node:assert');

const { encode, decode, DecodeError } = require('../lib/msgpackCodec');
const { DEFAULT_LIMITS, HELLO, CALL, RETURN } = require('../lib/protocol');
const { Atom, Pid, Ref, Tuple, ImproperList, termsEqual } = require('../lib/values');

function roundTrip(envelope) {
  const encoded = encode(envelope, DEFAULT_LIMITS);
  const [decoded, rest] = decode(encoded, DEFAULT_LIMITS);
  assert.strictEqual(rest.length, 0);
  return decoded;
}

function assertRoundTrip(envelope) {
  const decoded = roundTrip(envelope);
  assert.ok(termsEqual(decoded, envelope), `round trip changed ${require('node:util').inspect(envelope)}`);
}

test('primitives', () => {
  assertRoundTrip([null, true, false]);
});

test('ints including bigints', () => {
  assertRoundTrip([0, 1, 127, 128, 255, 256, 65535, 65536, -1, -32, -33, -128, -129, -32768, -32769]);

  const huge = 170141183460469231731687303715884105728n;
  assertRoundTrip([huge, -huge]);
});

test('float', () => {
  assertRoundTrip([1.5]);
});

test('str and bin are distinct', () => {
  const decoded = roundTrip(['hello', Buffer.from([0, 1, 2])]);
  assert.strictEqual(decoded[0], 'hello');
  assert.ok(Buffer.isBuffer(decoded[1]));
  assert.ok(decoded[1].equals(Buffer.from([0, 1, 2])));
});

test('tuple', () => {
  assertRoundTrip([new Tuple([1, 'a', null])]);
});

test('atom', () => {
  assertRoundTrip([new Atom('ok')]);
});

test('pid and reference are opaque round trips', () => {
  assertRoundTrip([new Pid(Buffer.from('\x83pid_bytes')), new Ref(Buffer.from('\x83ref_bytes'))]);
});

test('improper list', () => {
  assertRoundTrip([new ImproperList([1, 2], new Atom('tail'))]);
});

test('nested map', () => {
  assertRoundTrip([{ a: 1, b: [1, 2, 3], c: { nested: true } }]);
});

test('call and hello envelope shapes', () => {
  assertRoundTrip([HELLO, 1, 'node22', 16, 0, []]);
  assertRoundTrip([CALL, 1, 'bench_worker', 'echo', ['hello']]);
});

test('max frame size enforced', () => {
  assert.throws(
    () => encode(['much too long a string'], { ...DEFAULT_LIMITS, max_frame_size: 4 }),
    DecodeError,
  );
});

test('truncated frame raises DecodeError, not a generic exception', () => {
  assert.throws(() => decode(Buffer.from([0x91]), DEFAULT_LIMITS), (err) => {
    assert.ok(err instanceof DecodeError);
    assert.strictEqual(err.reason, 'truncated');
    return true;
  });
});

test('unknown leading byte is invalid_encoding', () => {
  assert.throws(() => decode(Buffer.from([0xc1]), DEFAULT_LIMITS), (err) => {
    assert.strictEqual(err.reason, 'invalid_encoding');
    return true;
  });
});

test('oversized collection is rejected', () => {
  assert.throws(() => decode(Buffer.from([0xdd, 0xff, 0xff, 0xff, 0xff]), DEFAULT_LIMITS), (err) => {
    assert.strictEqual(err.reason, 'max_length_exceeded');
    return true;
  });
});

test('large binary round trips', () => {
  const blob = Buffer.alloc(70000);
  const decoded = roundTrip([RETURN, 1, blob]);
  assert.ok(decoded[2].equals(blob));
});

test('return envelope round trip', () => {
  assertRoundTrip([RETURN, 42, { ok: true }]);
});
