#!/bin/sh
# Publishes core `portals` and every `portals_<language>` package to Hex at
# one version, then tags the commit. See RELEASING.md.
#
#     scripts/release.sh            # dry run: checks, tests, builds tarballs
#     scripts/release.sh --publish  # the real thing
#
# Order matters: the language packages depend on `portals ~> X.Y.Z` from
# Hex, so core is published (and resolvable) before any of them is built
# in publish mode (PORTALS_PUBLISH=1 switches their path dependency on core
# to the Hex requirement).
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
languages="python ruby javascript php java go"
publish=false
[ "${1:-}" = "--publish" ] && publish=true

section() { printf '\n==> %s\n' "$1"; }
fail() { echo "release: $*" >&2; exit 1; }

cd "$root"

section "Preflight"
[ -z "$(git status --porcelain)" ] || fail "working tree is not clean"
elixir scripts/version.exs check
version=$(sed -n 's/^  @version "\(.*\)"$/\1/p' mix.exs)
git rev-parse -q --verify "refs/tags/v$version" >/dev/null && fail "tag v$version already exists"

section "Tests"
scripts/test_all.sh

section "Java SDK jar"
(cd packages/portals_java && mix portals_java.jar)

if [ "$publish" = false ]; then
  section "Dry run: building packages"
  mkdir -p "$root/_build/release"
  mix hex.build --output "$root/_build/release/portals-$version.tar"

  for language in $languages; do
    # Core is not on Hex yet, so the path dependency on it is reported as
    # excluded; anything else (missing files, metadata) is a real error.
    output=$(cd "packages/portals_$language" && mix hex.build \
      --output "$root/_build/release/portals_$language-$version.tar" 2>&1) || true
    errors=$(printf '%s\n' "$output" | sed -n '/Stopping package build/,$p' |
      grep -v 'Stopping package build\|Dependencies excluded from the package.*: portals$' || true)
    [ -z "$errors" ] || fail "portals_$language: $errors"
    echo "portals_$language: package contents and metadata OK"
  done

  section "Dry run complete for v$version"
  echo "Run scripts/release.sh --publish to publish to Hex and tag v$version."
  exit 0
fi

section "Publishing portals $version"
mix hex.publish --yes

for language in $languages; do
  section "Publishing portals_$language $version"
  (cd "packages/portals_$language" &&
    PORTALS_PUBLISH=1 mix deps.get &&
    PORTALS_PUBLISH=1 mix hex.publish --yes &&
    git checkout -- mix.lock) # back to the monorepo's path dependency
done

section "Tagging v$version"
git tag "v$version"
git push origin "v$version"
