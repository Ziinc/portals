import os
import sys
import unittest

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

from portals.msgpack_codec import DecodeError, decode, encode
from portals.protocol import CALL, DEFAULT_LIMITS, HELLO, RETURN
from portals.values import Atom, ImproperList, Pid, Reference


class MessagePackCodecTest(unittest.TestCase):
    def round_trip(self, envelope):
        encoded = encode(envelope, DEFAULT_LIMITS)
        decoded, rest = decode(encoded, DEFAULT_LIMITS)
        self.assertEqual(rest, b"")
        return decoded

    def test_primitives(self):
        self.assertEqual(self.round_trip([None, True, False]), [None, True, False])

    def test_ints_including_bigints(self):
        values = [0, 1, 127, 128, 255, 256, 65535, 65536, -1, -32, -33, -128, -129, -32768, -32769]
        self.assertEqual(self.round_trip(values), values)

        huge = 170141183460469231731687303715884105728
        self.assertEqual(self.round_trip([huge, -huge]), [huge, -huge])

    def test_float(self):
        self.assertEqual(self.round_trip([1.5]), [1.5])

    def test_str_and_bytes_are_distinct(self):
        decoded = self.round_trip(["hello", b"\x00\x01\x02"])
        self.assertEqual(decoded[0], "hello")
        self.assertIsInstance(decoded[0], str)
        self.assertEqual(decoded[1], b"\x00\x01\x02")
        self.assertIsInstance(decoded[1], bytes)

    def test_tuple(self):
        decoded = self.round_trip([(1, "a", None)])
        self.assertEqual(decoded, [(1, "a", None)])

    def test_atom(self):
        decoded = self.round_trip([Atom("ok")])
        self.assertEqual(decoded, [Atom("ok")])

    def test_pid_and_reference_are_opaque_round_trip(self):
        pid = Pid(b"\x83pid_bytes")
        ref = Reference(b"\x83ref_bytes")
        self.assertEqual(self.round_trip([pid, ref]), [pid, ref])

    def test_improper_list(self):
        decoded = self.round_trip([ImproperList([1, 2], Atom("tail"))])
        self.assertEqual(decoded, [ImproperList([1, 2], Atom("tail"))])

    def test_nested_map(self):
        term = {"a": 1, "b": [1, 2, 3], "c": {"nested": True}}
        self.assertEqual(self.round_trip([term]), [term])

    def test_call_and_hello_envelope_shapes(self):
        hello = [HELLO, 1, "python3.11", 16, 0, []]
        self.assertEqual(self.round_trip(hello), hello)

        call = [CALL, 1, "bench_worker", "echo", ["hello"]]
        self.assertEqual(self.round_trip(call), call)

    def test_max_frame_size_enforced(self):
        tight = {**DEFAULT_LIMITS, "max_frame_size": 4}
        with self.assertRaises(DecodeError):
            encode(["much too long a string"], tight)

    def test_truncated_frame_raises_decode_error_not_generic_exception(self):
        with self.assertRaises(DecodeError) as ctx:
            decode(b"\x91", DEFAULT_LIMITS)
        self.assertEqual(ctx.exception.reason[0], "truncated")

    def test_return_envelope_round_trip(self):
        envelope = [RETURN, 42, {"ok": True}]
        self.assertEqual(self.round_trip(envelope), envelope)


if __name__ == "__main__":
    unittest.main()
