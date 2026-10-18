#!/bin/sh
# Runs everything CI should run, for core and every language package:
# formatting, compiler warnings, the Elixir suites (which launch real
# workers) and each SDK's own unit tests.
#
#     scripts/test_all.sh            # everything
#     scripts/test_all.sh python go  # core plus the named languages
#
# Needs elixir plus each tested language's toolchain on PATH: python3,
# ruby, node, php, java/javac 17+ and go.
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
languages=${*:-python ruby node php java go}

section() { printf '\n==> %s\n' "$1"; }

mix_checks() {
  (cd "$1" && mix deps.get >/dev/null && mix format --check-formatted &&
    MIX_ENV=test mix compile --warnings-as-errors && mix test)
}

section "portals (core)"
mix_checks "$root"

for language in $languages; do
  package="$root/packages/portals_$language"
  section "portals_$language"
  mix_checks "$package"

  section "portals_$language: SDK unit tests"
  case "$language" in
    python) (cd "$package/priv/python" && python3 -m unittest discover -s tests) ;;
    ruby) (cd "$package/priv/ruby" && ruby -Ilib -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }') ;;
    node) (cd "$package/priv/node/portals-worker" && node --test test/*.test.js) ;;
    php) (cd "$package/priv/php" && php test/run.php) ;;
    java) (cd "$package/priv/java" && ./test.sh) ;;
    go) (cd "$package/priv/go" && go vet ./... && go test ./...) ;;
    *) echo "unknown language: $language" >&2; exit 1 ;;
  esac
done

section "OK"
