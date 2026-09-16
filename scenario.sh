#!/usr/bin/env bash
# scenario.sh — run the restart-under-load scenario for one indexer mode (memory|valkey)
set -euo pipefail
source "$(dirname "$0")/env.sh"

mode=${1:?memory|valkey}
duration=${DURATION:-150}
event_at=${EVENT_AT:-60}
outage=${OUTAGE:-5}
out="$RUN_DIR/results/$mode"
rm -rf "$out"; mkdir -p "$out"

# Fresh indexer state for the mode, bridges attached, router pointed at it.
"$DEMO_DIR/router.sh" stop
"$DEMO_DIR/indexer.sh" memory stop 2>/dev/null || true
"$DEMO_DIR/indexer.sh" valkey stop 2>/dev/null || true
if [ "$mode" = valkey ]; then valkey-cli -p "$VALKEY_PORT" FLUSHALL >/dev/null; fi
# Workers keep their radix caches across runs; flush them so both modes start cold.
for i in 0 1; do curl -sf -X POST "$(worker_url $i)/flush_cache" >/dev/null || true; done
"$DEMO_DIR/indexer.sh" "$mode" start
first_port=$([ "$mode" = valkey ] && echo "${INDEXER_VALKEY_PORTS[0]}" || echo "$INDEXER_MEMORY_PORT")
"$DEMO_DIR/router.sh" start "$first_port"

log "mode=$mode: load for ${duration}s, indexer server killed at ${event_at}s for ${outage}s"
python3 "$DEMO_DIR/load.py" --router "http://127.0.0.1:$ROUTER_PORT" --model "$MODEL" \
  --workers "$(worker_url 0)" "$(worker_url 1)" --duration "$duration" --out "$out" \
  ${LOAD_ARGS:-} > "$out/load.log" 2>&1 &
load_pid=$!

sleep "$event_at"
log "killing indexer server(s)"
"$DEMO_DIR/indexer.sh" "$mode" stop-server
sleep "$outage"
log "restarting indexer server(s)"
"$DEMO_DIR/indexer.sh" "$mode" start-server

wait "$load_pid"
curl -s "http://127.0.0.1:$ROUTER_PORT/metrics" | grep -E "^sgl_router_(cache_aware_decisions_total|policy_decisions_total)" > "$out/router_metrics.txt" || true
if [ "$mode" = valkey ]; then
  { valkey-cli -p "$VALKEY_PORT" dbsize; valkey-cli -p "$VALKEY_PORT" info memory | grep -E "^used_memory_human"; } > "$out/valkey.txt"
fi
tail -3 "$out/load.log"
cat "$out/router_metrics.txt"
log "results in $out"
