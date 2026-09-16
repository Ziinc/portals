'use strict';

// The Node worker runtime: connects to the BEAM's Unix socket, completes the
// exact-version handshake, and dispatches `CALL` frames to arbitrary
// module/function targets concurrently.
//
//     const { Worker } = require('portals');
//     await new Worker({ modules: { bench_worker: handlers } }).run();
//
// The socket reader is a loop that never awaits handler execution: a `CALL`
// is started and the loop immediately reads the next frame, so a slow or
// blocked handler can never stall reading further frames or responding to
// other in-flight calls. Concurrency is bounded by the `max_concurrency`
// advertised in `HELLO`, with streams held to a separate `max_streams`
// budget so long-lived streams cannot consume unary capacity.

const path = require('path');
const fs = require('fs');
const { AsyncLocalStorage } = require('async_hooks');

const p = require('./protocol');
const { encode, decode, DecodeError } = require('./msgpackCodec');
const { buildErrorMap, overloadErrorMap, protocolErrorMap } = require('./errors');
const { FramedConnection, ConnectionClosed, socketPathFromArgv } = require('./transport');
const { Stream, StreamProtocolError, FRAME_PREFIX_BYTES } = require('./streams');

// Thrown by `callback()` when the BEAM-side handler fails.
class RemoteError extends Error {
  constructor(errorMap) {
    super(errorMap.message || 'callback failed');
    this.name = 'RemoteError';
    this.errorMap = errorMap;
  }
}

class ProtocolError extends Error {}

class CallbackTimeout extends Error {}

// Per-call context: reentrancy depth, deadline, and a cooperative
// cancellation flag, all visible to the handler without threading an extra
// argument through user code.
const callContext = new AsyncLocalStorage();

// Mark a function as a streaming target. The BEAM's `open_stream/5`
// dispatches to it with a `Stream` as the first argument; the value it
// resolves to becomes the stream's terminal `RETURN`.
function streamHandler(fn) {
  fn.portalsStreamHandler = true;
  return fn;
}

const isStreamHandler = (fn) => Boolean(fn && fn.portalsStreamHandler);

let activeWorker = null;

class Worker {
  constructor(options = {}) {
    this.maxConcurrency = options.maxConcurrency ?? 16;
    this.maxStreams = options.maxStreams ?? 8;
    this.socketPath = options.socketPath ?? null;
    this.transportMode = options.transport ?? 'unix';
    // Overridable strictly so the version-mismatch diagnostics can be
    // exercised end to end; real workers always send the SDK's version.
    this.protocolVersion = options.protocolVersion ?? p.PROTOCOL_VERSION;
    this.modulePaths = options.modulePaths ?? [process.cwd()];
    this.limits = { ...p.DEFAULT_LIMITS };
    this.log = Worker.defaultLogger(options.logger, options.logFile);

    this._modules = new Map();
    for (const [name, mod] of Object.entries(options.modules ?? {})) this.register(name, mod);

    this._streams = new Map();
    this._pendingUnary = new Map();
    this._shutdown = false;
    this._conn = null;

    this._activeCalls = 0;
    this._callQueue = [];
    this._activeStreams = 0;

    this._callbackId = 0;
    this._pendingCallbacks = new Map();
  }

  // Logging goes to a file or a callback, never over the RPC protocol.
  static defaultLogger(logger, logFile) {
    if (typeof logger === 'function') return logger;
    const file = logFile ?? process.env.PORTALS_LOG_FILE;
    if (file) {
      const stream = fs.createWriteStream(file, { flags: 'a' });
      return (message) => stream.write(`${message}\n`);
    }
    return (message) => process.stderr.write(`${message}\n`);
  }

  // Register a handler module under the name the BEAM will use in `CALL`.
  register(name, mod) {
    this._modules.set(String(name), mod);
    return this;
  }

