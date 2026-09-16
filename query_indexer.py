#!/usr/bin/env python3
# query_indexer.py — ask several KV Indexer servers the same placement question and diff the answers
"""Usage: uv run --with grpcio --with grpcio-tools query_indexer.py --proto <kv_indexer.proto> \
          --hashes-from-valkey <valkey-port> --endpoints 127.0.0.1:50051 127.0.0.1:50052

Compiles the proto at runtime, pulls block hashes out of the Valkey keyspace,
and shows that every server returns byte-identical placements for them."""

import argparse
import importlib
import json
import os
import subprocess
import sys
import tempfile


def compile_proto(proto_path: str):
    out = tempfile.mkdtemp(prefix="kv-indexer-pb-")
    from grpc_tools import protoc

    rc = protoc.main(
        [
            "protoc",
            f"-I{os.path.dirname(proto_path)}",
            f"--python_out={out}",
            f"--grpc_python_out={out}",
            os.path.basename(proto_path),
        ]
    )
    if rc != 0:
        sys.exit("protoc failed")
    sys.path.insert(0, out)
    return importlib.import_module("kv_indexer_pb2"), importlib.import_module("kv_indexer_pb2_grpc")


def hashes_from_valkey(port: int, prefix: str, limit: int):
    keys = subprocess.run(
        ["valkey-cli", "-p", str(port), "--scan", "--pattern", f"{prefix}b:*"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.split()
    hashes = sorted(int(k.rsplit("b:", 1)[1]) for k in keys)
    return hashes[:limit]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--proto", required=True)
    ap.add_argument("--endpoints", nargs="+", required=True)
    ap.add_argument(
        "--hashes-from-valkey",
        type=int,
        default=int(os.environ.get("VALKEY_PORT", "6399")),
        metavar="PORT",
    )
    ap.add_argument("--prefix", default="{sgl-kv-indexer}:")
    ap.add_argument("--limit", type=int, default=64)
    ap.add_argument("--hashes-file", help="one block hash per line instead of scanning Valkey")
    ap.add_argument("--dump", help="write the normalized placements of the first endpoint as JSON")
    args = ap.parse_args()

    import grpc

    pb2, pb2_grpc = compile_proto(args.proto)
    if args.hashes_file:
        with open(args.hashes_file) as f:
            hashes = [int(line) for line in f if line.strip()]
    else:
        hashes = hashes_from_valkey(args.hashes_from_valkey, args.prefix, args.limit)
    if not hashes:
        sys.exit("no block hashes in Valkey yet; run some load first")
    print(f"querying {len(hashes)} block hashes on {len(args.endpoints)} servers")

    answers = {}
    for endpoint in args.endpoints:
        stub = pb2_grpc.KVIndexerStub(grpc.insecure_channel(endpoint))
        resp = stub.MatchExternalKv(pb2.MatchExternalKvRequest(hashes=hashes, count_as_hit=False), timeout=5)
        placements = sorted(
            (node.worker_id, node.address, tier.tier, tuple(sorted(tier.hashes)))
            for node in resp.matches
            for tier in node.hashes_by_tier
        )
        answers[endpoint] = placements
        held = sum(len(p[3]) for p in placements)
        print(f"  {endpoint}: {len(resp.matches)} workers, {held} placements")

    first = next(iter(answers.values()))
    per_worker = {}
    for worker_id, _, _, hashes in first:
        per_worker[worker_id] = per_worker.get(worker_id, 0) + len(hashes)
    print("per-worker placements: " + json.dumps(per_worker, sort_keys=True))
    if args.dump:
        with open(args.dump, "w") as f:
            json.dump([list(p[:3]) + [list(p[3])] for p in first], f, indent=1, sort_keys=True)
    if all(v == first for v in answers.values()):
        print("all servers agree, byte for byte")
    else:
        sys.exit("servers DISAGREE")


if __name__ == "__main__":
    main()
