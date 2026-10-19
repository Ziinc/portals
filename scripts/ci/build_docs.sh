#!/bin/sh
# Builds the ExDoc docs of core and every language package, failing on any
# warning (broken references, missing files).
set -eu

root=$(cd "$(dirname "$0")/../.." && pwd)

for project in "$root" "$root"/packages/portals_*; do
  name=${project#"$root"}
  name=${name#/}
  printf '\n==> docs: %s\n' "${name:-.}"
  (cd "$project" && mix deps.get >/dev/null && mix docs --warnings-as-errors)
done
