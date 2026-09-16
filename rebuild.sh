#!/usr/bin/env bash
# rebuild.sh — wipe the placement keyspace and rebuild it from the retained event stream
#
# Run after a stream-mode scenario, with no load in flight. The comparison only
# means something on a frozen world, and the order matters: the indexers go
# first (their liveness watchers would clear a worker whose heartbeat lapses
# once the bridges stop), then the bridges (the stream stops growing), and only
# then is anything read or deleted.
set -euo pipefail
source "$(dirname "$0")/env.sh"

PREFIX='{sgl-kv-indexer}:'
PROTO="$SGLANG_ROUTER_DIR/sgl-kv-indexer/proto/kv_indexer.proto"
serve_port=$INDEXER_EXTRA_PORT
out="$RUN_DIR/results/rebuild"; rm -rf "$out"; mkdir -p "$out"

query() { # endpoint, dump path
  uv run --quiet --with grpcio --with grpcio-tools --with protobuf python "$DEMO_DIR/query_indexer.py" \
    --proto "$PROTO" --endpoints "$1" --hashes-file "$out/hashes.txt" --dump "$2"
}

# A read-only server: it answers queries from the keyspace, consumes no events
# and runs no liveness watcher, so starting it changes nothing.
start_reader() {
  KV_INDEXER_BACKEND=valkey KV_INDEXER_LIVENESS=0 \
  KV_INDEXER_VALKEY_URL="valkey://127.0.0.1:$VALKEY_PORT" \
  KV_INDEXER_LISTEN_ADDR="127.0.0.1:$serve_port" \
  start_bg "indexer-$serve_port" "$BIN/kv-indexer-server"
  sleep 1
}

# With the stream frozen, "drained" is simply a keyspace that stopped growing.
wait_settled() {
  local last=-1 now stable=0
  for _ in $(seq 1 240); do
    now=$(valkey-cli -p "$VALKEY_PORT" dbsize)
    if [ "$now" = "$last" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 6 ] && return 0
    else
      stable=0
    fi
    last=$now
    sleep 0.5
  done
  log "keyspace never settled (dbsize=$last)"; return 1
}

log "freezing: indexers first, then bridges"
for port in "${INDEXER_VALKEY_PORTS[@]}" "$INDEXER_EXTRA_PORT"; do stop_bg "indexer-$port"; done
for i in 0 1; do stop_bg "bridge-$i"; done
sleep 1

log "capturing the live index"
valkey-cli -p "$VALKEY_PORT" --scan --pattern "${PREFIX}b:*" | sed 's/.*b://' | sort > "$out/hashes.txt"
hashes=$(wc -l < "$out/hashes.txt")
log "$hashes block hashes, stream length $(valkey-cli -p "$VALKEY_PORT" XLEN "${PREFIX}events"), dbsize $(valkey-cli -p "$VALKEY_PORT" dbsize)"
if [ "$hashes" -lt 50 ]; then
  log "too few placements to prove anything; run a stream scenario first"; exit 1
fi
start_reader
query "127.0.0.1:$serve_port" "$out/before.json"
stop_bg "indexer-$serve_port"

log "wiping every key except the stream"
valkey-cli -p "$VALKEY_PORT" --scan --pattern "${PREFIX}*" \
  | grep -vx "${PREFIX}events" \
  | xargs -r -n 500 valkey-cli -p "$VALKEY_PORT" DEL > /dev/null
log "keys left: $(valkey-cli -p "$VALKEY_PORT" dbsize) (the stream), placements: $(valkey-cli -p "$VALKEY_PORT" --scan --pattern "${PREFIX}b:*" | wc -l)"

group="rebuild-$(date +%s)"
log "replaying the window into the empty keyspace as group $group"
KV_INDEXER_BACKEND=valkey KV_INDEXER_EVENT_SOURCE=stream \
KV_INDEXER_CONSUMER_GROUP="$group" KV_INDEXER_STREAM_START=beginning \
KV_INDEXER_CONSUMER_NAME="rebuild-$serve_port" KV_INDEXER_LIVENESS=0 \
KV_INDEXER_VALKEY_URL="valkey://127.0.0.1:$VALKEY_PORT" \
KV_INDEXER_LISTEN_ADDR="127.0.0.1:$serve_port" \
start_bg "indexer-$serve_port" "$BIN/kv-indexer-server"
sleep 2
wait_settled
log "rebuilt: dbsize $(valkey-cli -p "$VALKEY_PORT" dbsize), placements $(valkey-cli -p "$VALKEY_PORT" --scan --pattern "${PREFIX}b:*" | wc -l)"

query "127.0.0.1:$serve_port" "$out/after.json"
stop_bg "indexer-$serve_port"
if cmp -s "$out/before.json" "$out/after.json"; then
  log "REBUILT INDEX IDENTICAL over $hashes block hashes ($(wc -c < "$out/after.json") bytes of placements)"
else
  log "rebuilt index DIFFERS; see $out/before.json vs after.json"
  diff "$out/before.json" "$out/after.json" | head -20
  exit 1
fi
