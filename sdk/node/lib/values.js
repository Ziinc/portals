'use strict';

// Host-language representations of the Erlang-specific value extensions
// (`protocol/v1.md` §5.1). JavaScript has no atom table, no tuples, no
// cons-cell lists, and cannot construct or interpret PIDs/references, so
// these are wrapper types that re-encode identically to what was decoded.

class Atom {
  constructor(name) {
    this.name = name;
    Object.freeze(this);
  }

  toString() {
    return this.name;
  }
}

// An opaque local or distributed Erlang PID. A trusted worker may store and
// echo it back (e.g. as a `MESSAGE` target) but must never attempt to
// construct or interpret its bytes.
class Pid {
  constructor(raw) {
    this.raw = Buffer.from(raw);
    Object.freeze(this);
  }
}

// An opaque Erlang reference. Same opacity rules as `Pid`.
class Ref {
  constructor(raw) {
    this.raw = Buffer.from(raw);
    Object.freeze(this);
  }
}

// An Erlang tuple; JavaScript's Array is a list, so tuples need their own
// type to round-trip back to the BEAM as tuples.
class Tuple {
  constructor(items) {
    this.items = Array.isArray(items) ? items.slice() : [items];
    Object.freeze(this);
  }
}

// An Erlang improper list `[items | tail]`.
class ImproperList {
  constructor(items, tail) {
    this.items = items;
    this.tail = tail;
    Object.freeze(this);
  }
}

// Forces MessagePack float64 encoding for an integral JS number, which
// would otherwise encode as an integer (protocol/v1.md §5).
class Float {
  constructor(value) {
    this.value = Number(value);
    Object.freeze(this);
  }
}

const atom = (name) => new Atom(name);
const tuple = (...items) => new Tuple(items);
const float = (value) => new Float(value);

// Deep structural equality across the wrapper types, used by the tests and
// available to callers comparing decoded terms.
function termsEqual(a, b) {
  if (a === b) return true;
  if (typeof a === 'bigint' || typeof b === 'bigint') {
    if (typeof a === 'number' || typeof b === 'number') return BigInt(a) === BigInt(b);
    return a === b;
  }
  if (Buffer.isBuffer(a)) return Buffer.isBuffer(b) && a.equals(b);
  if (a instanceof Atom) return b instanceof Atom && a.name === b.name;
  if (a instanceof Pid) return b instanceof Pid && a.raw.equals(b.raw);
  if (a instanceof Ref) return b instanceof Ref && a.raw.equals(b.raw);
  if (a instanceof Float) return b instanceof Float && a.value === b.value;
  if (a instanceof Tuple) {
    return b instanceof Tuple && a.items.length === b.items.length
      && a.items.every((item, i) => termsEqual(item, b.items[i]));
  }
  if (a instanceof ImproperList) {
    return b instanceof ImproperList && termsEqual(a.items, b.items) && termsEqual(a.tail, b.tail);
  }
  if (Array.isArray(a)) {
    return Array.isArray(b) && a.length === b.length && a.every((item, i) => termsEqual(item, b[i]));
  }
  if (a && b && typeof a === 'object' && typeof b === 'object') {
    const ka = Object.keys(a);
    const kb = Object.keys(b);
    return ka.length === kb.length
      && ka.every((key) => Object.prototype.hasOwnProperty.call(b, key) && termsEqual(a[key], b[key]));
  }
  return false;
}

module.exports = { Atom, Pid, Ref, Tuple, ImproperList, Float, atom, tuple, float, termsEqual };
