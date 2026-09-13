"""The Python worker runtime: connects to the BEAM's Unix socket,
completes the exact-version handshake, and dispatches `CALL` frames to
arbitrary `module.function` targets concurrently.

    from portals import Worker
    Worker().run()

The socket reader is a dedicated thread independent of call execution
(each `CALL` is submitted to a bounded thread pool), so a slow or blocked
handler can never stall reading further frames or responding to other
in-flight calls.
"""

import importlib
import logging
import platform
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

from . import protocol as p
from .errors import build_error_map
from .msgpack_codec import DecodeError, decode, encode
from .transport import ConnectionClosed, FramedSocket, FramedStdio, socket_path_from_argv

logger = logging.getLogger("portals.worker")


class Worker:
    def __init__(
        self,
        max_concurrency: int = 16,
        max_streams: int = 0,
        socket_path: Optional[str] = None,
        transport: str = "unix",
    ):
        self._max_concurrency = max_concurrency
        self._max_streams = max_streams
        self._transport_mode = transport
        self._socket_path = socket_path
        self._executor = ThreadPoolExecutor(max_workers=max_concurrency, thread_name_prefix="portals-call")
        self._limits = dict(p.DEFAULT_LIMITS)
        self._shutdown = threading.Event()
        self._conn = None

    def run(self) -> None:
        if self._transport_mode == "stdio":
            self._conn = FramedStdio()
        else:
            self._conn = FramedSocket.connect_unix(self._socket_path or socket_path_from_argv())

        self._handshake()

        try:
            while not self._shutdown.is_set():
                try:
                    payload = self._conn.recv_frame()
                except ConnectionClosed:
                    break

                if payload is None:
                    break

                self._handle_frame(payload)
        finally:
            self._executor.shutdown(wait=True)
            self._conn.close()

    # -- Handshake --------------------------------------------------------

    def _handshake(self) -> None:
        hello = [
            p.HELLO,
            p.PROTOCOL_VERSION,
            f"python{platform.python_version()}",
            self._max_concurrency,
            self._max_streams,
            [],
        ]
        self._conn.send_frame(encode(hello, self._limits))

        payload = self._conn.recv_frame()
        if payload is None:
            raise ConnectionClosed("connection closed during handshake")

        envelope, rest = decode(payload, self._limits)
        if rest != b"":
            raise ProtocolError("trailing bytes after READY")

        tag = envelope[0]
        if tag != p.READY:
            raise ProtocolError(f"expected READY, got frame tag {tag}")

        _tag, version, limits = envelope
        if version != p.PROTOCOL_VERSION:
            raise ProtocolError(
                f"protocol version mismatch: worker={p.PROTOCOL_VERSION} beam={version}"
            )

        self._limits = {**self._limits, **limits}

    # -- Frame dispatch ----------------------------------------------------

    def _handle_frame(self, payload: bytes) -> None:
        try:
            envelope, rest = decode(payload, self._limits)
        except DecodeError as exc:
            logger.warning("portals worker: dropping malformed frame: %r", exc.reason)
            return

        if rest != b"":
            logger.warning("portals worker: dropping frame with trailing bytes")
            return

        tag = envelope[0]

        if tag == p.CALL:
            self._executor.submit(self._dispatch_call, envelope[1:])
        elif tag == p.CANCEL:
            pass
        elif tag == p.PING:
            (nonce,) = envelope[1:]
            self._send([p.PONG, nonce])
        elif tag == p.PONG:
            pass
        elif tag == p.SHUTDOWN:
            self._shutdown.set()
        else:
            logger.warning("portals worker: ignoring unsupported frame tag %s", tag)

    def _dispatch_call(self, fields) -> None:
        if len(fields) == 4:
            request_id, module_name, function_name, args = fields
        else:
            request_id, module_name, function_name, args, _deadline_ms = fields

        try:
            module = importlib.import_module(module_name)
            function = getattr(module, function_name)
            result = function(*args)
        except Exception as exc:  # noqa: BLE001 - reported to the caller, not swallowed
            self._send([p.ERROR, request_id, build_error_map(exc)])
            return

        self._send([p.RETURN, request_id, result])

    def _send(self, envelope: list) -> None:
        self._conn.send_frame(encode(envelope, self._limits))


class ProtocolError(Exception):
    pass
