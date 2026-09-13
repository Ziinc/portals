"""Pure-Python MessagePack codec implementing the exact subset used by the
Portals v1 wire protocol, including the Erlang-value extensions. No
external dependency: this must be usable in a bare trusted-worker
environment. See `protocol/v1.md` and `lib/portals/codec/message_pack.ex`
(the reference implementation, which this must interoperate with
byte-for-byte).
"""

import struct
from typing import Any, List, Tuple

from .protocol import DEFAULT_LIMITS
from .values import Atom, ImproperList, Pid, Reference

EXT_TUPLE = 0
EXT_ATOM = 1
EXT_PID = 2
EXT_REFERENCE = 3
EXT_BIGINT = 4
EXT_IMPROPER_LIST = 5


class DecodeError(Exception):
    def __init__(self, reason):
        self.reason = reason
        super().__init__(repr(reason))


def encode(envelope: list, limits: dict = DEFAULT_LIMITS) -> bytes:
    body = _encode_term(envelope, 0, limits)
    if len(body) > limits["max_frame_size"]:
        raise DecodeError(("max_size_exceeded", len(body)))
    return body


def decode(data: bytes, limits: dict = DEFAULT_LIMITS) -> Tuple[list, bytes]:
    if len(data) > limits["max_frame_size"]:
        raise DecodeError(("max_size_exceeded", len(data)))
    term, rest = _decode_term(data, 0, limits)
    if not isinstance(term, list):
        term = [term]
    return term, rest


# -- Encoding -------------------------------------------------------------


def _check_depth(depth, limits):
    if depth > limits["max_nesting_depth"]:
        raise DecodeError(("max_depth_exceeded", depth))


def _check_length(n, limits):
    if n > limits["max_collection_length"]:
        raise DecodeError(("max_length_exceeded", n))


def _encode_term(term, depth, limits) -> bytes:
    _check_depth(depth, limits)

    if term is None:
        return b"\xc0"
    if term is False:
        return b"\xc2"
    if term is True:
        return b"\xc3"
    if isinstance(term, Atom):
        return _encode_ext(EXT_ATOM, term.name.encode("utf-8"))
    if isinstance(term, Pid):
        return _encode_ext(EXT_PID, term.raw)
    if isinstance(term, Reference):
        return _encode_ext(EXT_REFERENCE, term.raw)
    if isinstance(term, bool):
        raise DecodeError(("invalid_encoding", "unreachable"))
    if isinstance(term, int):
        return _encode_int(term)
    if isinstance(term, float):
        return b"\xcb" + struct.pack(">d", term)
    if isinstance(term, str):
        return _encode_string(term.encode("utf-8"))
    if isinstance(term, (bytes, bytearray)):
        return _encode_bin(bytes(term))
    if isinstance(term, tuple):
        _check_length(len(term), limits)
        payload = _encode_array(list(term), depth + 1, limits)
        return _encode_ext(EXT_TUPLE, payload)
    if isinstance(term, ImproperList):
        payload = _encode_array([term.items, term.tail], depth + 1, limits)
        return _encode_ext(EXT_IMPROPER_LIST, payload)
    if isinstance(term, dict):
        _check_length(len(term), limits)
        return _encode_map(term, depth, limits)
    if isinstance(term, list):
        _check_length(len(term), limits)
        return _encode_array(term, depth + 1, limits)

    raise DecodeError(("invalid_encoding", f"unsupported type {type(term)!r}"))


def _encode_string(bs: bytes) -> bytes:
    n = len(bs)
    if n < 32:
        return bytes([0b101_00000 | n]) + bs
    if n < 256:
        return b"\xd9" + bytes([n]) + bs
    if n < 65536:
        return b"\xda" + struct.pack(">H", n) + bs
    return b"\xdb" + struct.pack(">I", n) + bs


def _encode_bin(bs: bytes) -> bytes:
    n = len(bs)
    if n < 256:
        return b"\xc4" + bytes([n]) + bs
    if n < 65536:
        return b"\xc5" + struct.pack(">H", n) + bs
    return b"\xc6" + struct.pack(">I", n) + bs


def _encode_array(items: list, depth: int, limits: dict) -> bytes:
    n = len(items)
    header = _array_header(n)
    body = b"".join(_encode_term(item, depth, limits) for item in items)
    return header + body


def _array_header(n: int) -> bytes:
    if n < 16:
        return bytes([0b1001_0000 | n])
    if n < 65536:
        return b"\xdc" + struct.pack(">H", n)
    return b"\xdd" + struct.pack(">I", n)


def _encode_map(m: dict, depth: int, limits: dict) -> bytes:
    n = len(m)
    header = _map_header(n)
    body = b""
    for k, v in m.items():
        key_bytes = str(k).encode("utf-8")
        body += _encode_string(key_bytes) + _encode_term(v, depth + 1, limits)
    return header + body


def _map_header(n: int) -> bytes:
    if n < 16:
        return bytes([0b1000_0000 | n])
    if n < 65536:
        return b"\xde" + struct.pack(">H", n)
    return b"\xdf" + struct.pack(">I", n)


