'use strict';

// Function targets used by the Elixir integration tests — the Node mirror of
// `sdk/python/tests/fixtures/bench_worker.py`.

const portals = require('../..');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const echo = (value) => value;

const add = (a, b) => a + b;

function raiseError(message) {
  throw new TypeError(message);
}

async function sleepMs(ms) {
  await sleep(ms);
  return ms;
}

function crashProcess() {
  process.exit(1);
}

// Calls back into the BEAM to double a number, demonstrating a reentrant
// round trip.
const doubleViaCallback = (n) =>
  portals.callback('Elixir.Portals.Fixtures.CallbackTarget', 'double', [n]);

// A callback target the Elixir side invokes; while running (still inside the
// BEAM-side callback handler) it reports the reentrancy depth the BEAM
// echoed back on this nested CALL.
const nestedCallThenCallback = (_connMarker, n) => ({
  depth_seen: portals.currentCallbackDepth(),
  doubled: n * 2,
});

const callbackDepthProbe = () => portals.currentCallbackDepth();

const deadlineProbe = () => portals.currentDeadlineMs();

function messageToCaller(pid, value) {
  portals.sendMessage(pid, value);
  return 'sent';
}

const raiseCallbackError = () =>
  portals.callback('Elixir.Portals.Fixtures.CallbackTarget', 'boom', []);

// Value-model probes: proves the Erlang extensions survive a round trip
// through Node untouched.
const echoTerm = (value) => value;

const makeTuple = (items) => new portals.Tuple(items);

const makeAtom = (text) => new portals.Atom(text);

// Cooperative cancellation: polls the flag the CANCEL frame raises.
async function cancellable(ms) {
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    if (portals.isCancelled()) return 'cancelled';
    await sleep(5);
  }
  return 'completed';
}

// -- Streaming targets ---------------------------------------------------

// Echo every inbound chunk back out, then terminate with a count.
const echoStream = portals.streamHandler(async (stream) => {
  let count = 0;
  for (;;) {
    const chunk = await stream.recv();
    if (chunk === null) break;
    await stream.send(chunk);
    count += 1;
  }
  return count;
});

// Produce `count` chunks of `size` bytes each, blocking on the BEAM's credit
// window.
const produceStream = portals.streamHandler(async (stream, count, size) => {
  const payload = 'x'.repeat(size);
  for (let i = 0; i < count; i += 1) await stream.send(payload, 10000);
  stream.halfClose();
  return count;
});

// Consume everything the BEAM sends, optionally slowly.
const drainStream = portals.streamHandler(async (stream, delayMs = 0) => {
  let chunks = 0;
  let bytes = 0;
  for await (const chunk of stream) {
    chunks += 1;
    bytes += Buffer.byteLength(chunk);
    if (delayMs) await sleep(delayMs);
  }
  return { chunks, bytes };
});

// Never consume inbound chunks: the BEAM's sender must block on the credit
// window rather than grow BEAM memory.
const neverConsume = portals.streamHandler(async (stream, holdMs) => {
  await sleep(holdMs);
  return 'held';
});

// Close only the worker's sending direction immediately, then keep
// consuming — proving half-close is per-direction.
const halfCloseThenDrain = portals.streamHandler(async (stream) => {
  stream.halfClose();
  let chunks = 0;
  for await (const _chunk of stream) chunks += 1;
  return chunks;
});

// Keep a stream open (and a stream slot busy) without doing anything, for
// unary/stream fairness tests.
const holdStream = portals.streamHandler(async (stream, holdMs) => {
  await sleep(holdMs);
  return 'done';
});

module.exports = {
  echo,
  add,
  // The BEAM addresses targets by their wire name; both the snake_case
  // names the shared integration tests use and the JS-idiomatic camelCase
  // names are exported.
  raise_error: raiseError,
  raiseError,
  sleep_ms: sleepMs,
  sleepMs,
  crash_process: crashProcess,
  crashProcess,
  double_via_callback: doubleViaCallback,
  doubleViaCallback,
  nested_call_then_callback: nestedCallThenCallback,
  nestedCallThenCallback,
  callback_depth_probe: callbackDepthProbe,
  callbackDepthProbe,
  deadline_probe: deadlineProbe,
  deadlineProbe,
  message_to_caller: messageToCaller,
  messageToCaller,
  raise_callback_error: raiseCallbackError,
  raiseCallbackError,
  echo_term: echoTerm,
  echoTerm,
  make_tuple: makeTuple,
  makeTuple,
  make_atom: makeAtom,
  makeAtom,
  cancellable,
  echo_stream: echoStream,
  echoStream,
  produce_stream: produceStream,
  produceStream,
  drain_stream: drainStream,
  drainStream,
  never_consume: neverConsume,
  neverConsume,
  half_close_then_drain: halfCloseThenDrain,
  halfCloseThenDrain,
  hold_stream: holdStream,
  holdStream,
};
