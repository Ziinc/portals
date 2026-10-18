#!/bin/sh
# Compiles the SDK, its unit tests and its fixtures into build/classes with
# plain javac (JDK 21+, no build tool or dependencies). A no-op when nothing
# changed; safe to run concurrently (the Elixir suite starts many workers at
# once), since only one caller compiles while the rest wait for it.
#
# All output goes to stderr: under the stdio transport, stdout is the
# protocol stream.
set -e

root=$(cd "$(dirname "$0")" && pwd)
build="$root/build"
out="$build/classes"
stamp="$build/.stamp"

up_to_date() {
  [ -f "$stamp" ] && [ -d "$out" ] &&
    [ -z "$(find "$root/src" "$root/test" -name '*.java' -newer "$stamp" 2>/dev/null | head -n 1)" ]
}

up_to_date && exit 0

mkdir -p "$build"
lock="$build/.lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
  # A lock older than ~2 minutes belongs to a compile that died.
  waited=$((waited + 1))
  if [ "$waited" -gt 1200 ]; then rm -rf "$lock"; waited=0; fi
  sleep 0.1
done
trap 'rmdir "$lock" 2>/dev/null' EXIT INT TERM

up_to_date && exit 0

tmp="$build/classes.tmp.$$"
rm -rf "$tmp"
mkdir -p "$tmp"
touch "$tmp.stamp"
find "$root/src" "$root/test" -name '*.java' > "$tmp.sources"
javac --release 21 -encoding UTF-8 -d "$tmp" @"$tmp.sources" 1>&2
rm -f "$tmp.sources"
rm -rf "$out"
mv "$tmp" "$out"
mv "$tmp.stamp" "$stamp"
