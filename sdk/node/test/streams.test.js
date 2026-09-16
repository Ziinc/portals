'use strict';

// Mirrors `sdk/python/tests/test_streams.py` and
// `sdk/ruby/test/test_streams.rb`: the credit window, the independent
// queued-frame cap, per-direction half-close, and cancellation.

const test = require('node:test');
const assert = require('node:assert');

const { Stream, StreamClosed, StreamProtocolError, FRAME_PREFIX_BYTES } = require('../lib/streams');
const { encode, decode } = require('../lib/msgpackCodec');
const { DEFAULT_LIMITS, STREAM_DATA, CREDIT, HALF_CLOSE } = require('../lib/protocol');
const { streamHandler, isStreamHandler } = require('../lib/worker');

const WINDOW = 1024;
const MAX_FRAMES = 4;

function makeStream() {
  const sent = [];
  const stream = new Stream(
    7,
    WINDOW,
    MAX_FRAMES,
    (bytes) => sent.push(bytes),
    (envelope) => encode(envelope, DEFAULT_LIMITS),
  );
  const frames = () => sent.map((bytes) => decode(bytes, DEFAULT_LIMITS)[0]);
  return { stream, sent, frames };
}

const tick = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

test('initial grant offers the whole window once', () => {
  const { stream } = makeStream();
  assert.strictEqual(stream.initialGrant(), WINDOW);
  assert.strictEqual(stream.initialGrant(), 0);
});

test('inbound beyond the granted window is rejected', () => {
  const { stream } = makeStream();
  stream.initialGrant();
  stream.recordInbound('a', 512);
  assert.throws(() => stream.recordInbound('b', 600), StreamProtocolError);
});

test('a tiny frame flood hits the frame limit while bytes remain', () => {
  const { stream } = makeStream();
  stream.initialGrant();
  for (let i = 0; i < MAX_FRAMES; i += 1) stream.recordInbound(String(i), 8);
  assert.throws(() => stream.recordInbound('one too many', 8), StreamProtocolError);
});

test('consuming replenishes exactly what was consumed', async () => {
  const { stream, frames } = makeStream();
  stream.initialGrant();
  stream.recordInbound('chunk', 100);

  assert.strictEqual(await stream.recv(), 'chunk');
  const credit = frames().at(-1);
  assert.deepStrictEqual(credit, [CREDIT, 7, 100, 1]);
});

test('recv resolves null after the peer half-closes', async () => {
  const { stream } = makeStream();
  stream.peerHalfClosed();
  assert.strictEqual(await stream.recv(), null);
});

test('inbound after half-close is a protocol error', () => {
  const { stream } = makeStream();
  stream.initialGrant();
  stream.peerHalfClosed();
  assert.throws(() => stream.recordInbound('late', 8), StreamProtocolError);
});

test('send waits until credit arrives', async () => {
  const { stream, sent, frames } = makeStream();
  const pending = stream.send('payload');
  await tick();
  assert.strictEqual(sent.length, 0);

  stream.addSendCredit(WINDOW, 0);
  await pending;

  assert.strictEqual(sent.length, 1);
  assert.deepStrictEqual(frames()[0], [STREAM_DATA, 7, 'payload']);
});

test('send is charged the full frame size including the length prefix', async () => {
  const { stream, sent } = makeStream();
  const payload = encode([STREAM_DATA, 7, 'payload'], DEFAULT_LIMITS);
  stream.addSendCredit(payload.length + FRAME_PREFIX_BYTES, 0);
  await stream.send('payload');
  assert.strictEqual(sent.length, 1);

  // Exactly one frame's worth of credit was granted, so the next send parks.
  const parked = stream.send('payload');
  await tick();
  assert.strictEqual(sent.length, 1);
  stream.cancel();
  await assert.rejects(parked, StreamClosed);
});

test('send respects the unacknowledged frame limit', async () => {
  const { stream, sent } = makeStream();
  stream.addSendCredit(WINDOW, 0);
  for (let i = 0; i < MAX_FRAMES; i += 1) await stream.send('x');
  assert.strictEqual(sent.length, MAX_FRAMES);

  const parked = stream.send('x');
  await tick();
  assert.strictEqual(sent.length, MAX_FRAMES);

  stream.addSendCredit(0, MAX_FRAMES);
  await parked;
  assert.strictEqual(sent.length, MAX_FRAMES + 1);
});

test('a chunk larger than the window can never be sent', async () => {
  const { stream } = makeStream();
  stream.addSendCredit(WINDOW, 0);
  await assert.rejects(() => stream.send('x'.repeat(WINDOW * 2)), StreamProtocolError);
});

test('half-close is per direction and idempotent', async () => {
  const { stream, frames } = makeStream();
  stream.initialGrant();
  stream.halfClose();
  stream.halfClose();

  assert.strictEqual(frames().filter((frame) => frame[0] === HALF_CLOSE).length, 1);
  await assert.rejects(() => stream.send('late'), StreamClosed);

  // The receiving direction is untouched.
  stream.recordInbound('still-arriving', 32);
  assert.strictEqual(await stream.recv(), 'still-arriving');
});

test('cancel releases state and unblocks a parked sender', async () => {
  const { stream } = makeStream();
  stream.initialGrant();
  stream.recordInbound('queued', 32);

  const parked = stream.send('parked');
  await tick();
  stream.cancel();

  await assert.rejects(parked, StreamClosed);
  assert.ok(stream.cancelled);
  assert.strictEqual(await stream.recv(), null);
});

test('streamHandler marks and returns the function', () => {
  const marked = streamHandler(async () => 1);
  const unmarked = async () => 1;
  assert.ok(isStreamHandler(marked));
  assert.ok(!isStreamHandler(unmarked));
});
