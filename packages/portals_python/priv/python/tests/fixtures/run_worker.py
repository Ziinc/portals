#!/usr/bin/env python3
"""Entry point launched by Portals as the direct worker process (the
socket path is appended as the final CLI argument by
`Portals.Connection`). Puts this fixtures directory on `sys.path` so
`bench_worker` is importable, then runs the worker loop. The `portals`
package itself is importable because `Portals.Python.worker_opts/1` puts
the SDK on `PYTHONPATH`, exactly as for an application's worker."""

import os
import sys

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)

from portals import Worker  # noqa: E402

if __name__ == "__main__":
    Worker(
        max_concurrency=int(os.environ.get("PORTALS_MAX_CONCURRENCY", "64")),
        max_streams=int(os.environ.get("PORTALS_MAX_STREAMS", "8")),
    ).run()
