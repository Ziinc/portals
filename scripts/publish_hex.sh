#!/bin/sh
# Publishes core `portals` and every `portals_<language>` package, with their
# docs, to Hex at the version in mix.exs. The release workflow
# (.github/workflows/release.yml) runs this when a vX.Y.Z tag is pushed; see
# RELEASING.md.
#
#     HEX_API_KEY=... scripts/publish_hex.sh
#
# Safe to re-run after a partial failure: a package whose version is already
# on Hex is skipped.
#
# Order matters: the language packages depend on `portals ~> X.Y.Z` from
# Hex, so core is published (and resolvable) before any of them is built in
# publish mode (PORTALS_PUBLISH=1 switches their path dependency on core to
# the Hex requirement).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
languages="python ruby javascript php java go"
version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' "$root/mix.exs")

section() { printf '\n==> %s\n' "$1"; }
fail() { echo "publish: $*" >&2; exit 1; }

# 0 when $1 $version is on Hex, 1 when it isn't.
on_hex() {
  status=$(curl -sS -o /dev/null -w '%{http_code}' "https://hex.pm/api/packages/$1/releases/$version") ||
    fail "could not reach hex.pm"
  case $status in
    200) return 0 ;;
    404) return 1 ;;
    *) fail "hex.pm answered HTTP $status for $1 $version" ;;
  esac
}

cd "$root"
elixir scripts/version.exs check

section "portals $version"
if on_hex portals; then
  echo "already on Hex, skipping"
else
  mix deps.get
  mix hex.publish --yes
fi

# The jar ships prebuilt in portals_java, so build it before packaging.
(cd packages/portals_java && mix deps.get >/dev/null && mix portals_java.jar)

for language in $languages; do
  section "portals_$language $version"
  if on_hex "portals_$language"; then
    echo "already on Hex, skipping"
    continue
  fi

  cd "packages/portals_$language"
  # A just-published core can take a little while to reach the registry.
  attempt=1
  until PORTALS_PUBLISH=1 mix deps.get; do
    [ "$attempt" -lt 30 ] || fail "portals $version did not become resolvable on Hex"
    echo "waiting for portals $version on the Hex registry (attempt $attempt)"
    attempt=$((attempt + 1))
    sleep 20
  done
  PORTALS_PUBLISH=1 mix hex.publish --yes
  git checkout -- mix.lock # back to the monorepo's path dependency
  cd "$root"
done

section "Published v$version"