  async run() {
    this._conn = this.transportMode === 'stdio'
      ? FramedConnection.stdio()
      : await FramedConnection.connectUnix(this.socketPath ?? socketPathFromArgv());

    await this.handshake();
    activeWorker = this;

    try {
      while (!this._shutdown) {
        let payload;
        try {
          payload = await this._conn.recvFrame();
        } catch (err) {
          if (err instanceof ConnectionClosed) break;
          break;
        }
        if (payload === null) break;

        // Deliberately not awaited: the reader must stay independent of
        // handler execution.
        this.handleFrame(payload);
      }
    } finally {
      if (activeWorker === this) activeWorker = null;
      this.cancelAllStreams();
      this._conn.close();
    }
  }

  // -- Handshake ------------------------------------------------------

  async handshake() {
    const hello = [
      p.HELLO,
      this.protocolVersion,
      `node${process.versions.node}`,
      this.maxConcurrency,
      this.maxStreams,
      [],
    ];
    this._conn.sendFrame(encode(hello, this.limits));

    const payload = await this._conn.recvFrame();
    if (payload === null) throw new ConnectionClosed('connection closed during handshake');

    const [envelope, rest] = decode(payload, this.limits);
    if (rest.length !== 0) throw new ProtocolError('trailing bytes after READY');

    const [tag, version, limits] = envelope;
    if (tag !== p.READY) throw new ProtocolError(`expected READY, got frame tag ${tag}`);
    if (version !== p.PROTOCOL_VERSION) {
      throw new ProtocolError(
        `protocol version mismatch: worker=${p.PROTOCOL_VERSION} beam=${version}`,
      );
    }

    this.limits = { ...this.limits, ...limits };
  }

  // -- Reentrant callbacks and messaging --------------------------------

