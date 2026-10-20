'use strict';

// Mirrors `packages/portals_python/priv/python/tests/test_etf_codec.py`, so
// both ETF codecs are held to the same contract.

const test = require('node:test');
const assert = require('node:assert');
const { execFileSync } = require('node:child_process');
const path = require('node:path');
const { inspect } = require('node:util');

const { encode, decode, DecodeError } = require('../lib/etfCodec');
const msgpackCodec = require('../lib/msgpackCodec');
const { DEFAULT_LIMITS } = require('../lib/protocol');
const { Atom, Pid, Ref, Tuple, ImproperList, Float, termsEqual } = require('../lib/values');

// :erlang.term_to_binary/1 of
//   [3, 7, "héllo", %{"k" => [1, -2, 300, 2_147_483_648, -(2**70)]},
//    {:ok, nil, true, false}, 1.5, [], ~c"ab", [1 | 2],
//    %Portals.Codec.Bin{data: <<0, 255>>}]
const BEAM_BYTES = Buffer.from(
  '836c0000000a610361076d0000000668c3a96c6c6f74000000016d000000016b6c00000005610162fffffffe'
  + '620000012c6e0400000000806e09010000000000000000406a68046400026f6b6400036e696c640004747275'
  + '6564000566616c7365463ff80000000000006a6b000261626c0000000161016102740000000264000a5f5f73'
  + '74727563745f5f640018456c697869722e506f7274616c732e436f6465632e42696e640004646174616d0000'
  + '000200ff6a',
  'hex',
);

const BEAM_TERM = [
  3,
  7,
  'héllo',
  { k: [1, -2, 300, 2147483648, -(2n ** 70n)] },
  new Tuple([new Atom('ok'), null, true, false]),
  1.5,
  [],
  [97, 98],
  new ImproperList([1], 2),
  Buffer.from([0, 255]),
];

function assertTerm(actual, expected) {
  assert.ok(termsEqual(actual, expected), `${inspect(actual)} != ${inspect(expected)}`);
}

function assertRejected(data, reason, limits = DEFAULT_LIMITS) {
  assert.throws(() => decode(data, limits), (err) => {
    assert.ok(err instanceof DecodeError, `not a DecodeError: ${err}`);
    assert.strictEqual(err.reason, reason);
    return true;
  });
}

test('decodes what the BEAM encodes', () => {
  const [term, rest] = decode(BEAM_BYTES);
  assertTerm(term, BEAM_TERM);
  assert.strictEqual(rest.length, 0);
  assert.ok(Buffer.isBuffer(term[9]));
  assert.strictEqual(typeof term[3].k[4], 'bigint');
});

test('encodes the golden term back to identical values', () => {
  const [term] = decode(encode(BEAM_TERM));
  assertTerm(term, BEAM_TERM);
});

test('round trips every value type', () => {
  const envelope = [
    4,
    1,
    {
      none: null,
      bools: [true, false],
      ints: [0, 255, 256, -1, 2 ** 31, -(2 ** 31) - 1, 2 ** 53 - 1, 2n ** 64n, -(2n ** 2100n)],
      float: -0.25,
      text: 'naïve ✓',
      bytes: Buffer.from([0, 1, 254]),
      empty: Buffer.alloc(0),
      emptyText: '',
      atom: new Atom('ok'),
      tuple: new Tuple([1, 'two', new Tuple([3])]),
      bigTuple: new Tuple(Array.from({ length: 300 }, (_, i) => i)),
      improper: new ImproperList([1, 2], 'tail'),
      nested: { a: [{ b: [] }] },
      long: 'x'.repeat(70000),
    },
  ];
  const [term, rest] = decode(encode(envelope));
  assertTerm(term, envelope);
  assert.strictEqual(rest.length, 0);
});

test('decodes to the same values as MessagePack', () => {
  const envelope = [
    null, true, false, 1, -1, 2 ** 40, 2n ** 70n, 1.5, 'text', Buffer.from([1, 2]),
    new Atom('ok'), new Tuple([1]), new ImproperList([1], 2), [1, [2]], { a: { b: 1 } },
  ];
  const [viaEtf] = decode(encode(envelope));
  const [viaMsgpack] = msgpackCodec.decode(msgpackCodec.encode(envelope));
  assertTerm(viaEtf, viaMsgpack);
});

