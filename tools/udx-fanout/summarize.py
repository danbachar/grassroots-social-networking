#!/usr/bin/env python3
"""Summarises a repeated fan-out sweep: one row per N, across its runs.

Reports the spread across runs, not just the mean. A fan-out whose mean
throughput looks fine but varies by a factor of three between identical
runs has not been characterised by its mean.
"""
import argparse
import glob
import json
import os
import re
import statistics as st

p = argparse.ArgumentParser()
p.add_argument("dir", help="results directory")
p.add_argument("--skip-windows", type=int, default=1,
               help="leading report windows to drop as ramp-up (default 1)")
a = p.parse_args()

runs = {}
for f in glob.glob(os.path.join(a.dir, "n*_r*_phone.jsonl")):
    m = re.search(r"n(\d+)_r(\d+)_phone", os.path.basename(f))
    if not m:
        continue
    n, rep = int(m.group(1)), int(m.group(2))
    win, end = [], None
    for line in open(f):
        if '"throughput"' in line:
            try:
                win.append(json.loads(line.split("{", 1)[0] + "{"
                                      + line.split("{", 1)[1]))
            except (json.JSONDecodeError, IndexError):
                pass
        elif '"load_end"' in line:
            try:
                end = json.loads(line[line.index("{"):])
            except (ValueError, json.JSONDecodeError):
                pass
    win = win[a.skip_windows:]
    if not win:
        continue
    runs.setdefault(n, []).append({
        "aggKBps": st.mean(w["aggregateBps"] for w in win) / 1000,
        "minKBps": st.mean(w["perStreamMinBps"] for w in win) / 1000,
        "p50KBps": st.mean(w["perStreamP50Bps"] for w in win) / 1000,
        "maxKBps": st.mean(w["perStreamMaxBps"] for w in win) / 1000,
        "stalled": max(w["stalled"] for w in win),
        "errors": end["writeErrors"] if end else -1,
    })

if not runs:
    raise SystemExit(f"no completed runs found in {a.dir}")

print(f"{'N':>4} {'runs':>5} {'aggregate kB/s':>22} {'per-stream kB/s':>18} "
      f"{'slowest':>9} {'stalled':>8} {'errs':>5}")
print(f"{'':>4} {'':>5} {'mean':>10}{'sd':>7}{'cv':>5} "
      f"{'mean':>9}{'sd':>9} {'kB/s':>9} {'max':>8} {'':>5}")
for n in sorted(runs):
    r = runs[n]
    agg = [x["aggKBps"] for x in r]
    per = [x["aggKBps"] / n for x in r]
    sd = st.stdev(agg) if len(agg) > 1 else 0.0
    psd = st.stdev(per) if len(per) > 1 else 0.0
    cv = sd / st.mean(agg) if st.mean(agg) else 0
    print(f"{n:>4} {len(r):>5} {st.mean(agg):>10.1f}{sd:>7.1f}{cv:>5.2f} "
          f"{st.mean(per):>9.1f}{psd:>9.1f} "
          f"{st.mean(x['minKBps'] for x in r):>9.2f} "
          f"{max(x['stalled'] for x in r):>8} "
          f"{sum(x['errors'] for x in r if x['errors'] > 0):>5}")
