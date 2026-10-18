#!/bin/sh
# Runs one language SDK's own unit tests with that language's tooling.
#
#     scripts/sdk_tests.sh python
set -eu

root=$(cd "$(dirname "$0")/.." && pwd)
package="$root/packages/portals_$1"

case "$1" in
  python) cd "$package/priv/python" && python3 -m unittest discover -s tests ;;
  ruby) cd "$package/priv/ruby" && ruby -Ilib -Itest -e 'Dir["test/test_*.rb"].each { |f| require File.expand_path(f) }' ;;
  javascript) cd "$package/priv/javascript/portals-worker" && node --test test/*.test.js ;;
  php) cd "$package/priv/php" && php test/run.php ;;
  java) cd "$package/priv/java" && ./test.sh ;;
  go) cd "$package/priv/go" && go vet ./... && go test ./... ;;
  *) echo "unknown language: $1" >&2; exit 1 ;;
esac
