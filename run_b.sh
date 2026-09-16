#!/usr/bin/env bash
# run_b.sh — the four scenarios that need a rerun, plus the rebuild proof
set -uo pipefail
source "$(dirname "$0")/env.sh"
export LOAD_ARGS="${LOAD_ARGS:---tenants 8 --prompt-words 7500 --concurrency 6}"
R="$RUN_DIR/results"

run() { # mode event duration event_at
  DURATION=$3 EVENT_AT=$4 "$DEMO_DIR/scenario2.sh" "$1" "$2" > "$RUN_DIR/logs/scenario-$1-$2.log" 2>&1 \
    && log "done $1 $2" || log "FAILED $1 $2"
  docker ps --format '{{.Names}}' | grep -c sgl | xargs -I{} log "workers up after $1 $2: {}"
}

run memory bridge-outage 180 60
run stream bridge-outage 180 60
run memory worker-restart 300 60
run stream worker-restart 300 60
"$DEMO_DIR/rebuild.sh" > "$RUN_DIR/logs/rebuild.log" 2>&1 && log "rebuild ok" || log "rebuild FAILED"

cd "$DEMO_DIR"
python3 report.py "$R/memory-bridge-outage" "$R/stream-bridge-outage" --event-at 60 --duration 180 --png "$R/b3-bridge-outage.png" > "$R/b3.txt"
python3 report.py "$R/memory-worker-restart" "$R/stream-worker-restart" --event-at 60 --duration 300 --png "$R/b4-worker-restart.png" > "$R/b4.txt"
log "reruns complete"
