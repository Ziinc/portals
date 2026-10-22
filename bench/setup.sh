#!/bin/sh
# Creates bench/.venv with the comparators' Python packages (zerorpc,
# msgpack, pyzmq) and fetches the Elixir dependencies. Every Python process
# in the suite, the Portals workers included, runs on this interpreter.
set -eu
cd "$(dirname "$0")"
python3 -m venv .venv
.venv/bin/pip install --quiet --requirement python/requirements.txt
mix deps.get
