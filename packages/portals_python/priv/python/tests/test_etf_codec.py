import unittest

from portals.etf_codec import DecodeError, decode, encode
from portals.values import Atom, ImproperList, Pid, Reference

# :erlang.term_to_binary/1 of
#   [3, 7, "héllo", %{"k" => [1, -2, 300, 2_147_483_648, -(2**70)]},
#    {:ok, nil, true, false}, 1.5, [], ~c"ab", [1 | 2],
#    %Portals.Codec.Bin{data: <<0, 255>>}]
BEAM_BYTES = bytes.fromhex(
    "836c0000000a610361076d0000000668c3a96c6c6f74000000016d000000016b6c00000005610162fffffffe"
    "620000012c6e0400000000806e09010000000000000000406a68046400026f6b6400036e696c640004747275"
    "6564000566616c7365463ff80000000000006a6b000261626c0000000161016102740000000264000a5f5f73"
    "74727563745f5f640018456c697869722e506f7274616c732e436f6465632e42696e640004646174616d0000"
    "000200ff6a"
)

BEAM_TERM = [
    3,
    7,
    "héllo",
    {"k": [1, -2, 300, 2_147_483_648, -(2**70)]},
    (Atom("ok"), None, True, False),
    1.5,
    [],
    [97, 98],
    ImproperList([1], 2),
    b"\x00\xff",
]


class EtfCodecTest(unittest.TestCase):
    def test_decodes_what_the_beam_encodes(self):
        term, rest = decode(BEAM_BYTES)
        self.assertEqual(term, BEAM_TERM)
        self.assertEqual(rest, b"")

    def test_round_trips_every_value_type(self):
        envelope = [
            4,
            1,
            {
                "none": None,
                "bools": [True, False],
                "ints": [0, 255, 256, -1, 2**31, -(2**31) - 1, 2**64, -(2**2100)],
                "float": -0.25,
                "text": "naïve ✓",
                "bytes": b"\x00\x01\xfe",
                "empty": b"",
                "atom": Atom("ok"),
                "tuple": (1, "two", (3,)),
                "improper": ImproperList([1, 2], "tail"),
                "nested": {"a": [{"b": []}]},
            },
        ]
        term, rest = decode(encode(envelope))
        self.assertEqual(term, envelope)
        self.assertEqual(rest, b"")

    def test_pids_and_references_are_opaque_and_written_back_verbatim(self):
        # self() and make_ref() from a BEAM, as NEW_PID_EXT / NEWER_REFERENCE_EXT.
        pid = bytes.fromhex("5864000d6e6f6e6f6465406e6f686f73740000005e0000000000000000")
        ref = bytes.fromhex("5a000364000d6e6f6e6f6465406e6f686f73740000000000008033634c0004263763cf")
        data = bytes([131, 108, 0, 0, 0, 2]) + pid + ref + bytes([106])
        term, _ = decode(data)
        self.assertEqual(term, [Pid(pid), Reference(ref)])
        self.assertEqual(encode(term), data)

    def test_a_data_key_outside_a_bin_struct_stays_text(self):
        term, _ = decode(encode([{Atom("data"): "x", Atom("other"): 1}]))
        self.assertEqual(term, [{"data": "x", "other": 1}])

    def test_map_keys_become_text_as_under_messagepack(self):
        # %{a: 1, 2 => 3, "s" => 4, nil => 5} from a BEAM.
        beam = bytes.fromhex("837400000004610261036400016161016400036e696c61056d00000001736104")
        term, _ = decode(beam)
        self.assertEqual(term, [{"2": 3, "a": 1, "s": 4, "": 5}])
        term, _ = decode(encode([{1: "x", Atom("k"): "y"}]))
        self.assertEqual(term, [{"1": "x", "k": "y"}])

    def test_malformed_input_raises_decode_error(self):
        for data, reason in [
            (b"", "truncated"),
            (b"\x00", "invalid_encoding"),
            (BEAM_BYTES[:-3], "truncated"),
            (bytes([131, 77]), "invalid_encoding"),
            (bytes([131, 109, 0, 0, 0, 1, 0xFF]), "invalid_encoding"),
            (bytes([131, 119, 1, 0xFF]), "invalid_encoding"),
        ]:
            with self.subTest(data=data):
                with self.assertRaises(DecodeError) as ctx:
                    decode(data)
                self.assertEqual(ctx.exception.reason[0], reason)

    def test_enforces_limits(self):
        limits = {"max_frame_size": 1024, "max_nesting_depth": 2, "max_collection_length": 3}
        with self.assertRaises(DecodeError):
            encode([[[[1]]]], limits)
        with self.assertRaises(DecodeError):
            encode([[1, 2, 3, 4]], limits)
        with self.assertRaises(DecodeError):
            encode(["x" * 2000], limits)


if __name__ == "__main__":
    unittest.main()
