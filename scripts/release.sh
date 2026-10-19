#!/bin/sh
# Checks that main is ready to release at the version in mix.exs: a clean
# tree, matching version locations, no existing tag, every test, and the
# Hex dry run. Publish by creating the vX.Y.Z GitHub release; see
# CONTRIBUTING.md.
#
#     scripts/release.sh
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)

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

section "Ready: create the v$version GitHub release on main to publish it"