def _encode_int(n: int) -> bytes:
    if -1_099_511_627_776 <= n < 18_446_744_073_709_551_616:
        if 0 <= n < 128:
            return bytes([n])
        if -32 <= n < 0:
            return bytes([0b1110_0000 | (n + 32)])
        if 0 <= n < 256:
            return b"\xcc" + bytes([n])
        if 0 <= n < 65536:
            return b"\xcd" + struct.pack(">H", n)
        if 0 <= n < 4294967296:
            return b"\xce" + struct.pack(">I", n)
        if n >= 0:
            return b"\xcf" + struct.pack(">Q", n)
        if n >= -128:
            return b"\xd0" + struct.pack(">b", n)
        if n >= -32768:
            return b"\xd1" + struct.pack(">h", n)
        if n >= -2147483648:
            return b"\xd2" + struct.pack(">i", n)
        return b"\xd3" + struct.pack(">q", n)

    return _encode_ext(EXT_BIGINT, _encode_bigint(n))


def _encode_bigint(n: int) -> bytes:
    sign = 1 if n < 0 else 0
    mag = abs(n)
    nbytes = max(1, (mag.bit_length() + 7) // 8)
    return bytes([sign]) + mag.to_bytes(nbytes, "big")


def _encode_ext(type_code: int, payload: bytes) -> bytes:
    n = len(payload)
    fixed = {1: 0xD4, 2: 0xD5, 4: 0xD6, 8: 0xD7, 16: 0xD8}
    if n in fixed:
        return bytes([fixed[n], type_code & 0xFF]) + payload
    if n < 256:
        return b"\xc7" + bytes([n, type_code & 0xFF]) + payload
    if n < 65536:
        return b"\xc8" + struct.pack(">H", n) + bytes([type_code & 0xFF]) + payload
    return b"\xc9" + struct.pack(">I", n) + bytes([type_code & 0xFF]) + payload


# -- Decoding ---------------------------------------------------------------

_KNOWN_HEADERS = {0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8, 0xD9, 0xDA, 0xDB, 0xDC, 0xDD, 0xDE, 0xDF}


def _decode_term(data: bytes, depth: int, limits: dict):
    _check_depth(depth, limits)

    if not data:
        raise DecodeError(("truncated", 0))

    b0 = data[0]

    if b0 == 0xC0:
        return None, data[1:]
    if b0 == 0xC2:
        return False, data[1:]
    if b0 == 0xC3:
        return True, data[1:]
    if b0 < 0x80:
        return b0, data[1:]
    if b0 >= 0xE0:
        return b0 - 256, data[1:]

    if b0 == 0xCC:
        _need(data, 2, "truncated")
        return data[1], data[2:]
    if b0 == 0xCD:
        return struct.unpack(">H", _need(data, 3, "truncated")[1:3])[0], data[3:]
    if b0 == 0xCE:
        return struct.unpack(">I", _need(data, 5, "truncated")[1:5])[0], data[5:]
    if b0 == 0xCF:
        return struct.unpack(">Q", _need(data, 9, "truncated")[1:9])[0], data[9:]
    if b0 == 0xD0:
        return struct.unpack(">b", _need(data, 2, "truncated")[1:2])[0], data[2:]
    if b0 == 0xD1:
        return struct.unpack(">h", _need(data, 3, "truncated")[1:3])[0], data[3:]
    if b0 == 0xD2:
        return struct.unpack(">i", _need(data, 5, "truncated")[1:5])[0], data[5:]
    if b0 == 0xD3:
        return struct.unpack(">q", _need(data, 9, "truncated")[1:9])[0], data[9:]
    if b0 == 0xCB:
        return struct.unpack(">d", _need(data, 9, "truncated")[1:9])[0], data[9:]

    if b0 == 0xC4:
        n = _need(data, 2, "truncated")[1]
        payload = _need(data, 2 + n, "truncated")[2 : 2 + n]
        return bytes(payload), data[2 + n :]
    if b0 == 0xC5:
        n = struct.unpack(">H", _need(data, 3, "truncated")[1:3])[0]
        payload = _need(data, 3 + n, "truncated")[3 : 3 + n]
        return bytes(payload), data[3 + n :]
    if b0 == 0xC6:
        n = struct.unpack(">I", _need(data, 5, "truncated")[1:5])[0]
        payload = _need(data, 5 + n, "truncated")[5 : 5 + n]
        return bytes(payload), data[5 + n :]

    if 0b10100000 <= b0 <= 0b10111111:
        n = b0 & 0b00011111
        payload = _need(data, 1 + n, "truncated")[1 : 1 + n]
        return payload.decode("utf-8"), data[1 + n :]
    if b0 == 0xD9:
        n = _need(data, 2, "truncated")[1]
        payload = _need(data, 2 + n, "truncated")[2 : 2 + n]
        return payload.decode("utf-8"), data[2 + n :]
    if b0 == 0xDA:
        n = struct.unpack(">H", _need(data, 3, "truncated")[1:3])[0]
        payload = _need(data, 3 + n, "truncated")[3 : 3 + n]
        return payload.decode("utf-8"), data[3 + n :]
    if b0 == 0xDB:
        n = struct.unpack(">I", _need(data, 5, "truncated")[1:5])[0]
        payload = _need(data, 5 + n, "truncated")[5 : 5 + n]
        return payload.decode("utf-8"), data[5 + n :]

    if 0b10010000 <= b0 <= 0b10011111:
        n = b0 & 0b00001111
        return _decode_array(n, data[1:], depth, limits)
    if b0 == 0xDC:
        n = struct.unpack(">H", _need(data, 3, "truncated")[1:3])[0]
        return _decode_array(n, data[3:], depth, limits)
    if b0 == 0xDD:
        n = struct.unpack(">I", _need(data, 5, "truncated")[1:5])[0]
        return _decode_array(n, data[5:], depth, limits)

    if 0b10000000 <= b0 <= 0b10001111:
        n = b0 & 0b00001111
        return _decode_map(n, data[1:], depth, limits)
    if b0 == 0xDE:
        n = struct.unpack(">H", _need(data, 3, "truncated")[1:3])[0]
        return _decode_map(n, data[3:], depth, limits)
    if b0 == 0xDF:
        n = struct.unpack(">I", _need(data, 5, "truncated")[1:5])[0]
        return _decode_map(n, data[5:], depth, limits)

    ext_fixed_sizes = {0xD4: 1, 0xD5: 2, 0xD6: 4, 0xD7: 8, 0xD8: 16}
    if b0 in ext_fixed_sizes:
        n = ext_fixed_sizes[b0]
        buf = _need(data, 2 + n, "truncated")
        type_code = _signed8(buf[1])
        payload = buf[2 : 2 + n]
        return _decode_ext(type_code, bytes(payload), depth, limits), data[2 + n :]
    if b0 == 0xC7:
        n = _need(data, 2, "truncated")[1]
        buf = _need(data, 3 + n, "truncated")
        type_code = _signed8(buf[2])
        payload = buf[3 : 3 + n]
        return _decode_ext(type_code, bytes(payload), depth, limits), data[3 + n :]
    if b0 == 0xC8:
        n = struct.unpack(">H", _need(data, 3, "truncated")[1:3])[0]
        buf = _need(data, 4 + n, "truncated")
        type_code = _signed8(buf[3])
        payload = buf[4 : 4 + n]
        return _decode_ext(type_code, bytes(payload), depth, limits), data[4 + n :]
    if b0 == 0xC9:
        n = struct.unpack(">I", _need(data, 5, "truncated")[1:5])[0]
        buf = _need(data, 6 + n, "truncated")
        type_code = _signed8(buf[5])
        payload = buf[6 : 6 + n]
        return _decode_ext(type_code, bytes(payload), depth, limits), data[6 + n :]

    if b0 in _KNOWN_HEADERS:
        raise DecodeError(("truncated", len(data)))

    raise DecodeError(("invalid_encoding", b0))


def _signed8(byte_value: int) -> int:
    return byte_value - 256 if byte_value >= 128 else byte_value


def _need(data: bytes, n: int, reason: str) -> bytes:
    if len(data) < n:
        raise DecodeError((reason, len(data)))
    return data


def _decode_array(n: int, rest: bytes, depth: int, limits: dict):
    _check_length(n, limits)
    items = []
    for _ in range(n):
        item, rest = _decode_term(rest, depth + 1, limits)
        items.append(item)
    return items, rest


def _decode_map(n: int, rest: bytes, depth: int, limits: dict):
    _check_length(n, limits)
    result = {}
    for _ in range(n):
        key, rest = _decode_term(rest, depth + 1, limits)
        value, rest = _decode_term(rest, depth + 1, limits)
        result[key] = value
    return result, rest


def _decode_ext(type_code: int, payload: bytes, depth: int, limits: dict):
    if type_code == EXT_BIGINT:
        if len(payload) < 1:
            raise DecodeError(("invalid_extension", "bigint"))
        sign = payload[0]
        mag = int.from_bytes(payload[1:], "big")
        return -mag if sign == 1 else mag

    if type_code == EXT_ATOM:
        try:
            return Atom(payload.decode("utf-8"))
        except UnicodeDecodeError as exc:
            raise DecodeError(("invalid_extension", "atom")) from exc

    if type_code == EXT_PID:
        return Pid(payload)

    if type_code == EXT_REFERENCE:
        return Reference(payload)

    if type_code == EXT_TUPLE:
        items, rest = _decode_term(payload, depth + 1, limits)
        if not isinstance(items, list) or rest != b"":
            raise DecodeError(("invalid_extension", "tuple"))
        return tuple(items)

    if type_code == EXT_IMPROPER_LIST:
        pair, rest = _decode_term(payload, depth + 1, limits)
        if not isinstance(pair, list) or len(pair) != 2 or rest != b"":
            raise DecodeError(("invalid_extension", "improper_list"))
        prefix, tail = pair
        return ImproperList(prefix, tail)

    raise DecodeError(("invalid_extension", type_code))
