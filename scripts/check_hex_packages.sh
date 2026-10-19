#!/bin/sh
# Builds every Hex tarball without publishing, to validate each package's
# metadata and file list. Tarballs go to _build/release/.
#
#     scripts/check_hex_packages.sh
#
# Before core is on Hex, a language package's path dependency on it is
# reported as excluded; that is expected, anything else is an error.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
languages="python ruby javascript php java go"
version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/mix.exs")
mkdir -p "$root/_build/release"

cd "$root"
mix deps.get >/dev/null
mix hex.build --output "$root/_build/release/portals-$version.tar"

# The jar ships prebuilt in portals_java, so build it before packaging.
(cd packages/portals_java && mix deps.get >/dev/null && mix portals_java.jar)

for language in $languages; do
  output=$(cd "packages/portals_$language" && mix deps.get >/dev/null && mix hex.build \
    --output "$root/_build/release/portals_$language-$version.tar" 2>&1) || true
  errors=$(printf '%s\n' "$output" | sed -n '/Stopping package build/,$p' |
    grep -v 'Stopping package build\|Dependencies excluded from the package.*: portals$' || true)
  if [ -n "$errors" ]; then
    echo "portals_$language: $errors" >&2
    exit 1
  fi
  echo "portals_$language: package contents and metadata OK"
done
