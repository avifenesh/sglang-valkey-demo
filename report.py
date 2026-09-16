#!/usr/bin/env python3
# report.py — compare memory vs valkey runs: TTFT and prefix cache hit ratio per window
"""Reads <run>/requests.csv and <run>/metrics.csv for each run directory given,
prints a per-window table and, when matplotlib is available, writes a PNG."""

import argparse
import csv
import os
import statistics
from collections import defaultdict


def load_requests(run):
    out = []
    with open(os.path.join(run, "requests.csv")) as f:
        for row in csv.DictReader(f):
            if row["ok"] == "1":
                out.append((float(row["t"]), float(row["ttft_ms"])))
    return out


def load_hits(run):
    """Per worker sample list of (t, cached, prompt)."""
    per_worker = defaultdict(list)
    with open(os.path.join(run, "metrics.csv")) as f:
        for row in csv.DictReader(f):
            per_worker[row["worker"]].append(
                (float(row["t"]), float(row["cached_tokens_total"]), float(row["prompt_tokens_total"]))
            )
    return per_worker


def window_stats(requests, hits, window, duration):
    rows = []
    for start in range(0, int(duration), window):
        end = start + window
        ttfts = [ttft for t, ttft in requests if start <= t < end]
        cached = prompt = 0.0
        for samples in hits.values():
            inside = [s for s in samples if start <= s[0] < end]
            if len(inside) >= 2:
                cached += inside[-1][1] - inside[0][1]
                prompt += inside[-1][2] - inside[0][2]
        ratio = cached / prompt if prompt > 0 else float("nan")
        p50 = statistics.median(ttfts) if ttfts else float("nan")
        p90 = sorted(ttfts)[int(0.9 * (len(ttfts) - 1))] if ttfts else float("nan")
        rows.append((start, end, len(ttfts), p50, p90, ratio))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+", help="run directories, e.g. results/memory results/valkey")
    ap.add_argument("--window", type=int, default=10)
    ap.add_argument("--duration", type=float, default=150)
    ap.add_argument("--event-at", type=float, default=None, help="seconds when the indexer was restarted")
    ap.add_argument("--png", default=None)
    args = ap.parse_args()

    table = {}
    for run in args.runs:
        table[run] = window_stats(load_requests(run), load_hits(run), args.window, args.duration)

    for run, rows in table.items():
        print(f"\n== {run}")
        print(f"{'window':>10} {'reqs':>5} {'ttft p50':>9} {'ttft p90':>9} {'hit ratio':>9}")
        for start, end, n, p50, p90, ratio in rows:
            mark = " <- indexer restart" if args.event_at is not None and start <= args.event_at < end else ""
            print(f"{start:4d}-{end:<4d} {n:5d} {p50:8.1f}ms {p90:8.1f}ms {ratio:9.2f}{mark}")

    if args.png:
        try:
            import matplotlib

            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
        except ImportError:
            print("matplotlib not installed; skipping PNG")
            return
        fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(9, 6), sharex=True)
        for run, rows in table.items():
            xs = [(s + e) / 2 for s, e, *_ in rows]
            ax1.plot(xs, [r[3] for r in rows], marker="o", label=os.path.basename(run.rstrip("/")))
            ax2.plot(xs, [r[5] for r in rows], marker="o", label=os.path.basename(run.rstrip("/")))
        if args.event_at is not None:
            for ax in (ax1, ax2):
                ax.axvline(args.event_at, color="k", linestyle="--", linewidth=1)
        ax1.set_ylabel("TTFT p50 (ms)")
        ax2.set_ylabel("prefix cache hit ratio")
        ax2.set_xlabel("seconds")
        ax2.set_ylim(0, 1.05)
        ax1.legend()
        ax1.set_title("KV Indexer restart under load: in-memory vs Valkey backend")
        fig.tight_layout()
        fig.savefig(args.png, dpi=130)
        print(f"wrote {args.png}")


if __name__ == "__main__":
    main()
