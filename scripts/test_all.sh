#!/bin/sh
# Runs everything CI runs, for core and every language package: lint,
# formatting, compiler warnings, the Elixir suites (which launch real
# workers) and each SDK's own unit tests.
#
#     scripts/test_all.sh            # everything
#     scripts/test_all.sh python go  # core plus the named languages
#
# Needs elixir plus each tested language's toolchain on PATH: python3,
# ruby, node (plus bun, deno and qjs for the other JavaScript runtimes),
# php, java/javac 17+ and go. Lint (all languages only) also
# needs ruff and shellcheck.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
languages=${*:-python ruby javascript php java go}
all="python ruby javascript php java go"

section() { printf '\n==> %s\n' "$1"; }

if [ "$languages" = "$all" ]; then
  section "lint"
  "$root/scripts/lint.sh"
fi

section "portals (core)"
"$root/scripts/check_project.sh" "$root"

for language in $languages; do
  section "portals_$language"
  "$root/scripts/check_project.sh" "$root/packages/portals_$language"

  section "portals_$language: SDK unit tests"
  "$root/scripts/sdk_tests.sh" "$language"
done

# The LiveView example uses every language and needs Elixir 1.15+.
if [ "$languages" = "$all" ]; then
  if elixir -e 'System.halt(if Version.match?(System.version(), ">= 1.15.0"), do: 0, else: 1)'; then
    section "examples/hello_live"
    "$root/scripts/check_project.sh" "$root/examples/hello_live"
  else
    section "examples/hello_live: skipped (needs Elixir 1.15+)"
  fi
fi

section "OK"
