#!/usr/bin/env bash
# down.sh — stop everything the demo started (router, indexers, bridges, workers, valkey)
set -uo pipefail
source "$(dirname "$0")/env.sh"

stop_bg router
for i in 0 1; do stop_bg "bridge-$i"; done
for port in "$INDEXER_MEMORY_PORT" "${INDEXER_VALKEY_PORTS[@]}"; do stop_bg "indexer-$port"; done
for i in 0 1; do docker rm -f "sgl-w$i" >/dev/null 2>&1 && log "removed sgl-w$i"; done
stop_bg valkey
log "down"