  callCallback(moduleName, functionName, args = [], timeoutMs = null) {
    const depth = Worker.currentCallbackDepth() + 1;
    this._callbackId += 1;
    const id = this._callbackId;

    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, timer: null };
      if (timeoutMs !== null && timeoutMs !== undefined) {
        entry.timer = setTimeout(() => {
          this._pendingCallbacks.delete(id);
          reject(new CallbackTimeout(`callback ${moduleName}.${functionName} timed out`));
        }, timeoutMs);
      }
      this._pendingCallbacks.set(id, entry);
      this.sendEnvelope([p.CALLBACK, id, moduleName, functionName, args, depth]);
    });
  }

  sendMessage(targetPid, value) {
    this.sendEnvelope([p.MESSAGE, targetPid, value]);
  }

  resolveCallback(id, ok, value, errorMap) {
    const entry = this._pendingCallbacks.get(id);
    if (!entry) {
      this.log(`portals worker: unknown callback_id ${id} in response`);
      return;
    }
    this._pendingCallbacks.delete(id);
    if (entry.timer) clearTimeout(entry.timer);
    if (ok) entry.resolve(value);
    else entry.reject(new RemoteError(errorMap));
  }

  static currentCallbackDepth() {
    const context = callContext.getStore();
    return context ? context.depth : 0;
  }

  // -- Frame dispatch ---------------------------------------------------

  handleFrame(payload) {
    let envelope;
    let rest;
    try {
      [envelope, rest] = decode(payload, this.limits);
    } catch (err) {
      if (err instanceof DecodeError) {
        this.log(`portals worker: dropping malformed frame: ${err.reason} ${err.detail}`);
        return;
      }
      throw err;
    }

    if (rest.length !== 0) {
      this.log('portals worker: dropping frame with trailing bytes');
      return;
    }

    const tag = envelope[0];
    const frameSize = payload.length + FRAME_PREFIX_BYTES;

    switch (tag) {
      case p.CALL:
        this.submitCall(envelope.slice(1));
        break;
      case p.CANCEL:
        this.cancelRequest(envelope[1]);
        break;
      case p.STREAM_DATA:
        this.handleStreamData(envelope[1], envelope[2], frameSize);
        break;
      case p.CREDIT: {
        const fields = envelope.slice(1);
        const stream = this._streams.get(fields[0]);
        if (stream) stream.addSendCredit(fields[1], fields.length > 2 ? fields[2] : 1);
        break;
      }
      case p.HALF_CLOSE: {
        const stream = this._streams.get(envelope[1]);
        if (stream) stream.peerHalfClosed();
        break;
      }
      case p.CALLBACK_RETURN:
        this.resolveCallback(envelope[1], true, envelope[2], null);
        break;
      case p.CALLBACK_ERROR:
        this.resolveCallback(envelope[1], false, null, envelope[2]);
        break;
      case p.PING:
        this.sendEnvelope([p.PONG, envelope[1]]);
        break;
      case p.PONG:
        break;
      case p.SHUTDOWN:
        this._shutdown = true;
        // Deferred so any already-queued RETURN/ERROR frames still flush.
        setImmediate(() => this._conn.close());
        break;
      default:
        this.log(`portals worker: ignoring unsupported frame tag ${tag}`);
    }
  }

  // -- Dispatch ---------------------------------------------------------

  // Route a CALL to the unary budget, or — when its target was registered
  // with `streamHandler` — to the separate stream budget with a `Stream`
  // bound to the call's request_id.
  submitCall(fields) {
    const [requestId, moduleName, functionName] = fields;
    const target = this.resolveQuietly(moduleName, functionName);

    if (!isStreamHandler(target)) {
      this.enqueueUnary(fields);
      return;
    }

    if (this.maxStreams <= 0) {
      this.sendEnvelope([p.ERROR, requestId, overloadErrorMap('worker advertises no streams')]);
      return;
    }
    if (this._streams.size >= this.maxStreams) {
      this.sendEnvelope([p.ERROR, requestId, overloadErrorMap('max_streams exceeded')]);
      return;
    }

    const stream = new Stream(
      requestId,
      this.limits.max_stream_byte_credit,
      this.limits.max_queued_stream_frames,
      (bytes) => this._conn.sendFrame(bytes),
      (envelope) => encode(envelope, this.limits),
    );
    this._streams.set(requestId, stream);

    const grant = stream.initialGrant();
    if (grant > 0) this.sendEnvelope([p.CREDIT, requestId, grant, 0]);

    this.dispatchStreamCall(stream, target, fields);
  }

  async dispatchStreamCall(stream, target, fields) {
    const requestId = fields[0];
    const args = fields[3] ?? [];

    try {
      const result = await target(stream, ...args);
      stream.halfClose();
      this._streams.delete(requestId);
      if (!stream.cancelled) this.sendEnvelope([p.RETURN, requestId, result]);
    } catch (err) {
      this._streams.delete(requestId);
      if (!stream.cancelled) this.sendEnvelope([p.ERROR, requestId, buildErrorMap(err)]);
    }
  }

  // Bounded unary execution: run now if the advertised concurrency allows,
  // otherwise queue. Either way the reader keeps going.
  enqueueUnary(fields) {
    if (this._activeCalls < this.maxConcurrency) {
      this.runUnary(fields);
    } else {
      this._callQueue.push(fields);
    }
  }

  async runUnary(fields) {
    this._activeCalls += 1;
    const [requestId, moduleName, functionName, args, deadlineMs, depth] = fields;
    const context = { depth: depth ?? 0, deadlineMs: deadlineMs ?? null, cancelled: false };
    this._pendingUnary.set(requestId, context);

    try {
      const target = this.resolveTarget(moduleName, functionName);
      const result = await callContext.run(context, () => target(...(args ?? [])));
      this.sendEnvelope([p.RETURN, requestId, result]);
    } catch (err) {
      this.sendEnvelope([p.ERROR, requestId, buildErrorMap(err)]);
    } finally {
      this._pendingUnary.delete(requestId);
      this._activeCalls -= 1;
      const next = this._callQueue.shift();
      if (next) this.runUnary(next);
    }
  }

  // Resolve a wire module name to a handler object: an explicitly
  // registered module wins; otherwise the name is `require`d relative to
  // this worker's configured module paths.
  resolveTarget(moduleName, functionName) {
    const mod = this.resolveModule(moduleName);
    const target = mod[functionName];
    if (typeof target !== 'function') {
      throw new Error(`no such function ${moduleName}.${functionName}`);
    }
    return target.bind(mod);
  }

  resolveModule(name) {
    const key = String(name);
    if (this._modules.has(key)) return this._modules.get(key);

    for (const base of this.modulePaths) {
      try {
        /* eslint-disable-next-line global-require, import/no-dynamic-require */
        const mod = require(path.resolve(base, key));
        this._modules.set(key, mod);
        return mod;
      } catch {
        /* try the next configured module path */
      }
    }
    throw new Error(`no such module ${key}`);
  }

  resolveQuietly(moduleName, functionName) {
    try {
      const mod = this.resolveModule(moduleName);
      return mod[functionName];
    } catch {
      // An unresolvable target is reported properly by the unary path.
      return null;
    }
  }

  // -- Cancellation and streaming ---------------------------------------

  // `CANCEL` shares the `request_id` space with streams: it cancels the
  // stream outright, or raises the cooperative cancellation flag for an
  // in-flight unary call.
  cancelRequest(requestId) {
    const stream = this._streams.get(requestId);
    if (stream) {
      stream.cancel();
      this._streams.delete(requestId);
      return;
    }
    const context = this._pendingUnary.get(requestId);
    if (context) context.cancelled = true;
  }

  handleStreamData(streamId, chunk, frameSize) {
    const stream = this._streams.get(streamId);
    if (!stream) return;

    try {
      stream.recordInbound(chunk, frameSize);
    } catch (err) {
      if (!(err instanceof StreamProtocolError)) throw err;
      // A peer that exceeds its allowance loses only that stream.
      stream.cancel();
      this._streams.delete(streamId);
      this.sendEnvelope([p.ERROR, streamId, protocolErrorMap(err.message)]);
    }
  }

  cancelAllStreams() {
    for (const stream of this._streams.values()) stream.cancel();
    this._streams.clear();
  }

  sendEnvelope(envelope) {
    try {
      this._conn.sendFrame(encode(envelope, this.limits));
    } catch (err) {
      this.log(`portals worker: send failed: ${err.message}`);
    }
  }
}

