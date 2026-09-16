#!/usr/bin/env python3
"""A worker that advertises a protocol version the BEAM does not speak.

Used by `test/conformance/sdk_conformance_test.exs` to prove that a version
mismatch fails deterministically and identically for every bundled SDK
(protocol/v1.md section 4: the BEAM never sends READY, closes the
connection, and worker startup fails). The Ruby and Node fixtures take the
version from `PORTALS_PROTOCOL_VERSION`; the Python SDK's `Worker` has no
such knob, so this script drives the same handshake through the SDK's
public transport and codec instead of modifying the SDK.
"""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "..")))

from portals import protocol as p  # noqa: E402
from portals.msgpack_codec import encode  # noqa: E402
from portals.transport import FramedSocket, socket_path_from_argv  # noqa: E402

if __name__ == "__main__":
    version = int(os.environ.get("PORTALS_PROTOCOL_VERSION", "999"))
    conn = FramedSocket.connect_unix(socket_path_from_argv())
    conn.send_frame(encode([p.HELLO, version, "python-bad-version", 1, 0, []], p.DEFAULT_LIMITS))

    # The BEAM must close without replying; exit once it does.
    try:
        conn.recv_frame()
    except Exception:  # noqa: BLE001 - any close is the expected outcome
        pass
    finally:
        conn.close()
