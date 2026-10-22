"""Portals worker serving `bench_handlers`: `portals_worker.py unix <socket>`
or `portals_worker.py stdio` (the codec comes from PORTALS_CODEC)."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from portals import Worker  # noqa: E402

if __name__ == "__main__":
    Worker(max_concurrency=64, transport=sys.argv[1]).run()
