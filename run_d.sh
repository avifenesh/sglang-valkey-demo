#!/usr/bin/env bash
# run_d.sh — the churn variant of the bridge outage, then the rebuild proof
set -uo pipefail
source "$(dirname "$0")/env.sh"
export LOAD_ARGS="${LOAD_ARGS:---tenants 8 --prompt-words 7500 --concurrency 6}"
R="$RUN_DIR/results"

run() { # mode event duration event_at
  DURATION=$3 EVENT_AT=$4 "$DEMO_DIR/scenario2.sh" "$1" "$2" > "$RUN_DIR/logs/scenario-$1-$2.log" 2>&1 \
    && log "done $1 $2 ($(tail -1 "$R/$1-$2/load.log" | cut -c1-58))" || log "FAILED $1 $2"
}

# Memory first: it flushes Valkey at setup, so the stream run must be last for
# the rebuild proof to have a window to replay.
run memory bridge-outage-churn 180 60
run stream bridge-outage-churn 180 60
"$DEMO_DIR/rebuild.sh" > "$RUN_DIR/logs/rebuild.log" 2>&1 && log "rebuild ok" || log "rebuild FAILED"

cd "$DEMO_DIR"
python3 report.py "$R/memory-bridge-outage-churn" "$R/stream-bridge-outage-churn" --event-at 60 --duration 180 --png "$R/b3-bridge-outage.png" > "$R/b3.txt"
log "churn runs complete"
