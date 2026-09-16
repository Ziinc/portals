#!/usr/bin/env python3
"""Entry point launched by Portals as the direct worker process (the
socket path is appended as the final CLI argument by
`Portals.Connection`). Puts this fixtures directory and the `portals`
package directory on `sys.path` so `bench_worker` and `portals` are both
importable, then runs the worker loop."""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
sys.path.insert(0, os.path.abspath(os.path.join(_HERE, "..", "..")))

from portals import Worker  # noqa: E402

if __name__ == "__main__":
    Worker(
        max_concurrency=int(os.environ.get("PORTALS_MAX_CONCURRENCY", "64")),
        max_streams=int(os.environ.get("PORTALS_MAX_STREAMS", "8")),
    ).run()
