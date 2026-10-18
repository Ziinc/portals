'use strict';

// Bidirectional streaming for the Node worker SDK (protocol/v1.md §9).
//
// A stream is opened by the BEAM as an ordinary `CALL` whose target was
// registered with `streamHandler(...)`; the call's `request_id` doubles as
// the `stream_id`. The handler receives a `Stream` as its first argument and
// runs against a dedicated stream-capacity budget, kept separate from the
// unary call budget so long-lived streams can never exhaust the concurrency
// this worker advertised for unary calls.
//
// Backpressure is an encoded-byte credit window, independent per direction,
// charged against the complete encoded frame size (4-byte length prefix
// included), plus a hard cap on queued-but-unconsumed frames so a flood of
// tiny frames cannot evade the byte window.

const { STREAM_DATA, CREDIT, HALF_CLOSE } = require('./protocol');

const FRAME_PREFIX_BYTES = 4;

// Thrown when sending on a cancelled/terminated stream, or on a direction
// this side already half-closed.
class StreamClosed extends Error {}

// The peer exceeded its documented byte or frame allowance.
class StreamProtocolError extends Error {}

class StreamTimeout extends Error {}

class Stream {
  constructor(streamId, maxCredit, maxFrames, sendFrame, encode) {
    this.id = streamId;
    this._maxCredit = maxCredit;
    this._maxFrames = maxFrames;
    this._sendFrame = sendFrame;
    this._encode = encode;

    this._sendCredit = 0;
    this._sendFrames = 0;
    this._recvCredit = 0;
    this._recvBytes = 0;
    this._inbox = [];
    this._outboundOpen = true;
    this._inboundOpen = true;
    this._cancelled = false;
    this._waiters = [];
  }

  get cancelled() {
    return this._cancelled;
  }

  // -- receive side ---------------------------------------------------

  // Bytes to grant the BEAM up front; also the replenishment amount after
  // consumption. Returns 0 when nothing is owed.
  initialGrant() {
    const bytes = this._maxCredit - this._recvCredit - this._recvBytes;
    if (bytes <= 0) return 0;
    this._recvCredit += bytes;
    return bytes;
  }

  // Account for one inbound STREAM_DATA frame. Throws
  // `StreamProtocolError` when the peer exceeded its allowance.
  recordInbound(chunk, frameSize) {
    if (!this._inboundOpen) throw new StreamProtocolError('STREAM_DATA after HALF_CLOSE');
    if (this._inbox.length >= this._maxFrames) {
      throw new StreamProtocolError('queued stream frame limit exceeded');
    }
    if (frameSize > this._recvCredit) throw new StreamProtocolError('stream byte credit exceeded');

    this._recvCredit -= frameSize;
    this._recvBytes += frameSize;
    this._inbox.push([chunk, frameSize]);
    this._notifyAll();
  }

  // Next inbound chunk, or `null` once the BEAM has half-closed its sending
  // direction (or the stream was cancelled). Consuming a chunk is what
  // replenishes the BEAM's credit.
  async recv(timeoutMs = null) {
    for (;;) {
      if (this._inbox.length > 0) {
        const [chunk, frameSize] = this._inbox.shift();
        this._recvBytes -= frameSize;
        const grant = this.initialGrant();
        if (grant > 0) this._sendFrame(this._encode([CREDIT, this.id, grant, 1]));
        return chunk;
      }
      if (this._cancelled || !this._inboundOpen) return null;
      await this._wait(timeoutMs, `stream ${this.id} receive timed out`);
    }
  }

  async* [Symbol.asyncIterator]() {
    for (;;) {
      const chunk = await this.recv();
      if (chunk === null) return;
      yield chunk;
    }
  }

  // -- send side ------------------------------------------------------

  // Send one chunk, suspending only this handler (never the socket reader)
  // until the BEAM has granted enough credit.
  async send(chunk, timeoutMs = null) {
    const payload = this._encode([STREAM_DATA, this.id, chunk]);
    const frameSize = payload.length + FRAME_PREFIX_BYTES;

    if (frameSize > this._maxCredit) {
      throw new StreamProtocolError(
        `chunk of ${frameSize} bytes exceeds the stream window of ${this._maxCredit}`,
      );
    }

    for (;;) {
      if (this._cancelled) throw new StreamClosed(`stream ${this.id} was cancelled`);
      if (!this._outboundOpen) {
        throw new StreamClosed(`stream ${this.id} outbound direction is half-closed`);
      }
      if (this._sendFrames < this._maxFrames && frameSize <= this._sendCredit) {
        this._sendCredit -= frameSize;
        this._sendFrames += 1;
        break;
      }
      await this._wait(timeoutMs, `stream ${this.id} send timed out waiting for credit`);
    }

    this._sendFrame(payload);
  }

  async sendAll(chunks, { timeoutMs = null, halfClose = true } = {}) {
    for (const chunk of chunks) await this.send(chunk, timeoutMs);
    if (halfClose) this.halfClose();
  }

  // Close only this side's sending direction. Idempotent.
  halfClose() {
    if (!this._outboundOpen || this._cancelled) return;
    this._outboundOpen = false;
    this._notifyAll();
    this._sendFrame(this._encode([HALF_CLOSE, this.id]));
  }

  // -- peer events ----------------------------------------------------

  addSendCredit(bytes, frames) {
    this._sendCredit = Math.min(this._sendCredit + bytes, this._maxCredit);
    this._sendFrames = Math.max(this._sendFrames - frames, 0);
    this._notifyAll();
  }

  peerHalfClosed() {
    this._inboundOpen = false;
    this._notifyAll();
  }

  // Release every piece of local state and unblock the handler.
  cancel() {
    this._cancelled = true;
    this._outboundOpen = false;
    this._inboundOpen = false;
    this._inbox.length = 0;
    this._notifyAll();
  }

  // -- internals -------------------------------------------------------

  _wait(timeoutMs, message) {
    return new Promise((resolve, reject) => {
      const waiter = { resolve, reject, timer: null };
      if (timeoutMs !== null && timeoutMs !== undefined) {
        waiter.timer = setTimeout(() => {
          const index = this._waiters.indexOf(waiter);
          if (index >= 0) this._waiters.splice(index, 1);
          reject(new StreamTimeout(message));
        }, timeoutMs);
      }
      this._waiters.push(waiter);
    });
  }

  _notifyAll() {
    const waiters = this._waiters;
    this._waiters = [];
    for (const waiter of waiters) {
      if (waiter.timer) clearTimeout(waiter.timer);
      waiter.resolve();
    }
  }
}

module.exports = { Stream, StreamClosed, StreamProtocolError, StreamTimeout, FRAME_PREFIX_BYTES };
