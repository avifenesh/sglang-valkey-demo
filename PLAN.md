# Valkey as the placement and event plane for SGLang cache-aware routing

Goal: a fleet whose cache-aware routing stays correct through the operational
events a provider actually hits, with Valkey carrying the state that makes it
possible, and a demo that shows each event with hit ratio and TTFT flat.

## What exists after PR #39785 (stage A)

- Indexer servers are stateless over a Valkey keyspace: restart-safe, active-active.
- Still true (from the indexer README): events published while a bridge is
  disconnected are lost; an indexer outage loses the batches sent during it; a
  worker death or restart is not detected, so its old placements stay in the
  index ("phantom prefixes" the router keeps routing to).

## Stage B: event log, liveness, restart hygiene (DONE, branch pr-kv-indexer-event-plane)

### B1. Valkey Streams as the KV event log

- Bridge gains `KV_INDEXER_SINK=grpc|stream`. In `stream` mode each decoded
  batch is `XADD`ed to `{prefix}events` (`MAXLEN ~` configurable, default 1M
  entries) as the prost-encoded `ApplyExternalKvBatchRequest` plus
  `worker_id` and `seq` fields. The bridge no longer needs an indexer up.
- Indexer server gains `KV_INDEXER_EVENT_SOURCE=grpc|stream`. In `stream` mode a
  consumer task reads `XREADGROUP GROUP indexers <consumer> COUNT 256 BLOCK 1000`
  on a dedicated connection, applies through the same validated path as the gRPC
  handler, `XACK`s, and reclaims idle pending entries with `XAUTOCLAIM` (crashed
  consumer). Group creation is idempotent (`MKSTREAM`, ignore `BUSYGROUP`).
  Applies are idempotent, so at-least-once delivery is correct.
- Snapshot plus replay: the keyspace is the snapshot, the stream is the replay
  window. Any number of indexers share one consumer group. A new indexer joins
  the group and is current immediately (state is in the keyspace).
- Bonus for the in-memory backend: with `EVENT_SOURCE=stream` it uses a private
  consumer group starting at `0`, so even the in-memory indexer rebuilds its
  index on restart from the retained window.

### B2. Worker liveness

- Bridge heartbeats `SET {prefix}alive:<worker> <ms> EX <ttl>` every `ttl/3`
  (default ttl 15 s) and sets a permanent marker `{prefix}hb:<worker>` so only
  workers that ever heartbeated are subject to liveness.
- Indexer runs a liveness poller every 5 s over the worker set: a marked worker
  with no `alive` key gets `CLEAR_ALL_AT_TIER` for every tier, through the normal
  apply path (so hit counts, prune and parity semantics all hold). Polling, not
  keyspace notifications: cluster-safe, no server config, one round trip.

### B3. Worker restart hygiene in the bridge

- On the publisher's END sentinel (seq `-1`) or a sequence reset (seq below the
  last seen), emit `AllBlocksCleared` for the worker before forwarding new
  events. Mirrors what the router's own pump does (`tree.clear_worker`).
- ZMQ replay on (re)connect: when `SGLANG_KV_REPLAY_ENDPOINT` is set, the bridge
  opens a DEALER to it, sends `last_seq + 1` (or `0`), and forwards the replayed
  batches before live ones. Closes the worker-to-bridge gap using the buffer the
  worker already keeps.

### Tests

- Stream sink and consumer round trip against a spawned `valkey-server`
  (existing harness); consumer-group reclaim after a killed consumer; rebuild
  from `0`.
- Liveness: heartbeat stops, poller clears, parity with the in-memory backend
  after the clear.
- Bridge: END sentinel and seq reset emit `AllBlocksCleared`; replay request
  frames and ordering against a fake ZMQ publisher (router tests already have
  helpers for a bound PUB socket).

### Size

About 1,200 to 1,600 lines of Rust including tests, plus README. Roughly a day
and a half of focused work, then half a day for the demo.

## Stage C: the demo (DONE, see README results)

Same rig, 2 workers, 2 bridges (stream, heartbeat, replay), 2 Valkey-backed
indexers consuming one group, router, 8 tenants with 7.8k-token prompts.
Each scenario is a plot with hit ratio and TTFT, memory-mode baseline where the
difference is the point:

1. Rolling restart of both indexers, one after the other. Expect flat.
2. Kill one indexer for good, start a third mid-run. Expect flat, group rebalances.
3. Bridge outage 20 s then restart. Baseline: lost events, drift (blind and
   stale decisions). New: replay from the worker buffer, index converges.
4. Worker restart (`docker restart`). Baseline: phantom prefixes, router sends
   the tenant back to a cold worker, misses. New: END sentinel clears, TTL
   backstop, routing adapts as soon as the worker is back.
5. Index rebuild: flush the placement keyspace while the stream is retained; a
   fresh consumer group from `0` rebuilds; `MatchExternalKv` answers identical
   before and after.

## Stage D (later, separate): SGLang-side publisher

`EventPublisherFactory.register_publisher("valkey", ...)`: workers `XADD`
directly with valkey-glide, no bridge. Python-side PR to SGLang.

## Delivery

Stage B as one PR on top of #39785 (GitHub stack if the target repo allows it,
otherwise "depends on" with the base commits included). Demo repo updated with
the five scenarios and results.
