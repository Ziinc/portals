"""Bidirectional streaming for the Python worker SDK (protocol/v1.md §9).

A stream is opened by the BEAM as an ordinary `CALL` whose target is a
function marked with `@portals.stream_handler`; the call's `request_id`
doubles as the `stream_id`. The handler receives a `Stream` as its first
argument and runs on a dedicated stream thread pool, kept separate from
the unary call pool so long-lived streams can never exhaust the
concurrency this worker advertised for unary calls.

Backpressure is an encoded-byte credit window, independent per direction,
charged against the complete encoded frame size (4-byte length prefix
included), plus a hard cap on queued-but-unconsumed frames so a flood of
tiny frames cannot evade the byte window.
"""

import threading
from collections import deque
from typing import Any, Callable, Optional

from .protocol import CREDIT, HALF_CLOSE, STREAM_DATA

FRAME_PREFIX_BYTES = 4


class StreamClosed(Exception):
    """Raised when sending on a cancelled/terminated stream, or on a
    direction this side already half-closed."""


class StreamProtocolError(Exception):
    """The peer exceeded its documented byte or frame allowance."""


def stream_handler(fn: Callable) -> Callable:
    """Mark a function as a streaming target. The BEAM's `open_stream/5`
    dispatches to it with a `Stream` as the first argument; its return
    value becomes the stream's terminal `RETURN`."""

    fn._portals_stream_handler = True
    return fn


def is_stream_handler(fn: Any) -> bool:
    return bool(getattr(fn, "_portals_stream_handler", False))


class Stream:
    """One open bidirectional stream. Thread-safe."""

    def __init__(self, stream_id: int, max_credit: int, max_frames: int, send_frame, encode):
        self.id = stream_id
        self._max_credit = max_credit
        self._max_frames = max_frames
        self._send_frame = send_frame
        self._encode = encode

        self._cond = threading.Condition()
        self._send_credit = 0
        self._send_frames = 0
        self._recv_credit = 0
        self._recv_bytes = 0
        self._inbox = deque()
        self._outbound_open = True
        self._inbound_open = True
        self._cancelled = False

    # -- receive side ---------------------------------------------------

    def initial_grant(self) -> int:
        """Bytes to grant the BEAM up front; also the replenishment
        amount after consumption. Returns 0 when nothing is owed."""

        with self._cond:
            return self._grant_locked()

    def _grant_locked(self) -> int:
        bytes_ = self._max_credit - self._recv_credit - self._recv_bytes
        if bytes_ > 0:
            self._recv_credit += bytes_
            return bytes_
        return 0

    def record_inbound(self, chunk, frame_size: int) -> None:
        """Account for one inbound STREAM_DATA frame. Raises
        `StreamProtocolError` when the peer exceeded its allowance."""

        with self._cond:
            if not self._inbound_open:
                raise StreamProtocolError("STREAM_DATA after HALF_CLOSE")
            if len(self._inbox) >= self._max_frames:
                raise StreamProtocolError("queued stream frame limit exceeded")
            if frame_size > self._recv_credit:
                raise StreamProtocolError("stream byte credit exceeded")

            self._recv_credit -= frame_size
            self._recv_bytes += frame_size
            self._inbox.append((chunk, frame_size))
            self._cond.notify_all()

    def recv(self, timeout: Optional[float] = None):
        """Next inbound chunk, or `None` once the BEAM has half-closed
        its sending direction (or the stream was cancelled). Consuming a
        chunk is what replenishes the BEAM's credit."""

        with self._cond:
            while not self._inbox:
                if self._cancelled or not self._inbound_open:
                    return None
                if not self._cond.wait(timeout=timeout):
                    raise TimeoutError(f"stream {self.id} receive timed out")

            chunk, frame_size = self._inbox.popleft()
            self._recv_bytes -= frame_size
            grant = self._grant_locked()

        if grant > 0:
            self._credit(grant, 1)
        return chunk

    def __iter__(self):
        while True:
            chunk = self.recv()
            if chunk is None:
                return
            yield chunk

    # -- send side ------------------------------------------------------

    def send(self, chunk, timeout: Optional[float] = None) -> None:
        """Send one chunk, blocking this handler's own thread (never the
        socket reader) until the BEAM has granted enough credit."""

        payload = self._encode([STREAM_DATA, self.id, chunk])
        frame_size = len(payload) + FRAME_PREFIX_BYTES

        if frame_size > self._max_credit:
            raise StreamProtocolError(
                f"chunk of {frame_size} bytes exceeds the stream window of {self._max_credit}"
            )

        with self._cond:
            while True:
                if self._cancelled:
                    raise StreamClosed(f"stream {self.id} was cancelled")
                if not self._outbound_open:
                    raise StreamClosed(f"stream {self.id} outbound direction is half-closed")
                if self._send_frames < self._max_frames and frame_size <= self._send_credit:
                    self._send_credit -= frame_size
                    self._send_frames += 1
                    break
                if not self._cond.wait(timeout=timeout):
                    raise TimeoutError(f"stream {self.id} send timed out waiting for credit")

        self._send_frame(payload)

    def send_all(self, iterable, timeout: Optional[float] = None, half_close: bool = True) -> None:
        for chunk in iterable:
            self.send(chunk, timeout=timeout)
        if half_close:
            self.half_close()

    def half_close(self) -> None:
        """Close only this side's sending direction. Idempotent."""

        with self._cond:
            if not self._outbound_open or self._cancelled:
                return
            self._outbound_open = False
            self._cond.notify_all()

        self._send_frame(self._encode([HALF_CLOSE, self.id]))

    # -- peer events ----------------------------------------------------

    def add_send_credit(self, bytes_: int, frames: int) -> None:
        with self._cond:
            self._send_credit = min(self._send_credit + bytes_, self._max_credit)
            self._send_frames = max(self._send_frames - frames, 0)
            self._cond.notify_all()

    def peer_half_closed(self) -> None:
        with self._cond:
            self._inbound_open = False
            self._cond.notify_all()

    def cancel(self) -> None:
        """Release every piece of local state and unblock the handler."""

        with self._cond:
            self._cancelled = True
            self._outbound_open = False
            self._inbound_open = False
            self._inbox.clear()
            self._cond.notify_all()

    @property
    def cancelled(self) -> bool:
        with self._cond:
            return self._cancelled

    def _credit(self, bytes_: int, frames: int) -> None:
        self._send_frame(self._encode([CREDIT, self.id, bytes_, frames]))
