#!/usr/bin/env bash
# indexer.sh — start|stop|restart the KV Indexer (memory|valkey|stream) and its bridges
#
#   memory  one in-memory indexer, bridges send gRPC to it
#   valkey  two Valkey-backed indexers, bridges send gRPC to the first
#   stream  two Valkey-backed indexers consuming the event stream under a lease;
#           bridges XADD to the stream, heartbeat, and replay from the worker buffer
set -euo pipefail
source "$(dirname "$0")/env.sh"

mode=${1:?memory|valkey|stream}
action=${2:?start|stop|restart|stop-server|start-server|stop-bridge|start-bridge|start-extra-server|stop-extra-server}
arg=${3:-}

server_ports() {
  case $mode in
    memory) echo "$INDEXER_MEMORY_PORT" ;;
    valkey|stream) echo "${INDEXER_VALKEY_PORTS[@]}" ;;
    *) log "unknown mode $mode"; exit 2 ;;
  esac
}

start_server() { # port
  local port=$1
  case $mode in
    memory)
      KV_INDEXER_LISTEN_ADDR="127.0.0.1:$port" \
      start_bg "indexer-$port" "$BIN/kv-indexer-server" ;;
    valkey)
      KV_INDEXER_BACKEND=valkey \
      KV_INDEXER_VALKEY_URL="valkey://127.0.0.1:$VALKEY_PORT" \
      KV_INDEXER_LIVENESS=0 \
      KV_INDEXER_LISTEN_ADDR="127.0.0.1:$port" \
      start_bg "indexer-$port" "$BIN/kv-indexer-server" ;;
    stream)
      KV_INDEXER_BACKEND=valkey \
      KV_INDEXER_EVENT_SOURCE=stream \
      KV_INDEXER_CONSUMER_NAME="indexer-$port" \
      KV_INDEXER_VALKEY_URL="valkey://127.0.0.1:$VALKEY_PORT" \
      KV_INDEXER_LIVENESS_SWEEP_MS="$LIVENESS_SWEEP_MS" \
      KV_INDEXER_LISTEN_ADDR="127.0.0.1:$port" \
      start_bg "indexer-$port" "$BIN/kv-indexer-server" ;;
  esac
}

start_servers() {
  for port in $(server_ports); do start_server "$port"; done
  sleep 0.5
}

stop_servers() {
  for port in $(server_ports); do stop_bg "indexer-$port"; done
}

# gRPC bridges follow the first server; stream bridges need no server at all.
start_bridge() { # index
  local i=$1
  local first; first=$(server_ports | awk '{print $1}')
  case $mode in
    memory|valkey)
      KV_INDEXER_WORKER_ID="worker-$i" \
      KV_INDEXER_WORKER_ADDRESS="$(worker_url $i)" \
      KV_INDEXER_ENDPOINT="http://127.0.0.1:$first" \
      SGLANG_KV_EVENT_ENDPOINT="tcp://127.0.0.1:${KV_EVENT_PORTS[$i]}" \
      SGLANG_KV_EVENT_TOPIC="kv-events" \
      start_bg "bridge-$i" "$BIN/kv-indexer-bridge" ;;
    stream)
      KV_INDEXER_WORKER_ID="worker-$i" \
      KV_INDEXER_WORKER_ADDRESS="$(worker_url $i)" \
      KV_INDEXER_SINK=stream \
      KV_INDEXER_VALKEY_URL="valkey://127.0.0.1:$VALKEY_PORT" \
      KV_INDEXER_HEARTBEAT_TTL_MS="$HEARTBEAT_TTL_MS" \
      SGLANG_KV_EVENT_ENDPOINT="tcp://127.0.0.1:${KV_EVENT_PORTS[$i]}" \
      SGLANG_KV_REPLAY_ENDPOINT="tcp://127.0.0.1:${KV_REPLAY_PORTS[$i]}" \
      SGLANG_KV_EVENT_TOPIC="kv-events" \
      start_bg "bridge-$i" "$BIN/kv-indexer-bridge" ;;
  esac
}

start_bridges() { for i in 0 1; do start_bridge "$i"; done; }
stop_bridges() { for i in 0 1; do stop_bg "bridge-$i"; done; }

case $action in
  start) start_servers; start_bridges ;;
  stop) stop_bridges; stop_servers; stop_bg "indexer-$INDEXER_EXTRA_PORT" ;;
  restart) stop_bridges; stop_servers; sleep 1; start_servers; start_bridges ;;
  stop-server) if [ -n "$arg" ]; then stop_bg "indexer-$arg"; else stop_servers; fi ;;
  start-server) if [ -n "$arg" ]; then start_server "$arg"; else start_servers; fi ;;
  start-extra-server) start_server "$INDEXER_EXTRA_PORT" ;;
  stop-extra-server) stop_bg "indexer-$INDEXER_EXTRA_PORT" ;;
  stop-bridge) stop_bg "bridge-${arg:?bridge index}" ;;
  start-bridge) start_bridge "${arg:?bridge index}" ;;
  *) log "unknown action $action"; exit 2 ;;
esac