test('Float forces NEW_FLOAT_EXT for an integral number', () => {
  const encoded = encode([new Float(2)]);
  assert.strictEqual(encoded[6], 70);
  assert.deepStrictEqual(decode(encoded)[0], [2]);
  assert.strictEqual(encode([2])[6], 97);
});

test('Uint8Array and Map encode like Buffer and object', () => {
  const [term] = decode(encode([new Uint8Array([7]), new Map([['a', 1]])]));
  assertTerm(term, [Buffer.from([7]), { a: 1 }]);
});

test('pids and references are opaque and written back verbatim', () => {
  // self() and make_ref() from a BEAM, as NEW_PID_EXT / NEWER_REFERENCE_EXT.
  const pid = Buffer.from('5864000d6e6f6e6f6465406e6f686f73740000005e0000000000000000', 'hex');
  const ref = Buffer.from('5a000364000d6e6f6e6f6465406e6f686f73740000000000008033634c0004263763cf', 'hex');
  const data = Buffer.concat([Buffer.from([131, 108, 0, 0, 0, 2]), pid, ref, Buffer.from([106])]);
  const [term] = decode(data);
  assertTerm(term, [new Pid(pid), new Ref(ref)]);
  assert.ok(encode(term).equals(data));
});

test('a data key outside a Bin struct stays text', () => {
  const [term] = decode(encode([{ data: 'x', other: 1 }]));
  assertTerm(term, [{ data: 'x', other: 1 }]);

  // Atom keys, as the BEAM sends `%{data: "x", other: 1}`, and a
  // `__struct__` that is not the Bin struct.
  const beam = Buffer.concat([
    Buffer.from([131, 116, 0, 0, 0, 2]),
    Buffer.from([119, 4]), Buffer.from('data'), Buffer.from([109, 0, 0, 0, 1]), Buffer.from('x'),
    Buffer.from([119, 10]), Buffer.from('__struct__'), Buffer.from([119, 3]), Buffer.from('Foo'),
  ]);
  assertTerm(decode(beam)[0], [{ data: 'x', __struct__: new Atom('Foo') }]);
});

test('the Bin struct is recognised with its keys in either order', () => {
  const beam = Buffer.concat([
    Buffer.from([131, 116, 0, 0, 0, 2]),
    Buffer.from([119, 4]), Buffer.from('data'), Buffer.from([109, 0, 0, 0, 2, 0xc3, 0x28]),
    Buffer.from([119, 10]), Buffer.from('__struct__'),
    Buffer.from([119, 24]), Buffer.from('Elixir.Portals.Codec.Bin'),
  ]);
  assertTerm(decode(beam)[0], [Buffer.from([0xc3, 0x28])]);
});

test('map keys become text as under MessagePack', () => {
  // %{a: 1, 2 => 3, "s" => 4, nil => 5} from a BEAM.
  const beam = Buffer.from('837400000004610261036400016161016400036e696c61056d00000001736104', 'hex');
  assertTerm(decode(beam)[0], [{ 2: 3, a: 1, s: 4, '': 5 }]);
  assertTerm(decode(encode([new Map([[1, 'x'], [new Atom('k'), 'y']])]))[0], [{ 1: 'x', k: 'y' }]);

  // Any other key type is invalid: %{{1} => 2} and %{1.5 => 2}.
  assertRejected(Buffer.from([131, 116, 0, 0, 0, 1, 104, 1, 97, 1, 97, 2]), 'invalid_encoding');
  assertRejected(
    Buffer.from([131, 116, 0, 0, 0, 1, 70, 0x3f, 0xf8, 0, 0, 0, 0, 0, 0, 97, 2]),
    'invalid_encoding',
  );
});

test('Latin-1 atoms and charlists decode', () => {
  // ATOM_EXT 'é', SMALL_ATOM_EXT 'ok', STRING_EXT "ab".
  const [term] = decode(Buffer.from([131, 108, 0, 0, 0, 3, 100, 0, 1, 0xe9, 115, 2, 111, 107, 107, 0, 2, 97, 98, 106]));
  assertTerm(term, [new Atom('é'), new Atom('ok'), [97, 98]]);
});

test('trailing bytes are returned to the frame reader', () => {
  const [term, rest] = decode(Buffer.from([131, 97, 1, 0]));
  assert.deepStrictEqual(term, [1]);
  assert.deepStrictEqual([...rest], [0]);
});

