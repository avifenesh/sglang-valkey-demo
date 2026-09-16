# Shared settings for the SGLang + Valkey KV Indexer demo. Source, do not run.

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Checkout of SGLang holding the router workspace, built in release mode. Set
# SGLANG_ROUTER_DIR to your own checkout, or SGLANG_DIR to the repo root.
SGLANG_DIR="${SGLANG_DIR:-$HOME/projects/sglang}"
SGLANG_ROUTER_DIR="${SGLANG_ROUTER_DIR:-$SGLANG_DIR/experimental/sgl-router}"
BIN="${BIN:-$SGLANG_ROUTER_DIR/target/release}"
RUN_DIR="${RUN_DIR:-$HOME/.cache/sglang-valkey-demo}"
mkdir -p "$RUN_DIR/logs" "$RUN_DIR/results"

IMAGE="${IMAGE:-lmsysorg/sglang:dev-cu13}"
# Hugging Face cache mounted into the worker containers. The model must already
# be there: the containers run offline (see up.sh).
HF_CACHE="${HF_CACHE:-${HF_HUB_CACHE:-$HOME/.cache/huggingface/hub}}"
MODEL="${MODEL:-Qwen/Qwen3-1.7B}"
TOKENIZER="${TOKENIZER:-$(ls -d "$HF_CACHE"/models--Qwen--Qwen3-1.7B/snapshots/*/ | head -1)tokenizer.json}"
MEM_FRACTION="${MEM_FRACTION:-0.85}"
# Two workers share one GPU: cap each KV pool (tokens) so the second still fits.
MAX_TOTAL_TOKENS="${MAX_TOTAL_TOKENS:-40000}"
PAGE_SIZE="${PAGE_SIZE:-64}"

# Ports. Every default here is offset from the usual ones so the demo can run
# beside whatever else is on the box; override any of them if they collide.
VALKEY_PORT="${VALKEY_PORT:-6399}"
WORKER_PORTS=(${WORKER_PORTS:-30001 30002})
KV_EVENT_PORTS=(${KV_EVENT_PORTS:-5701 5702})
KV_REPLAY_PORTS=(${KV_REPLAY_PORTS:-5711 5712})
# Above a bridge restart, so a bridge outage is recovered by replay instead of
# being mistaken for a worker death; below the time a provider tolerates
# routing to a dead worker.
HEARTBEAT_TTL_MS="${HEARTBEAT_TTL_MS:-30000}"
LIVENESS_SWEEP_MS="${LIVENESS_SWEEP_MS:-5000}"
INDEXER_MEMORY_PORT=50060
INDEXER_VALKEY_PORTS=(50051 50052)
INDEXER_EXTRA_PORT=50053
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

# A pidfile alone is not proof: PIDs are recycled, and killing a recycled one
# has already taken down an unrelated process here. Every pidfile is paired
# with the command line we started, and a kill only happens on a match.
running_pid() { # name -> prints the pid when it is still our process
  local f cmd pid want
  f=$(pidfile "$1")
  [ -f "$f" ] || return 1
  pid=$(cat "$f")
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] || return 1
  # Without a recorded command line, anything under our build directory counts;
  # both are exact enough that a recycled pid can never match.
  cmd="$f.cmd"
  want=$([ -f "$cmd" ] && cat "$cmd" || echo "$BIN/")
  tr '\0' ' ' < "/proc/$pid/cmdline" | grep -qF "$want" || return 1
  echo "$pid"
}

start_bg() { # name, cmd...
  local name=$1; shift
  local pid
  if pid=$(running_pid "$name"); then
    log "$name already running (pid $pid)"; return 0
  fi
  "$@" >"$RUN_DIR/logs/$name.log" 2>&1 &
  echo $! >"$(pidfile "$name")"
  echo "$1" >"$(pidfile "$name").cmd"
  log "started $name (pid $!)"
}

stop_bg() { # name
  local pid
  if pid=$(running_pid "$1"); then
    kill "$pid" 2>/dev/null && log "stopped $1 (pid $pid)"
  fi
  rm -f "$(pidfile "$1")" "$(pidfile "$1").cmd"
}

# Every binary we start lives under one build directory, so a full-path match is
# both exact and immune to PID reuse. Used at scenario setup: a leftover router
# or indexer from an earlier run would otherwise keep serving on the same port
# and quietly invalidate the results.
kill_all_ours() {
  local killed=0 pid
  for pid in $(pgrep -f "^$BIN/" 2>/dev/null); do
    kill "$pid" 2>/dev/null && killed=$((killed + 1))
  done
  [ "$killed" -gt 0 ] && log "cleared $killed leftover process(es) from $BIN"
  # Valkey is the one process not under $BIN, so down.sh still needs its pidfile
  # to stop the server this demo started.
  for pidfile in "$RUN_DIR"/*.pid "$RUN_DIR"/*.pid.cmd; do
    case "$pidfile" in *valkey.pid | *valkey.pid.cmd) continue ;; esac
    rm -f "$pidfile"
  done
  sleep 1
  pgrep -f "^$BIN/" >/dev/null 2>&1 && { log "processes survived SIGTERM; sending SIGKILL"; pkill -9 -f "^$BIN/"; sleep 1; }
  return 0
}

# The pid in the pidfile must be the process holding the port, or a stale
# listener is answering for us.
assert_port_owner() { # name, port
  local pid owner
  pid=$(running_pid "$1") || { log "$1 is not running"; return 1; }
  owner=$(ss -ltnpH "sport = :$2" 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2)
  if [ "$owner" != "$pid" ]; then
    log "port $2 is held by pid ${owner:-none}, not $1 (pid $pid)"
    return 1
  fi
}
