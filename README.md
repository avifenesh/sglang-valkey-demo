# SGLang KV Indexer on Valkey: restart-safe cache-aware routing

SGLang's router can route each request to the worker that already holds the
longest prefix of its KV cache. In a fleet, that placement knowledge lives in the
KV Indexer, a gRPC service fed by every worker's KV events. Until now the Indexer
kept its index in process memory: one server per deployment, and a restart or
deploy blanked the index. Hot prefixes (system prompts, tool schemas) are stored
once at worker start and never re-emitted, so a fresh Indexer never learns them.
The router falls back to load-based routing, half the requests land on a worker
without the prefix, and time to first token jumps until every worker has
recomputed every prefix.

This demo runs the same workload twice: once with the in-memory Indexer and once
with the Indexer backed by Valkey, and kills the Indexer server mid-run in both.

## What runs

```text
load.py  ->  sgl-router (cache_aware, prefix provider = indexer)  ->  2x SGLang workers (Qwen3-1.7B, one RTX 5090)
                    |                                                       |
                    | gRPC MatchExternalKvPrefix                            | ZMQ KV events (BlockStored / BlockRemoved)
                    v                                                       v
             kv-indexer-server  <------------ gRPC ApplyExternalKvBatch -- kv-indexer-bridge (one per worker)
                    |
                    +-- memory:  index dies with the process
                    +-- valkey:  index in a Valkey keyspace, server is stateless
```

- 12 tenants, each with its own system prompt of about 2k tokens, short
  questions, 6 concurrent clients, closed loop.
- `load.py` records time to first token per request and scrapes each worker's
  `sglang:cached_tokens_total` / `sglang:prompt_tokens_total` to compute the
  prefix cache hit ratio per 10 second window.
- At 60 s the Indexer server is killed; at 65 s it is started again with the
  same backend.

## Run

Needs docker with the NVIDIA runtime, `valkey-server` on `PATH`, `uv` (for the
gRPC probe), and one GPU with room for two small workers.

Point it at your own checkout and cache, then build the binaries:

```sh
export SGLANG_DIR=~/src/sglang          # or SGLANG_ROUTER_DIR directly
export HF_CACHE=~/.cache/huggingface/hub # must already hold MODEL
(cd "$SGLANG_DIR/experimental/sgl-router" && cargo build --release -p sgl-router -p sgl-kv-indexer)
```

