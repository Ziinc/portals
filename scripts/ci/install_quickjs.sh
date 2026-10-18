#!/bin/sh
# Installs a pinned QuickJS-ng `qjs` binary for CI (there is no setup
# action for it) into ~/.local/bin and adds that to the job's PATH.
set -eu

version=${QUICKJS_VERSION:-v0.17.0}
bin="$HOME/.local/bin"
mkdir -p "$bin"
curl -sSfL -o "$bin/qjs" \
  "https://github.com/quickjs-ng/quickjs/releases/download/$version/qjs-linux-x86_64"
chmod +x "$bin/qjs"
echo "$bin" >> "${GITHUB_PATH:-/dev/null}"
"$bin/qjs" -e 'print(navigator.userAgent)'
