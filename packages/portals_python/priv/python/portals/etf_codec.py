"""Benchmark-only Erlang External Term Format codec, the Python side of
`Portals.Codec.ETFBench`. Selected with `PORTALS_CODEC=etf`; MessagePack
(`msgpack_codec`) is the only supported wire codec.

Values map to the same Python types as under MessagePack:

* binaries are `str` (UTF-8), and `%Portals.Codec.Bin{}` structs are
  `bytes` (and `bytes` encode as that struct);
* the atoms `nil`, `true` and `false` are `None`, `True` and `False`, and
  other atoms are `Atom`;
* tuples are `tuple`, maps are `dict`, improper lists are `ImproperList`;
* PIDs and references are opaque `Pid` / `Reference` wrapping their ETF
  bytes, which are written back verbatim.
"""

import struct
from typing import Tuple

from .protocol import DEFAULT_LIMITS
from .values import Atom, ImproperList, Pid, Reference

VERSION = 131

NEW_FLOAT = 70
BIT_BINARY = 77
NEW_PID = 88
NEWER_REFERENCE = 90
SMALL_INTEGER = 97
INTEGER = 98
ATOM = 100
PID = 103
SMALL_TUPLE = 104
LARGE_TUPLE = 105
NIL = 106
STRING = 107
LIST = 108
BINARY = 109
SMALL_BIG = 110
LARGE_BIG = 111
NEW_REFERENCE = 114
SMALL_ATOM = 115
MAP = 116
ATOM_UTF8 = 118
SMALL_ATOM_UTF8 = 119

_SPECIAL_ATOMS = {"nil": None, "true": True, "false": False}
_BIN_STRUCT = Atom("Elixir.Portals.Codec.Bin")
_STRUCT_KEY = Atom("__struct__")
_DATA_KEY = Atom("data")
# How `bytes` are encoded: `%Portals.Codec.Bin{data: ...}`, up to the data
# binary itself.
_BIN_PREFIX = (
    bytes([MAP]) + struct.pack(">I", 2)
    + bytes([SMALL_ATOM_UTF8, 10]) + b"__struct__"
    + bytes([SMALL_ATOM_UTF8, 24]) + b"Elixir.Portals.Codec.Bin"
    + bytes([SMALL_ATOM_UTF8, 4]) + b"data"
)


class DecodeError(Exception):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(repr(reason))


def encode(envelope: list, limits: dict = DEFAULT_LIMITS) -> bytes:
    out = bytearray([VERSION])
    _encode_term(envelope, out, 0, limits)
    if len(out) > limits["max_frame_size"]:
        raise DecodeError(("max_size_exceeded", len(out)))
    return bytes(out)


def decode(data: bytes, limits: dict = DEFAULT_LIMITS) -> Tuple[list, bytes]:
    if len(data) > limits["max_frame_size"]:
        raise DecodeError(("max_size_exceeded", len(data)))
    if not data:
        raise DecodeError(("truncated", 0))
    if data[0] != VERSION:
        raise DecodeError(("invalid_encoding", data[0]))
    view = memoryview(data)
    try:
        term, pos = _decode_term(view, 1, 0, limits)
    except (IndexError, struct.error) as err:
        raise DecodeError(("truncated", len(data))) from err
    if not isinstance(term, list):
        term = [term]
    return term, bytes(view[pos:])


# -- Encoding -------------------------------------------------------------


def _check_depth(depth, limits):
    if depth > limits["max_nesting_depth"]:
        raise DecodeError(("max_depth_exceeded", depth))


def _check_length(n, limits):
    if n > limits["max_collection_length"]:
        raise DecodeError(("max_length_exceeded", n))


def _encode_atom(name: str, out: bytearray) -> None:
    text = name.encode("utf-8")
    if len(text) < 256:
        out += bytes([SMALL_ATOM_UTF8, len(text)])
    else:
        out += bytes([ATOM_UTF8]) + struct.pack(">H", len(text))
    out += text