`env.sh` holds the rest and every value is overridable: `MODEL`,
`MAX_TOTAL_TOKENS`, `MEM_FRACTION`, `VALKEY_PORT`, `WORKER_PORTS`,
`KV_EVENT_PORTS`, `KV_REPLAY_PORTS`, `HEARTBEAT_TTL_MS`. The workers run with
`HF_HUB_OFFLINE=1`, so pull the model first. The stage-B scenarios need the
`pr-kv-indexer-event-plane` branch (upstream PRs sgl-project/sglang#39785 and
#39822); the stage-A ones only need #39785.

```sh
./up.sh                      # valkey + two workers, waits for health
./scenario.sh memory         # ~2.5 min
./scenario.sh valkey         # ~2.5 min
python3 report.py ~/.cache/sglang-valkey-demo/results/memory ~/.cache/sglang-valkey-demo/results/valkey \
  --event-at 60 --png results.png
./down.sh
```

`indexer.sh valkey start` brings up two Indexer servers over the same keyspace;
the router is pointed at the first. `KV_INDEXER_BACKEND=valkey` and
`KV_INDEXER_VALKEY_URL` are the only server-side differences from the in-memory
run.

## Stage B: Valkey as the placement and event plane

Stage A (upstream PR #39785) made the placement index shared and restart-safe.
Stage B (`pr-kv-indexer-event-plane`) adds the pieces the indexer's own README
listed as missing for production high availability:

- **Event log on Valkey Streams.** Bridges `XADD` each decoded event batch to
  `<prefix>events` and indexers consume it through a consumer group under a
  lease, so a bridge never needs an indexer to be up and an indexer never needs
  a bridge to resend.
- **Worker replay.** With SGLang's replay endpoint configured, a bridge asks the
  worker for every batch after the last sequence it forwarded, on connect and on
  a gap, and checkpoints that sequence in Valkey so a restart replays only the
  gap. A sequence that goes backwards (worker restart) clears that worker first.
- **Worker liveness.** Bridges heartbeat a TTL key while the worker's port
  answers; indexers clear a worker whose heartbeat expired, through keyspace
  expiry notifications with a sweep as backstop.

Scripts: `indexer.sh <memory|valkey|stream>`, `event.sh <mode> <event>`,
`rebuild.sh`, `run_all.sh`. (`scenario.sh` is the older stage-A
restart-under-load script, kept for the results above it.)

## Results

One RTX 5090, two Qwen3-1.7B workers with 40k-token KV pools, 8 tenants with
about 7.8k-token system prompts, 6 concurrent clients, closed loop. "Blind" is
the router's `no_cache_candidate` count for the whole run; "index after" is how
many placements the router's indexer could still answer for this workload's
block set, probed live at that moment.

### 1. Restarting the indexer, and a rolling restart of the whole fleet

| setup | index before | index after | blind decisions | worst window |
| --- | --- | --- | --- | --- |
| memory, one endpoint | 968 | **419** | **337** of 1,958 (17%) | 0.73 hit ratio, p90 980 ms |
| Valkey, one endpoint | 968 | **1,210** (still growing) | 12 of 2,135 | 0.77 hit ratio, p90 1,053 ms |
| Valkey, both endpoints | 968 | **968** | 12 of 2,052 | **none: 0.99 and p90 73 ms throughout** |

The in-memory index comes back empty and relearns only as blocks churn; the
Valkey-backed one never loses anything. But durable state alone still leaves one
window degraded, because a router holding a single `--kv-indexer-endpoint` has
nowhere to ask while that socket is down.

Giving the router every endpoint of the shared-state fleet closes it. The third
row is a rolling restart of *both* indexers, one after the other, and no window
moves at all; the router logs the two failovers and nothing else changes:

```
KV Indexer failover: queries now prefer another endpoint from=http://127.0.0.1:50051 to=http://127.0.0.1:50052
KV Indexer failover: queries now prefer another endpoint from=http://127.0.0.1:50052 to=http://127.0.0.1:50051
```

That needed a router change (`--kv-indexer-endpoint` now takes a list, preferred
first, failing over only while the current endpoint cannot answer), which is the
third commit of the stage-B branch.

### 2. Rotating the indexer fleet behind a stable address

Kill the indexer the router is *not* using, then start a new one:

| mode | blind decisions | hit ratio | the new indexer, 5 s after start |
| --- | --- | --- | --- |
| stream (Valkey) | 10 of 1,992 | 0.99 flat | answers with all 968 placements |

An added in-memory indexer would start empty and stay wrong until every prefix
churned, which is why the same run has no memory-mode column.

### 3. Bridge outage (20 s), steady workload: no difference, measured

| mode | index before | index after | blind decisions |
| --- | --- | --- | --- |
| memory | 968 | 969 | 9 of 2,162 |
| stream | 968 | 968 | 10 of 2,206 |

Honest negative result. With a steady tenant set the worker publishes almost
nothing new during the outage, so there is nothing to lose. Flushing the
worker's cache mid-outage does not change it either: the same tenants re-store
the same block hashes, so the index is accidentally right. The replay path is
exercised in the same runs (`bridge-0.log`: `resuming from the checkpointed
sequence seq=13356`, then `replayed buffered KV event batches ... replayed=123`)
and is covered deterministically by `tests/bridge_replay.rs`. It pays off when
the content changes during the outage, which this load generator does not do.

### 4. Worker restart (about 70 s down)

| mode | index right after the worker returned | blind decisions |
| --- | --- | --- |
| memory | 1,089 placements, **484 of them for the worker whose cache is empty** | 115 of 3,110 |
| stream | 514, **all for the live worker**; the restarted one was cleared | 130 of 2,597 |

Liveness removes the phantom prefixes. Two honest caveats from the same runs:
TTFT during the hole is *worse* in stream mode (p50 1.0 to 3.3 s versus 0.5 to
0.9 s) and it serves fewer requests, because on a two-worker rig clearing the
dead worker concentrates every tenant on the survivor, whose 40k-token pool
cannot hold 62k tokens of prompts; and after the worker returns, stream mode
only routes to it again as it re-reports, so its capacity ramps up instead of
being assumed. On a fleet where one worker is a small fraction of capacity, both
behaviours are what you want; on this rig the phantom placements accidentally
let memory mode use the returning worker sooner.

### 5. Rebuilding the index from the stream

With the load stopped and the world frozen (indexers first, then bridges):

```
1251 block hashes, stream length 12045, dbsize 2230
wiping every key except the stream -> keys left: 1, placements: 0
replaying the window into the empty keyspace as group rebuild-...
rebuilt: dbsize 2225, placements 1251
REBUILT INDEX IDENTICAL over 1251 block hashes (30601 bytes of placements)
```

Same per-worker split before and after (630 / 621), byte for byte. This is the
"snapshot plus event replay" the indexer README asked for: the keyspace is the
snapshot, the stream is the window.

## Reproducing

```sh
./up.sh                                   # valkey + two workers
./run_all.sh                              # every scenario, memory baseline vs stream
./rebuild.sh                              # right after a stream-mode run
./down.sh
```

Individual runs: `DURATION=180 EVENT_AT=60 ./event.sh stream worker-restart`.
Events: `indexer-restart` (router on one endpoint), `indexer-restart-ha` (router
on every endpoint), `indexer-kill-add`, `bridge-outage`, `bridge-outage-churn`,
`worker-restart`.

## Notes for anyone repeating this

- Two workers on one GPU need `--max-total-tokens` per worker; SGLang sizes the
  pool from free memory, so the second worker otherwise gets whatever is left.
- Never edit a running shell script: bash reads it incrementally and a mid-run
  edit shifts the byte offsets, which silently corrupted two runs here.
- Kill background processes by matching their full binary path, not by a stored
  PID: a recycled PID took down a worker in one of these sessions and a leftover
  router served a whole scenario from a stale index.
