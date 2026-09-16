#!/usr/bin/env bash
# scenario2.sh — one operational event under load, for one indexer mode
#
#   scenario2.sh <memory|valkey|stream> <event>
#   events:
#     indexer-restart   rolling restart of every indexer server (1 s each), with
#                       the router pointed at one endpoint
#     indexer-restart-ha   the same rolling restart, with the router given every
#                       endpoint so it can fail over
#     indexer-kill-add  kill the first indexer for good, start a third one
#     bridge-outage     stop the bridge of worker 0 for OUTAGE seconds
#     bridge-outage-churn  the same, but flush worker 0's cache while its bridge
#                       is down, so the worker's placements really change and
#                       the events that say so are only in its replay buffer
#     worker-restart    docker restart of worker 1 (about a minute of downtime)
#
# The router always points at the last indexer server of the mode, so killing
# the first one never blinds the router; restarting the last one does, for a
# second, in every mode alike.
set -euo pipefail
source "$(dirname "$0")/env.sh"

mode=${1:?memory|valkey|stream}
event=${2:?indexer-restart|indexer-restart-ha|indexer-kill-add|bridge-outage|bridge-outage-churn|worker-restart}
duration=${DURATION:-180}
event_at=${EVENT_AT:-60}
outage=${OUTAGE:-20}
out="$RUN_DIR/results/$mode-$event"
rm -rf "$out"; mkdir -p "$out"

