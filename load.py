#!/usr/bin/env python3
# load.py — multi-tenant shared-prefix load against the router, logging TTFT and worker cache hits
"""Closed-loop chat load with N tenants, each owning a long system prompt.

Every request is `system prompt of tenant t` + a short question, streamed, so
time to first token is dominated by whether the worker that got the request
already holds the tenant's prefix. Worker /metrics are scraped in parallel so
the prefix cache hit ratio can be plotted against the same clock.

Outputs <out>/requests.csv and <out>/metrics.csv.
"""

import argparse
import csv
import json
import os
import random
import re
import statistics
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

WORDS = (
    "ledger invoice tenant policy region shard replica quorum lease epoch "
    "gateway checkpoint window budget latency throughput cache prefix token "
    "router worker index placement block hash chain parent tier memory host "
    "device request response stream session affinity failover restart "
    "schema contract audit metric gauge counter histogram deadline retry "
    "backlog queue drain saturation floor ceiling margin ratio share fleet"
).split()

QUESTIONS = [
    "Summarize the policy in one sentence.",
    "Which region is mentioned first?",
    "How many tiers does the plan describe?",
    "What is the retry rule?",
    "Name the failover condition.",
    "What does the audit require?",
    "Which metric gates the deadline?",
    "State the budget rule briefly.",
]


def system_prompt(tenant: int, words: int) -> str:
    rng = random.Random(1000 + tenant)
    body = " ".join(rng.choice(WORDS) for _ in range(words))
    return (
        f"You are the assistant for tenant {tenant}. Follow this operating policy strictly. "
        f"Policy document: {body}"
    )


def one_request(router: str, model: str, tenant: int, prompt: str, max_tokens: int):
    payload = json.dumps(
        {
            "model": model,
            "messages": [
                {"role": "system", "content": prompt},
                {"role": "user", "content": random.choice(QUESTIONS) + f" (case {random.randint(1, 9999)})"},
            ],
            "max_tokens": max_tokens,
            "temperature": 0,
            "stream": True,
        }
    ).encode()
    req = urllib.request.Request(
        f"{router}/v1/chat/completions",
        data=payload,
        headers={"Content-Type": "application/json"},
    )
    start = time.perf_counter()
    ttft = None
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            for line in resp:
                if ttft is None and line.startswith(b"data:") and b'"content"' in line:
                    ttft = (time.perf_counter() - start) * 1000
            if ttft is None:
                ttft = (time.perf_counter() - start) * 1000
        return ttft, True
    except Exception as exc:  # noqa: BLE001 - any failure is a data point
        sys.stderr.write(f"request failed: {exc}\n")
        return (time.perf_counter() - start) * 1000, False


METRIC_RE = re.compile(r"^(sglang:(?:cached_tokens_total|prompt_tokens_total))(?:\{[^}]*\})?\s+([0-9.eE+-]+)")


def scrape(url: str):
    cached = prompt = 0.0
    try:
        with urllib.request.urlopen(f"{url}/metrics", timeout=5) as resp:
            for raw in resp:
                m = METRIC_RE.match(raw.decode(errors="replace"))
                if not m:
                    continue
                if m.group(1).endswith("cached_tokens_total"):
                    cached += float(m.group(2))
                else:
                    prompt += float(m.group(2))
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"scrape failed for {url}: {exc}\n")
        return None
    return cached, prompt


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--router", default="http://127.0.0.1:8080")
    ap.add_argument("--model", default="Qwen/Qwen3-1.7B")
    ap.add_argument("--workers", nargs="+", required=True, help="worker base URLs to scrape")
    ap.add_argument("--tenants", type=int, default=12)
    ap.add_argument("--prompt-words", type=int, default=1500, help="about 2k tokens")
    ap.add_argument("--max-tokens", type=int, default=24)
    ap.add_argument("--concurrency", type=int, default=6)
    ap.add_argument("--duration", type=float, default=150)
    ap.add_argument("--scrape-every", type=float, default=2.0)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    prompts = [system_prompt(t, args.prompt_words) for t in range(args.tenants)]
    t0 = time.perf_counter()
    stop = threading.Event()
    lock = threading.Lock()
    rows = []

    def scraper():
        with open(os.path.join(args.out, "metrics.csv"), "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "worker", "cached_tokens_total", "prompt_tokens_total"])
            while not stop.is_set():
                now = time.perf_counter() - t0
                for url in args.workers:
                    got = scrape(url)
                    if got:
                        w.writerow([f"{now:.1f}", url, f"{got[0]:.0f}", f"{got[1]:.0f}"])
                f.flush()
                stop.wait(args.scrape_every)

    def worker_loop(_):
        rng = random.Random()
        while time.perf_counter() - t0 < args.duration:
            tenant = rng.randrange(args.tenants)
            started = time.perf_counter() - t0
            ttft, ok = one_request(args.router, args.model, tenant, prompts[tenant], args.max_tokens)
            with lock:
                rows.append((started, tenant, ttft, ok))

    def progress():
        last = 0
        while not stop.is_set():
            stop.wait(10)
            with lock:
                recent = [r[2] for r in rows[last:] if r[3]]
                last = len(rows)
            if recent:
                print(
                    f"t={time.perf_counter() - t0:6.1f}s  reqs={len(recent):4d}  "
                    f"ttft p50={statistics.median(recent):7.1f}ms  "
                    f"p90={sorted(recent)[int(0.9 * (len(recent) - 1))]:7.1f}ms",
                    flush=True,
                )

    threads = [threading.Thread(target=scraper, daemon=True), threading.Thread(target=progress, daemon=True)]
    for th in threads:
        th.start()
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        list(pool.map(worker_loop, range(args.concurrency)))
    stop.set()
    for th in threads:
        th.join(timeout=5)

    with open(os.path.join(args.out, "requests.csv"), "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["t", "tenant", "ttft_ms", "ok"])
        for started, tenant, ttft, ok in rows:
            w.writerow([f"{started:.3f}", tenant, f"{ttft:.1f}", int(ok)])
    oks = [r[2] for r in rows if r[3]]
    print(f"done: {len(rows)} requests, {len(rows) - len(oks)} failed, ttft p50={statistics.median(oks):.1f}ms")


if __name__ == "__main__":
    main()
