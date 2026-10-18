#!/bin/sh
# Same worker as `run_worker.sh`, over the framed stdio fallback transport.
here=$(cd "$(dirname "$0")" && pwd)
PORTALS_TRANSPORT=stdio PORTALS_MAX_CONCURRENCY=16 exec sh "$here/run_worker.sh" "$@"
