#!/bin/sh
# Runs one Mix project's checks: formatting, compiler warnings and tests.
#
#     scripts/check_project.sh .                       # core
#     scripts/check_project.sh packages/portals_ruby   # a language package
#     scripts/check_project.sh examples/hello_live     # the example app
set -eu

cd "$1"
mix deps.get >/dev/null
mix deps.unlock --check-unused
mix format --check-formatted
env MIX_ENV=test mix compile --warnings-as-errors
mix test
