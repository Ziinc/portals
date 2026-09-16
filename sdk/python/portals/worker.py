"""The Python worker runtime: connects to the BEAM's Unix socket,
completes the exact-version handshake, and dispatches `CALL` frames to
arbitrary `module.function` targets concurrently.

    from portals import Worker
    Worker().run()

The socket reader is a dedicated thread independent of call execution
(each `CALL` is submitted to a bounded thread pool), so a slow or blocked
handler can never stall reading further frames or responding to other
in-flight calls.

Fully reentrant callbacks (protocol/v1.md section 8): a handler running
inside a `CALL` may call back into the BEAM with `portals.callback(...)`,
which blocks the *handler's own thread* (not the reader thread) for the
result, so a nested `CALL` dispatched back into this same worker while
the callback is outstanding is still served normally by another thread
from the pool.
"""

import importlib
import itertools
import logging
import platform
import threading
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

from . import protocol as p
from .errors import build_error_map, overload_error_map
from .msgpack_codec import DecodeError, decode, encode
from .streams import FRAME_PREFIX_BYTES as STREAM_FRAME_PREFIX_BYTES
from .streams import Stream, StreamProtocolError, is_stream_handler
from .transport import ConnectionClosed, FramedSocket, FramedStdio, socket_path_from_argv
from .values import Pid

logger = logging.getLogger("portals.worker")

_thread_local = threading.local()


class RemoteError(Exception):
    """Raised by `callback()` when the BEAM-side handler fails."""

    def __init__(self, error_map: dict):
        self.error_map = error_map
        super().__init__(error_map.get("message", "callback failed"))


class ProtocolError(Exception):
    pass


_active_worker_lock = threading.Lock()
_active_worker: Optional["Worker"] = None


def callback(module: str, function: str, args: Optional[list] = None, timeout: Optional[float] = None):
    """Invoke a BEAM callback from within a `CALL` handler and block for
    its result. Requires a `Worker` to currently be running in this
    process (there is exactly one per worker process)."""

    worker = _active_worker
    if worker is None:
        raise RuntimeError("portals.callback() called with no active Worker in this process")
    return worker.call_callback(module, function, args or [], timeout=timeout)


def send_message(target_pid: Pid, value) -> None:
    """Send a value to a BEAM PID (typically one received as a `CALL`
    argument). Fire-and-forget: no acknowledgement, no exception if the
    target no longer exists."""

    worker = _active_worker
    if worker is None:
        raise RuntimeError("portals.send_message() called with no active Worker in this process")
    worker.send_message(target_pid, value)


def current_callback_depth() -> int:
    """The reentrancy depth of the `CALL` currently executing on this
    thread (0 outside of any call)."""

    return getattr(_thread_local, "depth", 0)