// -- Module-level helpers ------------------------------------------------

// Invoke a BEAM callback from within a `CALL` handler and await its result.
// Requires a running `Worker` in this process.
function callback(moduleName, functionName, args = [], timeoutMs = null) {
  if (!activeWorker) {
    throw new Error('portals.callback() called with no active Worker in this process');
  }
  return activeWorker.callCallback(moduleName, functionName, args, timeoutMs);
}

// Send a value to a BEAM PID (typically one received as a `CALL` argument).
// Fire-and-forget.
function sendMessage(targetPid, value) {
  if (!activeWorker) {
    throw new Error('portals.sendMessage() called with no active Worker in this process');
  }
  activeWorker.sendMessage(targetPid, value);
}

const currentCallbackDepth = () => Worker.currentCallbackDepth();

// The deadline (ms) the BEAM attached to the currently executing CALL.
function currentDeadlineMs() {
  const context = callContext.getStore();
  return context ? context.deadlineMs : null;
}

// Cooperative cancellation: true once the BEAM sent `CANCEL` for the call
// currently executing on this async context.
function isCancelled() {
  const context = callContext.getStore();
  return context ? context.cancelled : false;
}

module.exports = {
  Worker,
  RemoteError,
  ProtocolError,
  CallbackTimeout,
  streamHandler,
  isStreamHandler,
  callback,
  sendMessage,
  currentCallbackDepth,
  currentDeadlineMs,
  isCancelled,
};
