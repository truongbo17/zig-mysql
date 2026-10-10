#!/usr/bin/env bash
set -euo pipefail

# Run a single Zig process/pool for the entire requested soak duration.
# Repeated zig build invocations are NOT a valid memory/connection leak soak.
duration="${1:-15}"
if ! [[ "$duration" =~ ^[0-9]+$ ]] || (( duration < 1 || duration > 86400 )); then
  echo "usage: $0 <duration-seconds: 1..86400>" >&2
  exit 2
fi

# Allow enough time for the final 1280-operation wave and connection cleanup.
# CI invokes this script under an independent timeout as well.
SOAK_SECONDS="$duration" timeout "$((duration + 120))s" zig build soak-integration
