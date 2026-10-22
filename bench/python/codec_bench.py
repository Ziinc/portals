"""Python-side codec cost: encode + decode one RETURN frame carrying each
workload, in the interpreter alone (no I/O). The BEAM-side counterpart is
codecs.exs.

    .venv/bin/python python/codec_bench.py

Portals' two codecs are pure Python (the SDK has no dependencies), as is
ErlPort's; msgpack is the C extension zerorpc uses.
"""

import base64
import json
import os
import pickle
import random
import sys
import timeit

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "../../packages/portals_python/priv/python"))
sys.path.insert(0, os.path.join(HERE, "../deps/erlport/priv/python3"))

import msgpack  # noqa: E402
from erlport import erlterms  # noqa: E402

from portals import etf_codec, msgpack_codec  # noqa: E402

SENTENCE = "The quick brown fox jumps over the lazy dog. "


def workloads(text=str):
    """The same workloads as lib/bench/payloads.ex. ErlPort hands Elixir
    binaries to Python as bytes, so its text is bytes (`text=str.encode`)."""
    records = [
        {
            text("id"): i,
            text("name"): text(f"user-{i}"),
            text("email"): text(f"user{i}@example.com"),
            text("score"): i * 1.5,
            text("active"): i % 2 == 0,
            text("tags"): [text("alpha"), text("beta")],
        }
        for i in range(1, 101)
    ]
    return [
        ("small: [1, 2]", [1, 2]),
        ("1 KiB text", text((SENTENCE * 23)[:1024])),
        ("64 KiB bytes", random.Random(1).randbytes(65_536)),
        ("1 MiB bytes", random.Random(1).randbytes(1_048_576)),
        ("1,000 integers", [i * 7919 for i in range(1, 1001)]),
        ("100 records", records),
    ]


def b64(term):
    if isinstance(term, bytes):
        return base64.b64encode(term).decode()
    return term


CODECS = [
    ("Portals MessagePack (pure Python)", msgpack_codec.encode, lambda b: msgpack_codec.decode(b), str),
    ("Portals ETF (pure Python)", etf_codec.encode, lambda b: etf_codec.decode(b), str),
    ("ErlPort ETF (pure Python)", erlterms.encode, erlterms.decode, str.encode),
    (
        "msgpack (C extension)",
        lambda t: msgpack.packb(t, use_bin_type=True),
        lambda b: msgpack.unpackb(b, raw=False),
        str,
    ),
    ("pickle (protocol 5)", lambda t: pickle.dumps(t, protocol=5), pickle.loads, str),
    ("json (stdlib, bytes as base64)", lambda t: json.dumps(t).encode(), json.loads, str),
]


def measure(fn):
    timer = timeit.Timer(fn)
    number, _ = timer.autorange()
    best = min(timer.repeat(repeat=5, number=number))
    return best / number * 1e6


def main():
    names = [name for name, _ in workloads()]
    rows = []
    for codec, encode, decode, text in CODECS:
        cells = []
        for _name, payload in workloads(text):
            if codec.startswith("json"):
                payload = b64(payload)
            frame = [4, 1, payload]
            encoded = encode(frame)
            micros = measure(lambda frame=frame, encode=encode, decode=decode: decode(encode(frame)))
            cells.append(f"{micros:,.1f} µs ({len(encoded):,} B)")
        rows.append((codec, cells))
        print(f"  {codec}: done", file=sys.stderr)

    print("\n### Python codecs: encode + decode (best of 5; encoded size)\n")
    print("| Codec | " + " | ".join(names) + " |")
    print("|---|" + "---|" * len(names))
    for codec, cells in rows:
        print(f"| {codec} | " + " | ".join(cells) + " |")


if __name__ == "__main__":
    main()
