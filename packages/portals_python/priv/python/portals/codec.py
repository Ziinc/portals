"""The wire codec this worker speaks, chosen by the BEAM through the
PORTALS_CODEC environment variable: "etf" (the default) or "msgpack".
Handlers never see it; values arrive and leave as the same Python types
under either."""

import os

NAME = os.environ.get("PORTALS_CODEC", "etf")

if NAME == "etf":
    from .etf_codec import DecodeError, decode, encode
elif NAME == "msgpack":
    from .msgpack_codec import DecodeError, decode, encode
else:
    raise RuntimeError(f"PORTALS_CODEC={NAME!r} is not a codec this SDK speaks (etf, msgpack)")

__all__ = ["NAME", "DecodeError", "decode", "encode"]
