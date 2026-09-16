#!/usr/bin/env bash
# up.sh — start Valkey and two SGLang workers (docker) for the KV Indexer demo
set -euo pipefail
source "$(dirname "$0")/env.sh"

if ! valkey-cli -p "$VALKEY_PORT" ping >/dev/null 2>&1; then
  start_bg valkey valkey-server --port "$VALKEY_PORT" --save "" --appendonly no --loglevel warning
  sleep 0.5
fi
valkey-cli -p "$VALKEY_PORT" ping >/dev/null

for i in 0 1; do
  name="sgl-w$i"
  if docker ps --format '{{.Names}}' | grep -qx "$name"; then
    log "$name already running"; continue
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --restart unless-stopped --gpus all --network host --ipc host --shm-size 8g \
    -v "$HF_CACHE:/hf" -e HF_HUB_CACHE=/hf -e "HF_HUB_OFFLINE=${HF_HUB_OFFLINE:-1}" \
    "$IMAGE" python3 -m sglang.launch_server \
      --model-path "$MODEL" --host 0.0.0.0 --port "${WORKER_PORTS[$i]}" \
      --mem-fraction-static "$MEM_FRACTION" --max-total-tokens "$MAX_TOTAL_TOKENS" --page-size "$PAGE_SIZE" \
      --enable-metrics --log-level warning \
      --kv-events-config "{\"publisher\":\"zmq\",\"endpoint\":\"tcp://*:${KV_EVENT_PORTS[$i]}\",\"replay_endpoint\":\"tcp://*:${KV_REPLAY_PORTS[$i]}\",\"topic\":\"kv-events\"}" \
      >/dev/null
  log "launched $name on port ${WORKER_PORTS[$i]}, kv events on ${KV_EVENT_PORTS[$i]}"
  # Sequential: the second worker sizes its pool from what the first left free.
  log "waiting for worker $i"
  wait_http "$(worker_url $i)/health" 900 || { docker logs "$name" 2>&1 | tail -5; exit 1; }
done
log "workers healthy"
