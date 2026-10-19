"""Length-framed transport for the Python worker side.

Matches the BEAM's `packet: 4` / `{:packet, 4}` framing exactly: each
frame is a 4-byte big-endian length prefix followed by that many bytes of
MessagePack-encoded envelope. `FramedSocket` hides that framing so callers
only ever see whole envelopes.
"""

import socket
import struct
import sys
from typing import Optional


class ConnectionClosed(Exception):
    pass


class FramedSocket:
    def __init__(self, sock: socket.socket):
        self._sock = sock
        self._buffer = b""
        self._lock_send = __import__("threading").Lock()

    @classmethod
    def connect_unix(cls, path: str) -> "FramedSocket":
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(path)
        return cls(sock)

    def send_frame(self, payload: bytes) -> None:
        header = struct.pack(">I", len(payload))
        with self._lock_send:
            self._sock.sendall(header + payload)

    def recv_frame(self) -> Optional[bytes]:
        header = self._recv_exact(4)
        if header is None:
            return None
        (length,) = struct.unpack(">I", header)
        payload = self._recv_exact(length)
        if payload is None:
            raise ConnectionClosed("connection closed mid-frame")
        return payload

    def _recv_exact(self, n: int) -> Optional[bytes]:
        while len(self._buffer) < n:
            chunk = self._sock.recv(max(4096, n))
            if not chunk:
                if self._buffer:
                    raise ConnectionClosed("connection closed mid-frame")
                return None
            self._buffer += chunk

        data, self._buffer = self._buffer[:n], self._buffer[n:]
        return data

    def close(self) -> None:
        try:
            self._sock.close()
        except OSError:
            pass


class FramedStdio:
    """Experimental fallback transport: the same 4-byte length-prefix
    framing as `FramedSocket`, but carried over stdin/stdout instead of a
    Unix-domain socket, for platforms without Unix-socket support."""

    def __init__(self):
        self._stdin = sys.stdin.buffer
        self._stdout = sys.stdout.buffer
        self._lock_send = __import__("threading").Lock()

    def send_frame(self, payload: bytes) -> None:
        header = struct.pack(">I", len(payload))
        with self._lock_send:
            self._stdout.write(header + payload)
            self._stdout.flush()

    def recv_frame(self) -> Optional[bytes]:
        header = self._recv_exact(4)
        if header is None:
            return None
        (length,) = struct.unpack(">I", header)
        payload = self._recv_exact(length)
        if payload is None:
            raise ConnectionClosed("connection closed mid-frame")
        return payload

    def _recv_exact(self, n: int) -> Optional[bytes]:
        buf = b""
        while len(buf) < n:
            chunk = self._stdin.read(n - len(buf))
            if not chunk:
                if buf:
                    raise ConnectionClosed("connection closed mid-frame")
                return None
            buf += chunk
        return buf

    def close(self) -> None:
        pass


def socket_path_from_argv() -> str:
    if len(sys.argv) < 2:
        raise SystemExit("portals worker: expected the socket path as the last argument")
    return sys.argv[-1]
