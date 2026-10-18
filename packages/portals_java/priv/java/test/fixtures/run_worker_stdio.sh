#!/bin/sh
# Same worker as run_worker.sh, over the framed stdio fallback transport.
here=$(cd "$(dirname "$0")" && pwd)
"$here/../../build.sh" 1>&2 || exit 1
# PORTALS_JAVA_OPTS is a list of JVM flags, split on purpose.
# shellcheck disable=SC2086
exec java ${PORTALS_JAVA_OPTS:--XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xshare:auto} \
  -cp "$here/../../build/classes" portals.fixtures.RunWorkerStdio "$@"
