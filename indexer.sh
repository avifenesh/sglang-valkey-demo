#!/usr/bin/env bash
# indexer.sh — start|stop|restart the KV Indexer (memory or valkey) and its bridges
set -euo pipefail
source "$(dirname "$0")/env.sh"

mode=${1:?memory|valkey}
action=${2:?start|stop|restart|stop-server|start-server}

server_ports() {
  case $mode in
    memory) echo "$INDEXER_MEMORY_PORT" ;;
    valkey) echo "${INDEXER_VALKEY_PORTS[@]}" ;;
    *) log "unknown mode $mode"; exit 2 ;;
  esac
}

start_servers() {
  for port in $(server_ports); do
    if [ "$mode" = valkey ]; then
      KV_INDEXER_BACKEND=valkey \
      KV_INDEXER_VALKEY_URL="valkey://127.0.0.1:$VALKEY_PORT" \
      KV_INDEXER_LISTEN_ADDR="127.0.0.1:$port" \
      start_bg "indexer-$port" "$BIN/kv-indexer-server"
    else
      KV_INDEXER_LISTEN_ADDR="127.0.0.1:$port" \
      start_bg "indexer-$port" "$BIN/kv-indexer-server"
    fi
  done
  sleep 0.5
}

stop_servers() {
  for port in $(server_ports); do stop_bg "indexer-$port"; done
}

# Bridges follow the first server; a bridge is per worker event stream.
start_bridges() {
  local first; first=$(server_ports | awk '{print $1}')
  for i in 0 1; do
    KV_INDEXER_WORKER_ID="worker-$i" \
    KV_INDEXER_WORKER_ADDRESS="$(worker_url $i)" \
    KV_INDEXER_ENDPOINT="http://127.0.0.1:$first" \
    SGLANG_KV_EVENT_ENDPOINT="tcp://127.0.0.1:${KV_EVENT_PORTS[$i]}" \
    SGLANG_KV_EVENT_TOPIC="kv-events" \
    start_bg "bridge-$i" "$BIN/kv-indexer-bridge"
  done
}

stop_bridges() { for i in 0 1; do stop_bg "bridge-$i"; done; }

case $action in
  start) start_servers; start_bridges ;;
  stop) stop_bridges; stop_servers ;;
  restart) stop_bridges; stop_servers; sleep 1; start_servers; start_bridges ;;
  stop-server) stop_servers ;;
  start-server) start_servers ;;
  *) log "unknown action $action"; exit 2 ;;
esac
