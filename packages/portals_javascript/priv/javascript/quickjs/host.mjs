// QuickJS host for the Portals JavaScript SDK.
//
//     qjs host.mjs worker.js [args...]
//
// QuickJS is a small embeddable engine without Node's APIs. This host
// provides the subset the SDK uses (Buffer, process, timers, a CommonJS
// `require`, and minimal `path`, `fs` and `async_hooks` modules), then
// loads the worker script exactly as Node would. Portals.JavaScript runs
// it for `runtime: :quickjs`.
//
// Limits that come from QuickJS itself:
//   * No sockets: the worker always uses the framed stdio transport
//     (Portals.JavaScript sets PORTALS_TRANSPORT=stdio).
//   * No async context tracking: AsyncLocalStorage is emulated with a
//     stack, so the call-context helpers (currentCallbackDepth,
//     currentDeadlineMs, isCancelled) are exact while calls don't
//     interleave across `await`s. See the JavaScript guide.

import * as std from 'qjs:std';
import * as os from 'qjs:os';

const hostPath = scriptArgs[0];
const sdkDir = dirname(dirname(absolute(hostPath)));
const sdkIndex = `${sdkDir}/portals-worker/index.js`;

// -- Paths -------------------------------------------------------------------

function normalize(p) {
  const absoluteInput = p.startsWith('/');
  const out = [];
  for (const part of p.split('/')) {
    if (part === '' || part === '.') continue;
    if (part === '..') out.pop();
    else out.push(part);
  }
  return (absoluteInput ? '/' : '') + out.join('/');
}

function absolute(p) {
  return p.startsWith('/') ? normalize(p) : normalize(`${os.getcwd()[0]}/${p}`);
}

function dirname(p) {
  const i = p.lastIndexOf('/');
  return i <= 0 ? '/' : p.slice(0, i);
}

const pathModule = {
  sep: '/',
  delimiter: ':',
  isAbsolute: (p) => p.startsWith('/'),
  normalize,
  dirname,
  basename(p, ext) {
    const base = p.slice(p.lastIndexOf('/') + 1);
    return ext && base.endsWith(ext) ? base.slice(0, -ext.length) : base;
  },
  extname(p) {
    const base = p.slice(p.lastIndexOf('/') + 1);
    const i = base.lastIndexOf('.');
    return i <= 0 ? '' : base.slice(i);
  },
  join: (...parts) => normalize(parts.filter((x) => x !== '').join('/')),
  resolve(...parts) {
    let p = '';
    for (const part of parts) p = part.startsWith('/') ? part : `${p}/${part}`;
    return absolute(p || '.');
  },
};

// -- UTF-8 (QuickJS has no TextEncoder/TextDecoder) --------------------------

