#!/usr/bin/env bash
# run_all.sh — every scenario, memory baseline against the Valkey event plane
#
# About half an hour on two workers sharing one GPU. Each run starts from a clean
# slate. Order matters twice: a stream run goes first because it is what writes
# the block-hash file the memory-mode probes read, and the rebuild proof needs a
# stream run immediately before it, since a memory run flushes Valkey.
set -uo pipefail
source "$(dirname "$0")/env.sh"
export LOAD_ARGS="${LOAD_ARGS:---tenants 8 --prompt-words 7500 --concurrency 6}"
R="$RUN_DIR/results"

run() { # mode event duration event_at
  DURATION=$3 EVENT_AT=$4 "$DEMO_DIR/event.sh" "$1" "$2" > "$RUN_DIR/logs/scenario-$1-$2.log" 2>&1 \
    && log "done $1 $2 ($(tail -1 "$R/$1-$2/load.log" | cut -c1-58))" || log "FAILED $1 $2"
}

run stream indexer-restart 180 60
run memory indexer-restart 180 60
run stream indexer-restart-ha 180 60
run stream indexer-kill-add 180 60
run memory bridge-outage-churn 180 60
run stream bridge-outage-churn 180 60
run memory worker-restart 300 60
run stream worker-restart 300 60
"$DEMO_DIR/rebuild.sh" > "$RUN_DIR/logs/rebuild.log" 2>&1 && log "rebuild ok" || log "rebuild FAILED"

cd "$DEMO_DIR"
python3 report.py "$R/memory-indexer-restart" "$R/stream-indexer-restart-ha" \
  --event-at 60 --duration 180 --png "$R/b1-indexer-restart.png" > "$R/b1.txt"
python3 report.py "$R/stream-indexer-kill-add" --event-at 60 --duration 180 \
  --png "$R/b2-indexer-kill-add.png" > "$R/b2.txt"
python3 report.py "$R/memory-bridge-outage-churn" "$R/stream-bridge-outage-churn" \
  --event-at 60 --duration 180 --png "$R/b3-bridge-outage.png" > "$R/b3.txt"
python3 report.py "$R/memory-worker-restart" "$R/stream-worker-restart" \
  --event-at 60 --duration 300 --png "$R/b4-worker-restart.png" > "$R/b4.txt"
log "all scenarios complete; results in $R"