def _encode_term(term, out: bytearray, depth: int, limits: dict) -> None:
    _check_depth(depth, limits)

    if term is None:
        _encode_atom("nil", out)
    elif term is True:
        _encode_atom("true", out)
    elif term is False:
        _encode_atom("false", out)
    elif isinstance(term, Atom):
        _encode_atom(term.name, out)
    elif isinstance(term, (Pid, Reference)):
        out += term.raw
    elif isinstance(term, int):
        _encode_int(term, out)
    elif isinstance(term, float):
        out += bytes([NEW_FLOAT]) + struct.pack(">d", term)
    elif isinstance(term, str):
        text = term.encode("utf-8")
        out += bytes([BINARY]) + struct.pack(">I", len(text))
        out += text
    elif isinstance(term, (bytes, bytearray)):
        out += _BIN_PREFIX
        out += bytes([BINARY]) + struct.pack(">I", len(term))
        out += term
    elif isinstance(term, tuple):
        _check_length(len(term), limits)
        if len(term) < 256:
            out += bytes([SMALL_TUPLE, len(term)])
        else:
            out += bytes([LARGE_TUPLE]) + struct.pack(">I", len(term))
        for item in term:
            _encode_term(item, out, depth + 1, limits)
    elif isinstance(term, ImproperList):
        out += bytes([LIST]) + struct.pack(">I", len(term.items))
        for item in term.items:
            _encode_term(item, out, depth + 1, limits)
        _encode_term(term.tail, out, depth + 1, limits)
    elif isinstance(term, dict):
        _check_length(len(term), limits)
        out += bytes([MAP]) + struct.pack(">I", len(term))
        for key, value in term.items():
            _encode_term(key, out, depth + 1, limits)
            _encode_term(value, out, depth + 1, limits)
    elif isinstance(term, list):
        _check_length(len(term), limits)
        if term:
            out += bytes([LIST]) + struct.pack(">I", len(term))
            for item in term:
                _encode_term(item, out, depth + 1, limits)
        out.append(NIL)
    else:
        raise DecodeError(("invalid_encoding", f"unsupported type {type(term)!r}"))


