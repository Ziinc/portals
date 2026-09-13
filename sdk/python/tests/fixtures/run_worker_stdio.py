#!/usr/bin/env python3
"""Same as `run_worker.py`, but uses the framed-stdio fallback transport
instead of connecting to a Unix-domain socket."""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "..")))

from portals import Worker  # noqa: E402

if __name__ == "__main__":
    Worker(max_concurrency=64, transport="stdio").run()
