#!/bin/sh
# Static checks for every language in the repository. Each check covers
# the SDK, its tests and fixtures, the guide examples and examples/.
#
#     scripts/lint.sh
#
# Needs ruff, ruby, node, php, javac, gofmt/go and shellcheck on PATH.
# Elixir formatting and warnings are checked per project by
# scripts/check_project.sh.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
failed=0

section() { printf '\n==> %s\n' "$1"; }
fail() { echo "$*" >&2; failed=1; }

# Tracked files only, so deps/ and build output are never linted.
files() { git ls-files -- "$@"; }
# Run a command over tracked files matching a pattern.
over() { pattern=$1; shift; git ls-files -z -- "$pattern" | xargs -0 "$@"; }

section "Python (ruff)"
over '*.py' ruff check || failed=1

section "Ruby (ruby -wc)"
for f in $(files '*.rb'); do
  out=$(ruby -wc "$f" 2>&1) || true
  [ "$out" = "Syntax OK" ] || fail "$f: $out"
done

section "JavaScript (node --check)"
for f in $(files '*.js' '*.cjs' '*.mjs'); do
  node --check "$f" || fail "$f"
done

section "PHP (php -l)"
for f in $(files '*.php'); do
  php -l "$f" >/dev/null || fail "$f"
done

section "Java (javac -Xlint:all -Werror)"
out=$(mktemp -d)
# `serial` is excluded: the SDK's exception classes are never serialized.
over 'packages/portals_java/priv/java/*.java' \
  javac --release 17 -encoding UTF-8 -Xlint:all,-serial -Werror -d "$out" || failed=1
rm -rf "$out"

section "Go (gofmt, go vet)"
unformatted=$(over '*.go' gofmt -l)
[ -z "$unformatted" ] || fail "not gofmt-formatted: $unformatted"
for mod in $(files '*go.mod'); do
  dir=$(dirname "$mod")
  (cd "$dir" && go vet ./...) || fail "go vet failed in $dir"
done

section "Shell (shellcheck)"
over '*.sh' shellcheck || failed=1

if [ "$failed" -ne 0 ]; then
  section "Lint failed"
  exit 1
fi
section "Lint OK"
