'use strict';

// Inline calls (protocol/v1.md §7.1), driven against a real `Worker` over a
// Unix socket with this test playing the BEAM: an inline CALL replies before
// any later frame is acted on, calls already running carry on, and
// `callback()` fails at once inside it.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const net = require('net');
const os = require('os');
const path = require('path');

const { encode, decode } = require('../lib/codec');
const p = require('../lib/protocol');
const { FramedConnection } = require('../lib/transport');
const { Worker, callback, currentCallbackDepth } = require('../lib/worker');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const handlers = {
  add: (a, b) => a + b,
  async sleep_ms(ms) {
    await sleep(ms);
    return ms;
  },
  // A synchronous handler that blocks the event loop outright.
  spin_ms(ms) {
    const until = Date.now() + ms;
    while (Date.now() < until) { /* spin */ }
    return ms;
  },
  async via_callback(x) {
    return callback('Elixir.Callbacks', 'double', [x]);
  },
  depth: () => currentCallbackDepth(),
};

// Start a worker on a fresh socket and complete the handshake as the BEAM.
async function startWorker() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'portals-inline-'));
  const socketPath = path.join(dir, 'worker.sock');
  const accepted = new Promise((resolve) => {
    const server = net.createServer((socket) => {
      server.close();
      resolve(socket);
    });
    server.listen(socketPath);
  });

  const worker = new Worker({ socketPath, modules: { m: handlers }, logger: () => {} });
  const running = worker.run();
  const socket = await accepted;
  const conn = new FramedConnection(socket, socket, () => socket.destroy());

  const send = (envelope) => conn.sendFrame(encode(envelope, p.DEFAULT_LIMITS));
  const recv = async () => decode(await conn.recvFrame(), p.DEFAULT_LIMITS)[0];

  assert.strictEqual((await recv())[0], p.HELLO);
  send([p.READY, p.PROTOCOL_VERSION, {}]);

  const stop = async () => {
    conn.close();
    await running;
    fs.rmSync(dir, { recursive: true, force: true });
  };
  return { send, recv, stop };
}

test('an inline call returns its result like any other call', async () => {
  const beam = await startWorker();
  try {
    beam.send([p.CALL, 1, 'm', 'add', [1, 2], null, 0, true]);
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 1, 3]);
  } finally {
    await beam.stop();
  }
});

test('frames arriving during an async inline call wait until it has replied', async () => {
  const beam = await startWorker();
  try {
    beam.send([p.CALL, 1, 'm', 'sleep_ms', [150], null, 0, true]);
    beam.send([p.PING, 7]);
    beam.send([p.CALL, 2, 'm', 'add', [1, 2]]);

    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 1, 150]);
    assert.deepStrictEqual(await beam.recv(), [p.PONG, 7]);
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 2, 3]);
  } finally {
    await beam.stop();
  }
});

test('a CALL whose inline field is false or absent does not pause the reader', async () => {
  const beam = await startWorker();
  try {
    beam.send([p.CALL, 1, 'm', 'sleep_ms', [150], null, 0, false]);
    beam.send([p.CALL, 2, 'm', 'sleep_ms', [150], 5000]);
    beam.send([p.PING, 7]);

    assert.deepStrictEqual(await beam.recv(), [p.PONG, 7]);
    const replies = [await beam.recv(), await beam.recv()].sort((a, b) => a[1] - b[1]);
    assert.deepStrictEqual(replies, [[p.RETURN, 1, 150], [p.RETURN, 2, 150]]);
  } finally {
    await beam.stop();
  }
});

test('calls already running carry on and may complete during an inline call', async () => {
  const beam = await startWorker();
  try {
    beam.send([p.CALL, 1, 'm', 'sleep_ms', [20]]);
    beam.send([p.CALL, 2, 'm', 'sleep_ms', [200], null, 0, true]);
    beam.send([p.PING, 7]);

    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 1, 20]);
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 2, 200]);
    assert.deepStrictEqual(await beam.recv(), [p.PONG, 7]);
  } finally {
    await beam.stop();
  }
});

test('an inline call carries the CALL context', async () => {
  const beam = await startWorker();
  try {
    beam.send([p.CALL, 1, 'm', 'depth', [], null, 3, true]);
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 1, 3]);
    beam.send([p.CALL, 2, 'm', 'spin_ms', [20], null, 0, true]);
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 2, 20]);
  } finally {
    await beam.stop();
  }
});

test('callback() fails at once inside an inline call, but not in ordinary calls', async () => {
  const beam = await startWorker();
  try {
    beam.send([p.CALL, 1, 'm', 'via_callback', [21], null, 0, true]);
    const [tag, id, error] = await beam.recv();
    assert.deepStrictEqual([tag, id], [p.ERROR, 1]);
    assert.match(error.message, /inline/);

    beam.send([p.CALL, 2, 'm', 'via_callback', [21]]);
    const [cbTag, cbId, mod, fun, args, depth] = await beam.recv();
    assert.deepStrictEqual([cbTag, mod, fun, args, depth], [p.CALLBACK, 'Elixir.Callbacks', 'double', [21], 1]);
    beam.send([p.CALLBACK_RETURN, cbId, 42]);
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 2, 42]);
  } finally {
    await beam.stop();
  }
});

test('an ordinary call started before an inline call can still call back', async () => {
  const beam = await startWorker();
  try {
    beam.send([p.CALL, 1, 'm', 'via_callback', [5]]);
    const [, cbId] = await beam.recv();
    beam.send([p.CALL, 2, 'm', 'sleep_ms', [50], null, 0, true]);
    beam.send([p.CALLBACK_RETURN, cbId, 10]);

    // The CALLBACK_RETURN is read only once the inline call has replied.
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 2, 50]);
    assert.deepStrictEqual(await beam.recv(), [p.RETURN, 1, 10]);
  } finally {
    await beam.stop();
  }
});
