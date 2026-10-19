#!/bin/sh
# Prepares a release of core `portals` and every `portals_<language>`
# package at the version in mix.exs, and starts it. See RELEASING.md.
#
#     scripts/release.sh        # checks, tests and a Hex dry run
#     scripts/release.sh --tag  # then tags vX.Y.Z and pushes the tag
#
# Pushing the tag starts .github/workflows/release.yml, which runs CI
# (including the same dry run) and then publishes to Hex.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
tag=false
[ "${1:-}" = "--tag" ] && tag=true

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

section "Hex dry run"
scripts/hex_dry_run.sh

if [ "$tag" = false ]; then
  echo "Ready to release v$version. Run scripts/release.sh --tag to tag it and start the release workflow."
  exit 0
fi

section "Tagging v$version"
git tag "v$version"
git push origin "v$version"
echo "Pushed v$version; follow the Release workflow on GitHub Actions."
