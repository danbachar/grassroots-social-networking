#!/usr/bin/env python3
"""Reconciles the pure-UDP sweep's sender-claimed bytes against what the
responder actually received.

Raw UDP write success only means the OS accepted the datagram into its
send buffer, not that it arrived — a 32KB write is IP-fragmented and any
one lost fragment drops the whole write. Measured at N=2: phone claimed
208,764,928 B sent, responder received 189,169,664 B, a 9.4% loss the
phone-side JSONL cannot see. summarize.py's numbers for the udp transport
are therefore sender-side upper bounds, not delivered throughput; this
script produces the delivered number by bracketing each run's
[run_start, closed] window against the responder's own periodic totals.

Needs the responder run with a small REPORT_S (2s here) so its windows
are fine-grained enough not to blur across the --settle gap between runs.
"""
import argparse
import glob
import json
import os
import re
import statistics as st
from datetime import datetime, timezone

p = argparse.ArgumentParser()
p.add_argument("dir", help="results directory (n*_r*_phone.jsonl files)")
p.add_argument("responder_log", help="path to the udp_responder stdout log")
a = p.parse_args()


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


# (timestamp, cumulative totalBytes) samples from the responder's own
# periodic report, sorted by time.
samples = []
with open(a.responder_log) as f:
    for line in f:
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue
        if obj.get("ev") == "throughput" and obj.get("peer") == "all":
            samples.append((parse_ts(obj["ts"]), obj["totalBytes"]))
samples.sort(key=lambda x: x[0])

if not samples:
    raise SystemExit(f"no responder throughput samples in {a.responder_log}")


def cumulative_at_or_before(ts):
    """Latest known cumulative total at or before ts; falls back to the
    first sample if ts predates all of them (should not happen in
    practice — the run window is inside the responder's uptime)."""
    best = samples[0][1]
    for s_ts, s_total in samples:
        if s_ts > ts:
            break
        best = s_total
    return best


def cumulative_at_or_after(ts):
    for s_ts, s_total in samples:
        if s_ts >= ts:
            return s_total
    return samples[-1][1]  # responder log ends before ts; best available


runs = {}
for fpath in glob.glob(os.path.join(a.dir, "n*_r*_phone.jsonl")):
    m = re.search(r"n(\d+)_r(\d+)_phone", os.path.basename(fpath))
    if not m:
        continue
    n, rep = int(m.group(1)), int(m.group(2))
    start_ts = end_ts = None
    sender_bytes = None
    for line in open(fpath):
        if '"run_start"' in line:
            try:
                start_ts = parse_ts(json.loads(line[line.index("{"):])["ts"])
            except (ValueError, json.JSONDecodeError, KeyError):
                pass
        elif '"load_end"' in line:
            try:
                sender_bytes = json.loads(line[line.index("{"):])["totalBytes"]
            except (ValueError, json.JSONDecodeError, KeyError):
                pass
        elif '"closed"' in line:
            try:
                end_ts = parse_ts(json.loads(line[line.index("{"):])["ts"])
            except (ValueError, json.JSONDecodeError, KeyError):
                pass
    if start_ts is None or end_ts is None or sender_bytes is None:
        continue
    receiver_bytes = cumulative_at_or_after(end_ts) - cumulative_at_or_before(start_ts)
    loss_pct = 100 * (1 - receiver_bytes / sender_bytes) if sender_bytes else 0
    runs.setdefault(n, []).append({
        "senderKBps": sender_bytes / 1000 / (end_ts - start_ts).total_seconds(),
        "receiverKBps": receiver_bytes / 1000 / (end_ts - start_ts).total_seconds(),
        "lossPct": loss_pct,
    })

if not runs:
    raise SystemExit(f"no completed runs found in {a.dir}")

print(f"{'N':>4} {'runs':>5} {'sender kB/s':>14} {'receiver kB/s':>16} {'loss %':>8}")
for n in sorted(runs):
    r = runs[n]
    sender = [x["senderKBps"] for x in r]
    receiver = [x["receiverKBps"] for x in r]
    loss = [x["lossPct"] for x in r]
    print(f"{n:>4} {len(r):>5} {st.mean(sender):>14.1f} {st.mean(receiver):>16.1f} "
          f"{st.mean(loss):>8.1f}")