def _encode_int(n: int, out: bytearray) -> None:
    if 0 <= n < 256:
        out += bytes([SMALL_INTEGER, n])
    elif -(2**31) <= n < 2**31:
        out += bytes([INTEGER]) + struct.pack(">i", n)
    else:
        magnitude = abs(n)
        digits = magnitude.to_bytes((magnitude.bit_length() + 7) // 8, "little")
        if len(digits) < 256:
            out += bytes([SMALL_BIG, len(digits)])
        else:
            out += bytes([LARGE_BIG]) + struct.pack(">I", len(digits))
        out.append(1 if n < 0 else 0)
        out += digits


# -- Decoding -------------------------------------------------------------


def _decode_term(data: memoryview, pos: int, depth: int, limits: dict):
    _check_depth(depth, limits)
    tag = data[pos]

    if tag == SMALL_INTEGER:
        return data[pos + 1], pos + 2
    if tag == INTEGER:
        return struct.unpack_from(">i", data, pos + 1)[0], pos + 5
    if tag == NEW_FLOAT:
        return struct.unpack_from(">d", data, pos + 1)[0], pos + 9
    if tag in (SMALL_ATOM_UTF8, SMALL_ATOM, ATOM_UTF8, ATOM):
        name, pos = _decode_atom(data, pos)
        if name in _SPECIAL_ATOMS:
            return _SPECIAL_ATOMS[name], pos
        return Atom(name), pos
    if tag == BINARY:
        (n,) = struct.unpack_from(">I", data, pos + 1)
        start = pos + 5
        _need(data, start + n)
        try:
            return str(data[start : start + n], "utf-8"), start + n
        except UnicodeDecodeError as err:
            raise DecodeError(("invalid_encoding", "binary is not UTF-8")) from err
    if tag == NIL:
        return [], pos + 1
    if tag == LIST:
        (n,) = struct.unpack_from(">I", data, pos + 1)
        _check_length(n, limits)
        pos += 5
        items = []
        for _ in range(n):
            item, pos = _decode_term(data, pos, depth + 1, limits)
            items.append(item)
        if data[pos] == NIL:
            return items, pos + 1
        tail, pos = _decode_term(data, pos, depth + 1, limits)
        return ImproperList(items, tail), pos
    if tag == STRING:
        (n,) = struct.unpack_from(">H", data, pos + 1)
        _need(data, pos + 3 + n)
        return list(data[pos + 3 : pos + 3 + n]), pos + 3 + n
    if tag in (SMALL_TUPLE, LARGE_TUPLE):
        if tag == SMALL_TUPLE:
            n, pos = data[pos + 1], pos + 2
        else:
            (n,) = struct.unpack_from(">I", data, pos + 1)
            pos += 5
        _check_length(n, limits)
        items = []
        for _ in range(n):
            item, pos = _decode_term(data, pos, depth + 1, limits)
            items.append(item)
        return tuple(items), pos
    if tag == MAP:
        return _decode_map(data, pos, depth, limits)
    if tag in (SMALL_BIG, LARGE_BIG):
        if tag == SMALL_BIG:
            n, pos = data[pos + 1], pos + 2
        else:
            (n,) = struct.unpack_from(">I", data, pos + 1)
            pos += 5
        sign = data[pos]
        _need(data, pos + 1 + n)
        value = int.from_bytes(data[pos + 1 : pos + 1 + n], "little")
        return (-value if sign else value), pos + 1 + n
    if tag in (NEW_PID, PID):
        end = _skip_atom(data, pos + 1) + (12 if tag == NEW_PID else 9)
        _need(data, end)
        return Pid(bytes(data[pos:end])), end
    if tag in (NEWER_REFERENCE, NEW_REFERENCE):
        (n,) = struct.unpack_from(">H", data, pos + 1)
        creation = 4 if tag == NEWER_REFERENCE else 1
        end = _skip_atom(data, pos + 3) + creation + 4 * n
        _need(data, end)
        return Reference(bytes(data[pos:end])), end

    raise DecodeError(("invalid_encoding", tag))


def _decode_map(data: memoryview, pos: int, depth: int, limits: dict):
    (n,) = struct.unpack_from(">I", data, pos + 1)
    _check_length(n, limits)
    pos += 5
    result = {}
    raw_data = None
    for _ in range(n):
        key, pos = _decode_term(data, pos, depth + 1, limits)
        if key == _DATA_KEY and data[pos] == BINARY:
            # Kept as bytes until we know whether this is a Bin struct.
            (size,) = struct.unpack_from(">I", data, pos + 1)
            _need(data, pos + 5 + size)
            raw_data = bytes(data[pos + 5 : pos + 5 + size])
            result[key] = raw_data
            pos += 5 + size
        else:
            value, pos = _decode_term(data, pos, depth + 1, limits)
            result[key] = value
    if raw_data is not None:
        # A `%Portals.Codec.Bin{}` struct comes back as `bytes`.
        if n == 2 and result.get(_STRUCT_KEY) == _BIN_STRUCT:
            return raw_data, pos
        try:
            result[_DATA_KEY] = raw_data.decode("utf-8")
        except UnicodeDecodeError as err:
            raise DecodeError(("invalid_encoding", "binary is not UTF-8")) from err
    return result, pos


def _decode_atom(data: memoryview, pos: int):
    tag = data[pos]
    if tag in (SMALL_ATOM_UTF8, SMALL_ATOM):
        n, start = data[pos + 1], pos + 2
    else:
        (n,) = struct.unpack_from(">H", data, pos + 1)
        start = pos + 3
    _need(data, start + n)
    encoding = "latin-1" if tag in (SMALL_ATOM, ATOM) else "utf-8"
    return str(data[start : start + n], encoding), start + n


def _skip_atom(data: memoryview, pos: int) -> int:
    if data[pos] not in (SMALL_ATOM_UTF8, SMALL_ATOM, ATOM_UTF8, ATOM):
        raise DecodeError(("invalid_encoding", data[pos]))
    return _decode_atom(data, pos)[1]


def _need(data: memoryview, end: int) -> None:
    if end > len(data):
        raise DecodeError(("truncated", len(data)))