class Worker:
    def __init__(
        self,
        max_concurrency: int = 16,
        max_streams: int = 8,
        socket_path: Optional[str] = None,
        transport: str = "unix",
    ):
        self._max_concurrency = max_concurrency
        self._max_streams = max_streams
        self._transport_mode = transport
        self._socket_path = socket_path
        self._executor = ThreadPoolExecutor(max_workers=max_concurrency, thread_name_prefix="portals-call")
        # Streams get their own pool so a long-lived stream handler can
        # never consume the unary concurrency this worker advertised
        # (PRD FR-5 / Phase 6 fairness).
        self._stream_executor = (
            ThreadPoolExecutor(max_workers=max_streams, thread_name_prefix="portals-stream")
            if max_streams > 0
            else None
        )
        self._limits = dict(p.DEFAULT_LIMITS)
        self._streams: dict = {}
        self._streams_lock = threading.Lock()
        self._shutdown = threading.Event()
        self._conn = None

        self._callback_id_counter = itertools.count(1)
        self._callback_lock = threading.Lock()
        self._pending_callbacks: dict = {}  # callback_id -> (Event, result_box)

    def run(self) -> None:
        global _active_worker

        if self._transport_mode == "stdio":
            self._conn = FramedStdio()
        else:
            self._conn = FramedSocket.connect_unix(self._socket_path or socket_path_from_argv())

        self._handshake()

        with _active_worker_lock:
            _active_worker = self

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
            with _active_worker_lock:
                if _active_worker is self:
                    _active_worker = None
            self._cancel_all_streams()
            self._executor.shutdown(wait=True)
            if self._stream_executor is not None:
                self._stream_executor.shutdown(wait=True)
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

    # -- Reentrant callbacks and messaging ----------------------------------

    def call_callback(self, module: str, function: str, args: list, timeout: Optional[float] = None):
        depth = current_callback_depth() + 1
        callback_id = next(self._callback_id_counter)
        event = threading.Event()
        box = {}

        with self._callback_lock:
            self._pending_callbacks[callback_id] = (event, box)

        self._send([p.CALLBACK, callback_id, module, function, args, depth])

        if not event.wait(timeout=timeout):
            with self._callback_lock:
                self._pending_callbacks.pop(callback_id, None)
            raise TimeoutError(f"callback {module}.{function} timed out")

        if box.get("ok"):
            return box["value"]
        raise RemoteError(box["error"])

    def send_message(self, target_pid: Pid, value) -> None:
        self._send([p.MESSAGE, target_pid, value])

    def _resolve_callback(self, callback_id: int, ok: bool, value=None, error=None) -> None:
        with self._callback_lock:
            entry = self._pending_callbacks.pop(callback_id, None)

        if entry is None:
            logger.warning("portals worker: unknown callback_id %s in response", callback_id)
            return

        event, box = entry
        box["ok"] = ok
        box["value"] = value
        box["error"] = error
        event.set()

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
        frame_size = len(payload) + STREAM_FRAME_PREFIX_BYTES

        if tag == p.CALL:
            self._submit_call(envelope[1:])
        elif tag == p.CANCEL:
            self._cancel_stream(envelope[1])
        elif tag == p.STREAM_DATA:
            self._handle_stream_data(envelope[1], envelope[2], frame_size)
        elif tag == p.CREDIT:
            fields = envelope[1:]
            stream_id, byte_count = fields[0], fields[1]
            frames = fields[2] if len(fields) > 2 else 1
            stream = self._stream(stream_id)
            if stream is not None:
                stream.add_send_credit(byte_count, frames)
        elif tag == p.HALF_CLOSE:
            stream = self._stream(envelope[1])
            if stream is not None:
                stream.peer_half_closed()
        elif tag == p.CALLBACK_RETURN:
            callback_id, value = envelope[1:]
            self._resolve_callback(callback_id, True, value=value)
        elif tag == p.CALLBACK_ERROR:
            callback_id, error_map = envelope[1:]
            self._resolve_callback(callback_id, False, error=error_map)
        elif tag == p.PING:
            (nonce,) = envelope[1:]
            self._send([p.PONG, nonce])
        elif tag == p.PONG:
            pass
        elif tag == p.SHUTDOWN:
            self._shutdown.set()
        else:
            logger.warning("portals worker: ignoring unsupported frame tag %s", tag)

    # -- Streaming ---------------------------------------------------------

    def _submit_call(self, fields) -> None:
        """Route a CALL to the unary pool, or — when its target is marked
        `@portals.stream_handler` — to the separate stream pool with a
        `Stream` bound to the call's request_id."""

        request_id, module_name, function_name = fields[0], fields[1], fields[2]
        function = self._resolve_quietly(module_name, function_name)

        if function is None or not is_stream_handler(function):
            self._executor.submit(self._dispatch_call, fields)
            return

        if self._stream_executor is None:
            self._send([p.ERROR, request_id, overload_error_map("worker advertises no streams")])
            return

        with self._streams_lock:
            if len(self._streams) >= self._max_streams:
                self._send(
                    [p.ERROR, request_id, overload_error_map("max_streams exceeded")]
                )
                return

            stream = Stream(
                request_id,
                self._limits["max_stream_byte_credit"],
                self._limits["max_queued_stream_frames"],
                self._conn.send_frame,
                lambda envelope: encode(envelope, self._limits),
            )
            self._streams[request_id] = stream

        grant = stream.initial_grant()
        if grant > 0:
            self._send([p.CREDIT, request_id, grant, 0])

        self._stream_executor.submit(self._dispatch_stream_call, stream, function, fields)

    @staticmethod
    def _resolve_quietly(module_name, function_name):
        try:
            return getattr(importlib.import_module(module_name), function_name)
        except Exception:  # noqa: BLE001 - the unary path reports this properly
            return None

    def _dispatch_stream_call(self, stream: Stream, function, fields) -> None:
        request_id = fields[0]
        args = fields[3]

        try:
            result = function(stream, *args)
        except Exception as exc:  # noqa: BLE001 - reported as the terminal frame
            self._release_stream(request_id)
            if not stream.cancelled:
                self._send([p.ERROR, request_id, build_error_map(exc)])
            return

        stream.half_close()
        self._release_stream(request_id)
        if not stream.cancelled:
            self._send([p.RETURN, request_id, result])

    def _stream(self, stream_id) -> Optional[Stream]:
        with self._streams_lock:
            return self._streams.get(stream_id)

    def _release_stream(self, stream_id) -> None:
        with self._streams_lock:
            self._streams.pop(stream_id, None)

    def _handle_stream_data(self, stream_id, chunk, frame_size: int) -> None:
        stream = self._stream(stream_id)
        if stream is None:
            logger.debug("portals worker: STREAM_DATA for unknown stream %s", stream_id)
            return

        try:
            stream.record_inbound(chunk, frame_size)
        except StreamProtocolError as exc:
            # A peer that exceeds its allowance loses only that stream.
            stream.cancel()
            self._release_stream(stream_id)
            self._send(
                [
                    p.ERROR,
                    stream_id,
                    {
                        "kind": "protocol",
                        "message": str(exc),
                        "details": {},
                        "remote": {"language": "python"},
                    },
                ]
            )

    def _cancel_stream(self, stream_id) -> None:
        stream = self._stream(stream_id)
        if stream is not None:
            stream.cancel()
            self._release_stream(stream_id)

    def _cancel_all_streams(self) -> None:
        with self._streams_lock:
            streams = list(self._streams.values())
            self._streams.clear()
        for stream in streams:
            stream.cancel()

    def _dispatch_call(self, fields) -> None:
        depth = 0
        deadline_ms = None

        if len(fields) == 4:
            request_id, module_name, function_name, args = fields
        elif len(fields) == 5:
            request_id, module_name, function_name, args, deadline_ms = fields
        else:
            request_id, module_name, function_name, args, deadline_ms, depth = fields

        _thread_local.depth = depth or 0

        try:
            module = importlib.import_module(module_name)
            function = getattr(module, function_name)
            result = function(*args)
        except Exception as exc:  # noqa: BLE001 - reported to the caller, not swallowed
            self._send([p.ERROR, request_id, build_error_map(exc)])
            return
        finally:
            _thread_local.depth = 0

        self._send([p.RETURN, request_id, result])

    def _send(self, envelope: list) -> None:
        self._conn.send_frame(encode(envelope, self._limits))
