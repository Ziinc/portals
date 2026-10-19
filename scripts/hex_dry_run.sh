#!/bin/sh
# Dry run of a Hex release: everything scripts/publish_hex.sh would publish
# is built and checked, nothing is uploaded. CI runs this on every pull
# request, and the release workflow runs it before publishing.
#
#     scripts/hex_dry_run.sh
#
# Tarballs go to _build/release/ for inspection.
#
#   * core `portals`: `mix hex.publish --dry-run`, which builds the package
#     and its docs exactly as a publish would.
#   * each `portals_<language>`: `mix hex.build` with PORTALS_PUBLISH=1, so
#     the tarball depends on `{:portals, "~> X.Y.Z"}` from Hex, as published.
#     (`hex.publish --dry-run` can't run here: it fetches dependencies, and
#     this version of core is not on Hex until the release publishes it.)
#   * every package's docs, with warnings as errors.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
languages="python ruby javascript php java go"
version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/mix.exs")
release="$root/_build/release"

section() { printf '\n==> %s\n' "$1"; }

cd "$root"
mkdir -p "$release"
elixir scripts/version.exs check

section "docs (warnings as errors)"
scripts/ci/build_docs.sh

section "portals $version"
mix hex.build --output "$release/portals-$version.tar"
# --dry-run never uploads; the placeholder key and unroutable API URL make
# sure of it even with real Hex credentials in the environment.
HEX_API_KEY=dry-run HEX_API_URL=http://127.0.0.1:9/api mix hex.publish --dry-run --yes

# The jar ships prebuilt in portals_java, so build it before packaging.
(cd packages/portals_java && mix deps.get >/dev/null && mix portals_java.jar)

for language in $languages; do
  section "portals_$language $version"
  (cd "packages/portals_$language" &&
    PORTALS_PUBLISH=1 mix hex.build --output "$release/portals_$language-$version.tar")
done

section "Dry run OK for v$version; tarballs are in _build/release"
