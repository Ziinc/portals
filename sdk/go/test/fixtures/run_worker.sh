#!/bin/sh
# Entry point launched by Portals as the direct worker process (the socket
# path is appended as the final CLI argument by `Portals.Connection`).
#
# Go is compiled, so this builds the fixture worker in ./worker into
# sdk/go/.build on first use (and again whenever a Go source is newer than
# the binary), then execs it so the BEAM Port owns the worker process
# itself. `run_worker.sh --build-only` just builds.
set -e

here=$(cd "$(dirname "$0")" && pwd)
sdk=$(cd "$here/../.." && pwd)
bin="$sdk/.build/portals-fixture-worker"

if [ ! -x "$bin" ] || [ -n "$(find "$sdk" \( -name '*.go' -o -name go.mod \) -newer "$bin" | head -n 1)" ]; then
  mkdir -p "$sdk/.build"
  # Concurrent launches may race to build; each builds to its own file and
  # renames it into place atomically. stdout carries frames in stdio mode,
  # so build output goes to stderr.
  tmp="$bin.$$"
  (cd "$sdk" && go build -o "$tmp" ./test/fixtures/worker) >&2
  mv -f "$tmp" "$bin"
fi

if [ "$1" = "--build-only" ]; then
  exit 0
fi

exec "$bin" "$@"
