#!/bin/sh
# Launched by Portals as the direct worker process; the socket path is
# appended as the final argument. Compiles on first use (see build.sh).
here=$(cd "$(dirname "$0")" && pwd)
"$here/../../build.sh" 1>&2 || exit 1
# PORTALS_JAVA_OPTS is a list of JVM flags, split on purpose.
# shellcheck disable=SC2086
exec java ${PORTALS_JAVA_OPTS:--XX:+UseSerialGC -XX:TieredStopAtLevel=1 -Xshare:auto} \
  -cp "$here/../../build/classes" portals.fixtures.RunWorker "$@"
