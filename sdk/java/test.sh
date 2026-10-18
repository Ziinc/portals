#!/bin/sh
# Runs the Java SDK's own unit tests (JDK only, no test framework).
set -e
root=$(cd "$(dirname "$0")" && pwd)
"$root/build.sh"
exec java -cp "$root/build/classes" portals.TestSupport "$@"
