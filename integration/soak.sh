#!/usr/bin/env bash
set -euo pipefail

# Repeated fault-injection smoke against a running test MySQL on :33306.
# For a real 24-hour operating gate, run with duration 86400 in a dedicated
# staging environment; GitHub hosted jobs have much shorter runtime budgets.
duration="${1:-15}"
if ! [[ "$duration" =~ ^[0-9]+$ ]] || (( duration < 1 )); then
  echo "usage: $0 <duration-seconds>" >&2
  exit 2
fi
start="$(date +%s)"
runs=0
while (( $(date +%s) - start < duration )); do
  timeout 120s zig build stress-integration
  runs=$((runs + 1))
  echo "soak iteration $runs: 3200 concurrent operations plus 5 killed sockets passed"
done
echo "soak smoke completed: $runs stress suite iterations in $(($(date +%s) - start)) seconds"
