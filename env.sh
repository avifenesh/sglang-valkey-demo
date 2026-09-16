# Shared settings for the SGLang + Valkey KV Indexer demo. Source, do not run.

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SGLANG_ROUTER_DIR="${SGLANG_ROUTER_DIR:-$HOME/projects/sglang/wt-kv-valkey/experimental/sgl-router}"
BIN="${BIN:-$SGLANG_ROUTER_DIR/target/release}"
RUN_DIR="${RUN_DIR:-$HOME/.cache/sglang-valkey-demo}"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/results"

IMAGE="${IMAGE:-lmsysorg/sglang:dev-cu13}"
HF_CACHE="${HF_CACHE:-/data/ai-ml/hf-models}"
MODEL="${MODEL:-Qwen/Qwen3-1.7B}"
TOKENIZER="${TOKENIZER:-$(ls -d "$HF_CACHE"/models--Qwen--Qwen3-1.7B/snapshots/*/ | head -1)tokenizer.json}"
MEM_FRACTION="${MEM_FRACTION:-0.85}"
# Two workers share one GPU: cap each KV pool (tokens) so the second still fits.
MAX_TOTAL_TOKENS="${MAX_TOTAL_TOKENS:-40000}"
PAGE_SIZE="${PAGE_SIZE:-64}"

VALKEY_PORT=6399
WORKER_PORTS=(30001 30002)
KV_EVENT_PORTS=(5701 5602)
INDEXER_MEMORY_PORT=50060
INDEXER_VALKEY_PORTS=(50051 50052)
ROUTER_PORT=8080

worker_url() { echo "http://127.0.0.1:${WORKER_PORTS[$1]}"; }

log() { printf '\033[1;36m[demo]\033[0m %s\n' "$*" >&2; }

wait_http() { # url, seconds
  local url=$1 deadline=$(( $(date +%s) + ${2:-600} ))
  until curl -sf "$url" >/dev/null 2>&1; do
    if [ "$(date +%s)" -gt "$deadline" ]; then log "timeout waiting for $url"; return 1; fi
    sleep 2
  done
}

pidfile() { echo "$RUN_DIR/$1.pid"; }

start_bg() { # name, cmd...
  local name=$1; shift
  if [ -f "$(pidfile "$name")" ] && kill -0 "$(cat "$(pidfile "$name")")" 2>/dev/null; then
    log "$name already running (pid $(cat "$(pidfile "$name")"))"; return 0
  fi
  "$@" >"$RUN_DIR/logs/$name.log" 2>&1 &
  echo $! >"$(pidfile "$name")"
  log "started $name (pid $!)"
}

stop_bg() { # name
  local f; f=$(pidfile "$1")
  if [ -f "$f" ]; then
    kill "$(cat "$f")" 2>/dev/null && log "stopped $1"
    rm -f "$f"
  fi
}
