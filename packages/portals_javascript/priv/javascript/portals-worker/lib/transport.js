'use strict';

// Length-framed transport for the Node worker side.
//
// Matches the BEAM's `{:packet, 4}` framing exactly: a 4-byte big-endian
// length prefix followed by that many bytes of MessagePack-encoded
// envelope. `FramedConnection` hides the framing so callers only ever see
// whole envelopes, and buffers whole frames so the reader is never coupled
// to how fast handlers run.

const net = require('net');

class ConnectionClosed extends Error {}

class FramedConnection {
  constructor(readable, writable, closer) {
    this._writable = writable;
    this._closer = closer;
    this._buffer = Buffer.alloc(0);
    this._frames = [];
    this._waiters = [];
    this._closed = false;
    this._error = null;

    readable.on('data', (chunk) => this._onData(chunk));
    readable.on('end', () => this._onClose(null));
    readable.on('close', () => this._onClose(null));
    readable.on('error', (err) => this._onClose(err));
  }

  static connectUnix(path) {
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(path);
      socket.once('connect', () => {
        socket.removeListener('error', reject);
        resolve(new FramedConnection(socket, socket, () => socket.destroy()));
      });
      socket.once('error', reject);
    });
  }

  static stdio() {
    return new FramedConnection(process.stdin, process.stdout, () => {});
  }

  sendFrame(payload) {
    if (this._closed) return;
    const header = Buffer.allocUnsafe(4);
    header.writeUInt32BE(payload.length, 0);
    this._writable.write(Buffer.concat([header, payload]));
  }

  // Resolves with the next complete envelope, or `null` once the peer has
  // closed cleanly.
  recvFrame() {
    if (this._frames.length > 0) return Promise.resolve(this._frames.shift());
    if (this._error) return Promise.reject(this._error);
    if (this._closed) return Promise.resolve(null);
    return new Promise((resolve, reject) => this._waiters.push({ resolve, reject }));
  }

  close() {
    this._closed = true;
    try {
      this._closer();
    } catch {
      /* closing a already-dead socket is not an error */
    }
  }

  _onData(chunk) {
    this._buffer = this._buffer.length === 0 ? chunk : Buffer.concat([this._buffer, chunk]);

    for (;;) {
      if (this._buffer.length < 4) break;
      const length = this._buffer.readUInt32BE(0);
      if (this._buffer.length < 4 + length) break;

      const payload = Buffer.from(this._buffer.subarray(4, 4 + length));
      this._buffer = Buffer.from(this._buffer.subarray(4 + length));

      const waiter = this._waiters.shift();
      if (waiter) waiter.resolve(payload);
      else this._frames.push(payload);
    }
  }

  _onClose(err) {
    if (this._closed) return;
    this._closed = true;
    if (err) this._error = err;
    else if (this._buffer.length > 0) this._error = new ConnectionClosed('connection closed mid-frame');

    const waiters = this._waiters;
    this._waiters = [];
    for (const waiter of waiters) {
      if (this._error) waiter.reject(this._error);
      else waiter.resolve(null);
    }
  }
}

// `Portals.Connection` appends the socket path as the final CLI argument.
function socketPathFromArgv() {
  const args = process.argv.slice(2);
  if (args.length === 0) {
    throw new Error('portals worker: expected the socket path as the last argument');
  }
  return args[args.length - 1];
}

module.exports = { FramedConnection, ConnectionClosed, socketPathFromArgv };
