#!/usr/bin/env bash
# Runs the whole suite, or the named parts, and saves each part's output
# to results/<part>.txt along with the machine it ran on.
#
#     ./run.sh                     # everything (about 20 minutes)
#     ./run.sh rpc concurrency     # just these
#     BENCH_TIME=1 ./run.sh        # shorter runs, noisier numbers
#
# Parts: codecs python_codecs transports rpc concurrency startup.
# Needs ./setup.sh first.
set -euo pipefail
cd "$(dirname "$0")"
parts=${*:-codecs python_codecs transports rpc concurrency startup}
mkdir -p results

{
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit: $(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "os: $(uname -srm)"
  echo "cpu: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ //' || sysctl -n machdep.cpu.brand_string)"
  echo "cores: $(getconf _NPROCESSORS_ONLN)"
  echo "elixir: $(elixir --short-version)"
  echo "otp: $(erl -noshell -eval 'io:put_chars(erlang:system_info(otp_release)), halt().')"
  echo "python: $(.venv/bin/python --version)"
} > results/environment.txt
cat results/environment.txt

for part in $parts; do
  printf '\n==> %s\n' "$part"
  case $part in
    python_codecs) .venv/bin/python python/codec_bench.py ;;
    *) MIX_ENV=prod mix run "$part.exs" ;;
  esac | tee "results/$part.txt"
done