test('malformed input raises DecodeError with the protocol reasons', () => {
  assertRejected(Buffer.alloc(0), 'truncated');
  assertRejected(Buffer.from([0]), 'invalid_encoding');
  assertRejected(BEAM_BYTES.subarray(0, -3), 'truncated');
  assertRejected(Buffer.from([131, 77]), 'invalid_encoding');
  assertRejected(Buffer.from([131, 77, 0, 0, 0, 1, 3, 0xe0]), 'invalid_encoding');
  assertRejected(Buffer.from([131, 109, 0, 0, 0, 1, 0xff]), 'invalid_encoding');
  assertRejected(Buffer.from([131, 109, 0, 0, 0, 2, 0xc3, 0x28]), 'invalid_encoding');
  assertRejected(Buffer.from([131, 200]), 'invalid_encoding');
  assertRejected(Buffer.from([131, 108, 0, 0, 0, 3, 97, 1]), 'truncated');
  assertRejected(Buffer.from([131, 108, 0xff, 0xff, 0xff, 0xff]), 'max_length_exceeded');
  assertRejected(Buffer.concat([Buffer.from([131, 109, 0, 0, 0, 10]), Buffer.from('short')]), 'truncated');
  assertRejected(Buffer.from([131, 88, 97, 1]), 'invalid_encoding');
  // A literal U+FFFD is valid text, not a decoding error.
  assert.deepStrictEqual(decode(Buffer.from([131, 109, 0, 0, 0, 3, 0xef, 0xbf, 0xbd]))[0], ['�']);

  const deep = Buffer.concat([
    Buffer.from([131]),
    Buffer.from(Array(40).fill([108, 0, 0, 0, 1]).flat()),
    Buffer.from([97, 1]),
    Buffer.alloc(40, 106),
  ]);
  assertRejected(deep, 'max_depth_exceeded');
});

test('enforces limits on decode', () => {
  const limits = { max_frame_size: 1024, max_nesting_depth: 2, max_collection_length: 3 };
  assertRejected(encode([[[[1]]]]), 'max_depth_exceeded', limits);
  assertRejected(encode([[1, 2, 3, 4]]), 'max_length_exceeded', limits);
  assertRejected(encode([new Tuple([1, 2, 3, 4])]), 'max_length_exceeded', limits);
  assertRejected(encode([{ a: 1, b: 2, c: 3, d: 4 }]), 'max_length_exceeded', limits);
  assertRejected(encode(['x'.repeat(2000)]), 'max_size_exceeded', limits);
});

test('enforces limits on encode', () => {
  const limits = { max_frame_size: 1024, max_nesting_depth: 2, max_collection_length: 3 };
  const reason = (fn) => {
    try {
      fn();
    } catch (err) {
      assert.ok(err instanceof DecodeError);
      return err.reason;
    }
    return 'ok';
  };
  assert.strictEqual(reason(() => encode([[[[1]]]], limits)), 'max_depth_exceeded');
  assert.strictEqual(reason(() => encode([[1, 2, 3, 4]], limits)), 'max_length_exceeded');
  assert.strictEqual(reason(() => encode(['x'.repeat(2000)], limits)), 'max_size_exceeded');
  assert.strictEqual(reason(() => encode([() => 1], limits)), 'invalid_encoding');
});

test('shares its DecodeError with the MessagePack codec', () => {
  assert.strictEqual(DecodeError, msgpackCodec.DecodeError);
});

// -- Codec selection --------------------------------------------------------

function selectedCodec(value) {
  const env = { ...process.env };
  delete env.PORTALS_CODEC;
  if (value !== undefined) env.PORTALS_CODEC = value;
  const script = `process.stdout.write(require(${JSON.stringify(path.join(__dirname, '..', 'lib', 'codec'))}).NAME)`;
  return execFileSync(process.execPath, ['-e', script], { env, stdio: ['ignore', 'pipe', 'pipe'] }).toString();
}

test('PORTALS_CODEC selects the codec, defaulting to etf', () => {
  assert.strictEqual(selectedCodec(undefined), 'etf');
  assert.strictEqual(selectedCodec('etf'), 'etf');
  assert.strictEqual(selectedCodec('msgpack'), 'msgpack');
});

test('an unknown PORTALS_CODEC fails startup', () => {
  assert.throws(() => selectedCodec('json'), /PORTALS_CODEC="json" is not a codec this SDK speaks/);
});