ports=($( case $mode in memory) echo "$INDEXER_MEMORY_PORT";; *) echo "${INDEXER_VALKEY_PORTS[@]}";; esac ))
router_port=${ports[${#ports[@]}-1]}
PROTO="$SGLANG_ROUTER_DIR/sgl-kv-indexer/proto/kv_indexer.proto"

# How much of this workload's block set the router's indexer can still answer
# for. An emptied index answers for almost none of it, whatever the TTFT says.
index_probe() { # label
  local hashes="$RUN_DIR/results/hashes.txt"
  [ -s "$hashes" ] || { log "no hashes file yet; skipping the $1 probe"; return 0; }
  # A probe that finds nothing is a result, not a failure, so no pipeline status
  # is allowed to abort the scenario.
  local line=""
  line=$( { uv run --quiet --with grpcio --with grpcio-tools --with protobuf python "$DEMO_DIR/query_indexer.py" \
    --proto "$PROTO" --endpoints "127.0.0.1:$router_port" --hashes-file "$hashes" 2>&1 \
    || echo "probe failed"; } | grep -E "placements|per-worker|probe failed" | tr '\n' ' ') || true
  echo "$1: $line" >> "$out/index_probe.txt"
  log "index after $1: $line"
}

# Fresh indexer state for the mode, bridges attached, router pointed at it.
kill_all_ours
valkey-cli -p "$VALKEY_PORT" FLUSHALL >/dev/null
for i in 0 1; do curl -sf -X POST "$(worker_url $i)/flush_cache" >/dev/null || true; done
"$DEMO_DIR/indexer.sh" "$mode" start
sleep 2
for port in "${ports[@]}"; do assert_port_owner "indexer-$port" "$port" || exit 1; done
case $event in
  # The point of this one is the router holding every endpoint.
  indexer-restart-ha) "$DEMO_DIR/router.sh" start "${ports[@]}" ;;
  *) "$DEMO_DIR/router.sh" start "$router_port" ;;
esac

log "mode=$mode event=$event: load for ${duration}s, event at ${event_at}s"
python3 "$DEMO_DIR/load.py" --router "http://127.0.0.1:$ROUTER_PORT" --model "$MODEL" \
  --workers "$(worker_url 0)" "$(worker_url 1)" --duration "$duration" --out "$out" \
  ${LOAD_ARGS:-} > "$out/load.log" 2>&1 &
load_pid=$!

sleep "$event_at"
case $event in
  indexer-restart|indexer-restart-ha)
    index_probe "before the restart"
    for port in "${ports[@]}"; do
      log "restarting indexer :$port"
      "$DEMO_DIR/indexer.sh" "$mode" stop-server "$port"; sleep 1
      "$DEMO_DIR/indexer.sh" "$mode" start-server "$port"; sleep 3
      [ "$port" = "$router_port" ] && index_probe "the restart of the router's indexer :$port"
      sleep 7
    done ;;
  indexer-kill-add)
    index_probe "before the kill"
    log "killing indexer :${ports[0]} for good"
    "$DEMO_DIR/indexer.sh" "$mode" stop-server "${ports[0]}"
    sleep 15
    log "starting a new indexer :$INDEXER_EXTRA_PORT"
    "$DEMO_DIR/indexer.sh" "$mode" start-extra-server
    sleep 5
    # The new server answers from the shared keyspace, so it is current at once.
    router_port=$INDEXER_EXTRA_PORT index_probe "the new indexer :$INDEXER_EXTRA_PORT joined" ;;
  bridge-outage)
    index_probe "before the bridge outage"
    log "stopping bridge of worker 0 for ${outage}s"
    "$DEMO_DIR/indexer.sh" "$mode" stop-bridge 0
    sleep "$outage"
    "$DEMO_DIR/indexer.sh" "$mode" start-bridge 0
    sleep 10
    index_probe "the bridge returned" ;;
  bridge-outage-churn)
    index_probe "before the bridge outage"
    log "stopping bridge of worker 0, flushing its cache, waiting ${outage}s"
    "$DEMO_DIR/indexer.sh" "$mode" stop-bridge 0
    sleep 2
    curl -sf -X POST "$(worker_url 0)/flush_cache" >/dev/null && log "worker 0 cache flushed while its bridge was down"
    sleep "$outage"
    "$DEMO_DIR/indexer.sh" "$mode" start-bridge 0
    sleep 15
    index_probe "the bridge returned" ;;
  worker-restart)
    log "restarting worker 1 (docker restart)"
    docker restart sgl-w1 >/dev/null
    wait_http "$(worker_url 1)/health" 600 && log "worker 1 back"
    # Phantom check: the worker's cache is empty right now, so every placement
    # the index still attributes to it is a stale one the router may act on.
    # The memory mode has no keys in Valkey to enumerate, so the block hashes
    # come from a file captured at the end of a stream run of the same workload.
    hashes_arg=(--hashes-from-valkey "$VALKEY_PORT" --limit 4000)
    [ -s "$RUN_DIR/results/hashes.txt" ] && hashes_arg=(--hashes-file "$RUN_DIR/results/hashes.txt")
    uv run --quiet --with grpcio --with grpcio-tools --with protobuf python "$DEMO_DIR/query_indexer.py" \
      --proto "$PROTO" --endpoints "127.0.0.1:$router_port" "${hashes_arg[@]}" 2>&1 | grep -E "placements|per-worker" > "$out/phantom.txt" || true
    log "index right after the worker returned: $(tr '\n' ' ' < "$out/phantom.txt")" ;;
  *) log "unknown event $event"; kill "$load_pid"; exit 2 ;;
esac

wait "$load_pid"
# Block hashes of this workload, for probes in modes that keep nothing in Valkey.
if [ "$mode" != memory ]; then
  valkey-cli -p "$VALKEY_PORT" --scan --pattern '{sgl-kv-indexer}:b:*' | sed 's/.*b://' | sort > "$RUN_DIR/results/hashes.txt.new"
  [ "$(wc -l < "$RUN_DIR/results/hashes.txt.new")" -gt 100 ] && mv "$RUN_DIR/results/hashes.txt.new" "$RUN_DIR/results/hashes.txt" || rm -f "$RUN_DIR/results/hashes.txt.new"
fi
curl -s "http://127.0.0.1:$ROUTER_PORT/metrics" | grep -E "^sgl_router_(cache_aware_decisions_total|policy_decisions_total)" > "$out/router_metrics.txt" || true
{ valkey-cli -p "$VALKEY_PORT" dbsize; valkey-cli -p "$VALKEY_PORT" info memory | grep -E "^used_memory_human"; valkey-cli -p "$VALKEY_PORT" XLEN "{sgl-kv-indexer}:events" 2>/dev/null; } > "$out/valkey.txt" 2>/dev/null || true
echo "$event_at" > "$out/event_at"
tail -2 "$out/load.log"
cat "$out/router_metrics.txt"
log "results in $out"
