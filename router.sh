#!/usr/bin/env bash
# router.sh — start|stop sgl-router in cache_aware mode against an indexer endpoint
set -euo pipefail
source "$(dirname "$0")/env.sh"

action=${1:?start|stop}
shift || true
# Every remaining argument is an indexer port; the router prefers the first and
# fails over to the rest.
indexer_ports=("$@")

case $action in
  start)
    [ "${#indexer_ports[@]}" -gt 0 ] || { log "at least one indexer port is required"; exit 2; }
    endpoints=()
    for port in "${indexer_ports[@]}"; do endpoints+=("http://127.0.0.1:$port"); done
    RUST_LOG="${RUST_LOG:-info}" start_bg router "$BIN/sgl-router" \
      --host 127.0.0.1 --port "$ROUTER_PORT" \
      --model-id "$MODEL" --tokenizer-path "$TOKENIZER" \
      --worker-urls "$(worker_url 0)" "$(worker_url 1)" \
      --policy cache_aware --cache-prefix-provider indexer \
      --kv-indexer-endpoint "${endpoints[@]}" \
      --kv-indexer-query-timeout-ms 100
    wait_http "http://127.0.0.1:$ROUTER_PORT/readyz" 60 || { tail -20 "$RUN_DIR/logs/router.log"; exit 1; }
    assert_port_owner router "$ROUTER_PORT" || { tail -20 "$RUN_DIR/logs/router.log"; exit 1; }
    log "router healthy on $ROUTER_PORT (indexers: ${indexer_ports[*]})"
    ;;
  stop) stop_bg router ;;
  *) log "unknown action $action"; exit 2 ;;
esac
