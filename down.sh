#!/usr/bin/env bash
# down.sh — stop everything the demo started (router, indexers, bridges, workers, valkey)
set -uo pipefail
source "$(dirname "$0")/env.sh"

kill_all_ours
for i in 0 1; do docker rm -f "sgl-w$i" >/dev/null 2>&1 && log "removed sgl-w$i"; done
stop_bg valkey
log "down"