function utf8Encode(str) {
  const out = [];
  for (let i = 0; i < str.length; i++) {
    let c = str.charCodeAt(i);
    if (c >= 0xd800 && c < 0xdc00 && i + 1 < str.length) {
      const d = str.charCodeAt(i + 1);
      if (d >= 0xdc00 && d < 0xe000) {
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
        i++;
      }
    }
    if (c >= 0xd800 && c < 0xe000) c = 0xfffd; // lone surrogate
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
}

function utf8Decode(bytes, start, end) {
  let s = '';
  let i = start;
  while (i < end) {
    const b = bytes[i];
    let c = 0xfffd;
    let n = 1;
    if (b < 0x80) c = b;
    else if (b >= 0xc2 && b < 0xe0 && i + 1 < end && (bytes[i + 1] & 0xc0) === 0x80) {
      c = ((b & 31) << 6) | (bytes[i + 1] & 63);
      n = 2;
    } else if (b >= 0xe0 && b < 0xf0 && i + 2 < end &&
               (bytes[i + 1] & 0xc0) === 0x80 && (bytes[i + 2] & 0xc0) === 0x80) {
      c = ((b & 15) << 12) | ((bytes[i + 1] & 63) << 6) | (bytes[i + 2] & 63);
      n = 3;
      if (c < 0x800 || (c >= 0xd800 && c < 0xe000)) c = 0xfffd;
    } else if (b >= 0xf0 && b < 0xf5 && i + 3 < end && (bytes[i + 1] & 0xc0) === 0x80 &&
               (bytes[i + 2] & 0xc0) === 0x80 && (bytes[i + 3] & 0xc0) === 0x80) {
      c = ((b & 7) << 18) | ((bytes[i + 1] & 63) << 12) | ((bytes[i + 2] & 63) << 6) | (bytes[i + 3] & 63);
      n = 4;
      if (c < 0x10000 || c > 0x10ffff) c = 0xfffd;
    }
    s += String.fromCodePoint(c);
    i += n;
  }
  return s;
}

// -- Buffer --------------------------------------------------------------------

class Buffer extends Uint8Array {
  static from(value, encodingOrOffset, length) {
    if (typeof value === 'string') {
      if (encodingOrOffset && !/^utf-?8$/i.test(encodingOrOffset)) {
        throw new Error(`Buffer.from: unsupported encoding ${encodingOrOffset}`);
      }
      return new Buffer(utf8Encode(value));
    }
    if (value instanceof ArrayBuffer) return new Buffer(value, encodingOrOffset ?? 0, length);
    const out = new Buffer(value.length);
    out.set(value);
    return out;
  }

  static alloc(size, fill = 0) {
    const out = new Buffer(size);
    if (fill) out.fill(fill);
    return out;
  }

  static allocUnsafe(size) {
    return new Buffer(size);
  }

  static isBuffer(value) {
    return value instanceof Buffer;
  }

  static byteLength(value) {
    return typeof value === 'string' ? utf8Encode(value).length : value.byteLength;
  }

  static concat(list, totalLength) {
    const total = totalLength ?? list.reduce((n, b) => n + b.length, 0);
    const out = new Buffer(total);
    let offset = 0;
    for (const b of list) {
      out.set(b.subarray(0, Math.min(b.length, total - offset)), offset);
      offset += b.length;
      if (offset >= total) break;
    }
    return out;
  }

  get _view() {
    return new DataView(this.buffer, this.byteOffset, this.byteLength);
  }

  // Node's slice shares memory, like subarray.
  slice(start, end) {
    return this.subarray(start, end);
  }

  toString(encoding = 'utf8', start = 0, end = this.length) {
    if (encoding === 'hex') {
      let s = '';
      for (let i = start; i < end; i++) s += this[i].toString(16).padStart(2, '0');
      return s;
    }
    return utf8Decode(this, start, end);
  }

  equals(other) {
    if (this.length !== other.length) return false;
    for (let i = 0; i < this.length; i++) if (this[i] !== other[i]) return false;
    return true;
  }

  readUInt8(o = 0) { return this[o]; }
  readInt8(o = 0) { return this._view.getInt8(o); }
  readUInt16BE(o = 0) { return this._view.getUint16(o); }
  readInt16BE(o = 0) { return this._view.getInt16(o); }
  readUInt32BE(o = 0) { return this._view.getUint32(o); }
  readInt32BE(o = 0) { return this._view.getInt32(o); }
  readFloatBE(o = 0) { return this._view.getFloat32(o); }
  readDoubleBE(o = 0) { return this._view.getFloat64(o); }
  readBigUInt64BE(o = 0) { return this._view.getBigUint64(o); }
  readBigInt64BE(o = 0) { return this._view.getBigInt64(o); }

  writeUInt8(v, o = 0) { this[o] = v; return o + 1; }
  writeInt8(v, o = 0) { this._view.setInt8(o, v); return o + 1; }
  writeUInt16BE(v, o = 0) { this._view.setUint16(o, v); return o + 2; }
  writeInt16BE(v, o = 0) { this._view.setInt16(o, v); return o + 2; }
  writeUInt32BE(v, o = 0) { this._view.setUint32(o, v); return o + 4; }
  writeInt32BE(v, o = 0) { this._view.setInt32(o, v); return o + 4; }
  writeFloatBE(v, o = 0) { this._view.setFloat32(o, v); return o + 4; }
  writeDoubleBE(v, o = 0) { this._view.setFloat64(o, v); return o + 8; }
  writeBigUInt64BE(v, o = 0) { this._view.setBigUint64(o, v); return o + 8; }
  writeBigInt64BE(v, o = 0) { this._view.setBigInt64(o, v); return o + 8; }
}

// -- process, console and timers -----------------------------------------------

function emitter() {
  const listeners = {};
  return {
    on(event, fn) { (listeners[event] ||= []).push(fn); return this; },
    once(event, fn) {
      const wrapped = (...args) => { this.removeListener(event, wrapped); fn(...args); };
      return this.on(event, wrapped);
    },
    removeListener(event, fn) {
      listeners[event] = (listeners[event] || []).filter((l) => l !== fn);
      return this;
    },
    emit(event, ...args) { for (const fn of listeners[event] || []) fn(...args); },
  };
}

function writeAll(fd, bytes) {
  let offset = 0;
  while (offset < bytes.length) {
    const n = os.write(fd, bytes.buffer, bytes.byteOffset + offset, bytes.length - offset);
    if (n <= 0) throw new Error(`write to fd ${fd} failed`);
    offset += n;
  }
}

// stdin delivers raw chunks through the QuickJS event loop, so frames are
// read while handlers run.
const stdin = emitter();
let stdinStarted = false;
const originalOn = stdin.on;
stdin.on = function on(event, fn) {
  originalOn.call(this, event, fn);
  if (event === 'data' && !stdinStarted) {
    stdinStarted = true;
    const chunk = new ArrayBuffer(65536);
    os.setReadHandler(0, () => {
      const n = os.read(0, chunk, 0, chunk.byteLength);
      if (n <= 0) {
        os.setReadHandler(0, null);
        stdin.emit('end');
        stdin.emit('close');
        return;
      }
      stdin.emit('data', Buffer.from(new Uint8Array(chunk, 0, n)));
    });
  }
  return this;
};

const stdout = { write(data) { writeAll(1, typeof data === 'string' ? Buffer.from(data) : data); return true; } };
const stderr = { write(data) { writeAll(2, typeof data === 'string' ? Buffer.from(data) : data); return true; } };

globalThis.Buffer = Buffer;
globalThis.process = {
  argv: ['qjs', ...scriptArgs.slice(1)],
  env: std.getenviron(),
  versions: { quickjs: (globalThis.navigator?.userAgent ?? 'quickjs/unknown').split('/')[1] },
  platform: os.platform,
  cwd: () => os.getcwd()[0],
  exit: (code = 0) => std.exit(code),
  stdin,
  stdout,
  stderr,
  nextTick: (fn, ...args) => queueMicrotask(() => fn(...args)),
};

// Under the stdio transport, stdout carries protocol frames: keep console
// output off it.
const toStderr = (...args) => stderr.write(`${args.map((a) => (typeof a === 'string' ? a : JSON.stringify(a))).join(' ')}\n`);
globalThis.console = { log: toStderr, info: toStderr, warn: toStderr, error: toStderr, debug: toStderr };

globalThis.setTimeout = (fn, ms = 0, ...args) => os.setTimeout(() => fn(...args), ms);
globalThis.clearTimeout = (handle) => handle && os.clearTimeout(handle);
globalThis.setImmediate = (fn, ...args) => os.setTimeout(() => fn(...args), 0);
globalThis.clearImmediate = globalThis.clearTimeout;

// -- Node built-ins the SDK requires -----------------------------------------------

// QuickJS cannot propagate a store across `await`. This emulation keeps a
// stack of the calls in flight: a store is current from the moment its
// callback starts until the promise it returns settles.
class AsyncLocalStorage {
  constructor() {
    this._stack = [];
  }

  getStore() {
    return this._stack[this._stack.length - 1];
  }

  run(store, fn, ...args) {
    this._stack.push(store);
    const remove = () => {
      const i = this._stack.lastIndexOf(store);
      if (i !== -1) this._stack.splice(i, 1);
    };
    let result;
    try {
      result = fn(...args);
    } catch (err) {
      remove();
      throw err;
    }
    if (result && typeof result.then === 'function') {
      return result.then((v) => { remove(); return v; }, (e) => { remove(); throw e; });
    }
    remove();
    return result;
  }
}

const builtins = {
  path: pathModule,
  async_hooks: { AsyncLocalStorage },
  fs: {
    createWriteStream(file) {
      const f = std.open(file, 'a');
      return { write(s) { f.puts(String(s)); f.flush(); return true; }, end() { f.close(); } };
    },
    existsSync: (p) => os.stat(p)[1] === 0,
    readFileSync(p, encoding) {
      const text = std.loadFile(p);
      if (text === null) throw new Error(`ENOENT: no such file ${p}`);
      return encoding ? text : Buffer.from(text);
    },
  },
  net: {
    createConnection() {
      throw new Error('QuickJS has no socket support: use the stdio transport (PORTALS_TRANSPORT=stdio)');
    },
  },
  module: {},
};

// -- CommonJS loader -----------------------------------------------------------------

const cache = new Map();

function isFile(p) {
  const [st, err] = os.stat(p);
  return err === 0 && (st.mode & os.S_IFMT) === os.S_IFREG;
}

function resolveFile(p) {
  for (const candidate of [p, `${p}.js`, `${p}.cjs`, `${p}.json`]) if (isFile(candidate)) return candidate;
  const pkg = `${p}/package.json`;
  if (isFile(pkg)) {
    const main = JSON.parse(std.loadFile(pkg)).main;
    if (main) {
      const resolved = resolveFile(normalize(`${p}/${main}`));
      if (resolved) return resolved;
    }
  }
  for (const index of [`${p}/index.js`, `${p}/index.cjs`]) if (isFile(index)) return index;
  return null;
}

function resolveRequest(request, fromDir) {
  const bare = request.replace(/^node:/, '');
  if (bare in builtins) return { builtin: bare };
  if (request === 'portals-worker') return { file: sdkIndex };
  if (request.startsWith('./') || request.startsWith('../') || request.startsWith('/')) {
    const file = resolveFile(request.startsWith('/') ? normalize(request) : normalize(`${fromDir}/${request}`));
    if (file) return { file };
  } else {
    // node_modules lookup, for the worker's own dependencies.
    for (let dir = fromDir; ; dir = dirname(dir)) {
      const file = resolveFile(`${dir}/node_modules/${request}`);
      if (file) return { file };
      if (dir === '/') break;
    }
  }
  const err = new Error(`Cannot find module '${request}' from ${fromDir}`);
  err.code = 'MODULE_NOT_FOUND';
  throw err;
}

function makeRequire(fromDir) {
  const require = (request) => {
    const target = resolveRequest(request, fromDir);
    return target.builtin ? builtins[target.builtin] : load(target.file);
  };
  require.resolve = (request) => {
    const target = resolveRequest(request, fromDir);
    return target.builtin ?? target.file;
  };
  return require;
}

// Cache by real path, as Node does, so a module reached through a symlink
// (e.g. _build/.../priv) and through its source path loads only once.
function realpath(p) {
  const [real, err] = os.realpath(p);
  return err === 0 ? real : p;
}

function load(path) {
  const file = realpath(path);
  if (cache.has(file)) return cache.get(file).exports;

  const module = { exports: {}, filename: file, id: file, loaded: false };
  cache.set(file, module);
  const source = std.loadFile(file);
  if (source === null) throw new Error(`cannot read ${file}`);

  if (file.endsWith('.json')) {
    module.exports = JSON.parse(source);
  } else {
    const body = source.startsWith('#!') ? `//${source}` : source;
    const wrapper = std.evalScript(
      `(function (exports, require, module, __filename, __dirname) {${body}\n})`,
    );
    wrapper.call(module.exports, module.exports, makeRequire(dirname(file)), module, file, dirname(file));
  }
  module.loaded = true;
  return module.exports;
}

builtins.module = { _cache: cache, createRequire: (from) => makeRequire(dirname(absolute(from))) };

// -- Run the worker script -------------------------------------------------------------

const script = scriptArgs[1];
if (!script) {
  stderr.write('usage: qjs host.mjs worker.js [args...]\n');
  std.exit(2);
}

try {
  load(absolute(script));
} catch (err) {
  stderr.write(`portals worker: ${err && err.stack ? `${err}\n${err.stack}` : err}\n`);
  std.exit(1);
}
