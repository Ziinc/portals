import os
import sys
import threading
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from portals.msgpack_codec import encode
from portals.protocol import CREDIT, DEFAULT_LIMITS, HALF_CLOSE, STREAM_DATA
from portals.streams import (
    FRAME_PREFIX_BYTES,
    Stream,
    StreamClosed,
    StreamProtocolError,
    is_stream_handler,
    stream_handler,
)

MAX_CREDIT = 1000
MAX_FRAMES = 4


class StreamTest(unittest.TestCase):
    def setUp(self):
        self.sent = []
        self.stream = Stream(
            7,
            MAX_CREDIT,
            MAX_FRAMES,
            self.sent.append,
            lambda envelope: encode(envelope, DEFAULT_LIMITS),
        )

    def frame_size(self, chunk):
        return len(encode([STREAM_DATA, self.stream.id, chunk], DEFAULT_LIMITS)) + FRAME_PREFIX_BYTES

    # -- receive window -------------------------------------------------

    def test_initial_grant_offers_the_whole_window_once(self):
        self.assertEqual(self.stream.initial_grant(), MAX_CREDIT)
        self.assertEqual(self.stream.initial_grant(), 0)

    def test_inbound_beyond_the_granted_window_is_rejected(self):
        with self.assertRaises(StreamProtocolError):
            self.stream.record_inbound("x", 1)

        self.stream.initial_grant()
        with self.assertRaises(StreamProtocolError):
            self.stream.record_inbound("x", MAX_CREDIT + 1)

        self.stream.record_inbound("x", MAX_CREDIT)

    def test_tiny_frame_flood_hits_the_frame_limit_while_bytes_remain(self):
        self.stream.initial_grant()
        for _ in range(MAX_FRAMES):
            self.stream.record_inbound("x", 1)

        with self.assertRaises(StreamProtocolError):
            self.stream.record_inbound("x", 1)

    def test_consuming_replenishes_exactly_what_was_consumed(self):
        self.stream.initial_grant()
        self.stream.record_inbound("a", 200)
        self.stream.record_inbound("b", 300)

        self.assertEqual(self.stream.recv(), "a")
        self.assertEqual(self.sent, [encode([CREDIT, 7, 200, 1], DEFAULT_LIMITS)])

        self.assertEqual(self.stream.recv(), "b")
        self.assertEqual(len(self.sent), 2)

    def test_recv_returns_none_after_the_peer_half_closes(self):
        self.stream.initial_grant()
        self.stream.record_inbound("a", 10)
        self.stream.peer_half_closed()

        # Anything already queued is still delivered, then the iterator ends.
        self.assertEqual(self.stream.recv(), "a")
        self.assertIsNone(self.stream.recv())
        self.assertEqual(list(self.stream), [])

    def test_inbound_after_half_close_is_a_protocol_error(self):
        self.stream.initial_grant()
        self.stream.peer_half_closed()

        with self.assertRaises(StreamProtocolError):
            self.stream.record_inbound("a", 10)

    # -- send window ----------------------------------------------------

    def test_send_blocks_until_credit_arrives(self):
        size = self.frame_size("hello")
        done = threading.Event()

        def produce():
            self.stream.send("hello")
            done.set()

        thread = threading.Thread(target=produce, daemon=True)
        thread.start()

        self.assertFalse(done.wait(timeout=0.1))
        self.assertEqual(self.sent, [])

        self.stream.add_send_credit(size, 0)
        self.assertTrue(done.wait(timeout=2))
        thread.join(timeout=2)
        self.assertEqual(len(self.sent), 1)

    def test_send_is_charged_the_full_frame_size(self):
        size = self.frame_size("hello")
        self.stream.add_send_credit(size, 0)
        self.stream.send("hello")

        # The window is now exactly empty: a second send must block.
        with self.assertRaises(TimeoutError):
            self.stream.send("hello", timeout=0.05)

    def test_send_respects_the_unacknowledged_frame_limit(self):
        self.stream.add_send_credit(MAX_CREDIT, 0)
        for i in range(MAX_FRAMES):
            self.stream.send(i)

        with self.assertRaises(TimeoutError):
            self.stream.send(99, timeout=0.05)

        # Acknowledging one frame releases exactly one slot.
        self.stream.add_send_credit(0, 1)
        self.stream.send(99)
        with self.assertRaises(TimeoutError):
            self.stream.send(100, timeout=0.05)

    def test_a_chunk_larger_than_the_window_can_never_be_sent(self):
        with self.assertRaises(StreamProtocolError):
            self.stream.send("y" * (MAX_CREDIT * 2))

    # -- terminal states -------------------------------------------------

    def test_half_close_is_per_direction_and_idempotent(self):
        self.stream.initial_grant()
        self.stream.half_close()
        self.assertEqual(self.sent, [encode([HALF_CLOSE, 7], DEFAULT_LIMITS)])

        # A second half-close emits nothing more.
        self.stream.half_close()
        self.assertEqual(len(self.sent), 1)

        # The inbound direction is untouched.
        self.stream.record_inbound("still-arriving", 10)
        self.assertEqual(self.stream.recv(), "still-arriving")

        with self.assertRaises(StreamClosed):
            self.stream.send("too late")

    def test_cancel_releases_state_and_unblocks_a_parked_sender(self):
        self.stream.initial_grant()
        self.stream.record_inbound("queued", 10)

        errors = []

        def produce():
            try:
                self.stream.send("blocked")
            except StreamClosed as exc:
                errors.append(exc)

        thread = threading.Thread(target=produce, daemon=True)
        thread.start()

        self.stream.cancel()
        thread.join(timeout=2)

        self.assertEqual(len(errors), 1)
        self.assertTrue(self.stream.cancelled)
        self.assertIsNone(self.stream.recv())


class StreamHandlerMarkerTest(unittest.TestCase):
    def test_decorator_marks_and_returns_the_function(self):
        @stream_handler
        def handler(stream):
            return "ok"

        self.assertTrue(is_stream_handler(handler))
        self.assertEqual(handler(None), "ok")

    def test_plain_functions_are_not_stream_handlers(self):
        self.assertFalse(is_stream_handler(lambda: None))


if __name__ == "__main__":
    unittest.main()
