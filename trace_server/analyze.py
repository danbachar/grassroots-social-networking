#!/usr/bin/env python3
"""
Offline analysis for Grassroots testbed experiment recordings.

Input is either the trace server's SQLite DB (``data/traces.db``) or raw
``exp_<id>.jsonl`` files straight off a device. Records are grouped by
experiment (the exp file name) and device (the pubkey hex the app uploads as
``deviceId``; for raw files, the file stem). For every experiment the script
emits, under ``--out``:

    <exp>/summary.txt          per-device record counts, stage events,
                               delivery ratio, latency stats, flow goodput
    <exp>/steps.csv            per distance-step marker segment: RSSI stats
                               (adv/conn), stage events seen, drops
    <exp>/pathloss.txt         log-distance fit RSSI = A - 10 n log10(d)
                               (needs >= 3 distinct d= markers)
    <exp>/rssi_timeline.png    RSSI vs time per device, markers as verticals
    <exp>/link_stages.png      link-stage event timeline per device
    <exp>/wire_bytes.png       tx/rx bytes per packet type over time
    <exp>/latency.csv          per-message e2e latency (sent joined to
                               delivered on messageId)

Markers drive the ground truth: a marker whose label contains ``d=<number>``
opens a distance segment that runs until the next ``d=`` marker (or expStop).
Direction words in the label (``approach``/``retreat``) are carried through to
``steps.csv`` for the hysteresis analysis.

Usage:
    python3 analyze.py data/traces.db --out analysis
    python3 analyze.py exp_dry-1.jsonl other_device_exp_dry-1.jsonl --out analysis
    python3 analyze.py data/traces.db --exp dry-1 --out analysis

Dependencies: pandas, numpy, matplotlib (see analysis_requirements.txt).
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sqlite3
import sys
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402

MARKER_DISTANCE_RE = re.compile(r"\bd\s*=\s*(\d+(?:\.\d+)?)")
LINK_STAGES = ["discovered", "connected", "session", "usable", "drop"]


# --------------------------------------------------------------------------- #
# Loading
# --------------------------------------------------------------------------- #
def _exp_from_upload_id(upload_id: str) -> str:
    # uploadId = "exp_<name>.jsonl:<length>"
    name = upload_id.split(":", 1)[0]
    if name.startswith("exp_"):
        name = name[len("exp_"):]
    if name.endswith(".jsonl"):
        name = name[: -len(".jsonl")]
    return name or "unknown"


def load_db(path: Path) -> pd.DataFrame:
    conn = sqlite3.connect(path)
    rows = conn.execute(
        "SELECT upload_id, device_id, type, t, body FROM records"
    ).fetchall()
    conn.close()
    out = []
    for upload_id, device_id, rtype, t, body in rows:
        rec = json.loads(body)
        rec["_exp"] = _exp_from_upload_id(upload_id)
        rec["_device"] = device_id
        rec["_type"] = rtype
        rec["_t"] = t
        out.append(rec)
    return pd.DataFrame(out)


def load_jsonl(paths: list[Path]) -> pd.DataFrame:
    out = []
    for p in paths:
        stem = p.stem  # exp_dry-1 -> device label fallback = file stem
        exp = stem[len("exp_"):] if stem.startswith("exp_") else stem
        for line in p.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            rec["_exp"] = exp
            rec["_device"] = stem
            rec["_type"] = rec.get("type")
            rec["_t"] = rec.get("t")
            out.append(rec)
    return pd.DataFrame(out)


def short(device: str) -> str:
    return device[:8]


def _dict(v) -> dict:
    """A record field that should be a dict; pandas yields NaN when absent."""
    return v if isinstance(v, dict) else {}


def _num(v, default=0):
    """A numeric record field; NaN (missing) becomes the default."""
    return default if v is None or (isinstance(v, float) and math.isnan(v)) else v


# --------------------------------------------------------------------------- #
# Per-experiment analyses
# --------------------------------------------------------------------------- #
def marker_segments(df: pd.DataFrame) -> list[dict]:
    """Distance segments from d=<x> markers: [{d, direction, t0, t1}, ...].

    Every device stamps its own copy of each step marker, so identical labels
    arriving within 90s collapse into one segment (keyed to the earliest).
    """
    markers = df[(df._type == "marker")].sort_values("_t")
    segs: list[dict] = []
    for _, m in markers.iterrows():
        label = m.get("label") or ""
        match = MARKER_DISTANCE_RE.search(str(label))
        if not match:
            continue
        if segs and segs[-1]["label"] == str(label) \
                and m._t - segs[-1]["t0"] < 90_000:
            continue  # the same step marked on another device
        if segs:
            segs[-1]["t1"] = m._t
        direction = (
            "approach"
            if "approach" in str(label).lower()
            else "retreat" if "retreat" in str(label).lower() else ""
        )
        segs.append({"d": float(match.group(1)), "direction": direction,
                     "label": str(label), "t0": m._t, "t1": None})
    end = df._t.dropna().max()
    if segs and segs[-1]["t1"] is None:
        segs[-1]["t1"] = end
    return segs


def steps_table(df: pd.DataFrame, segs: list[dict]) -> pd.DataFrame:
    rssi = df[df._type == "rssi"]
    link = df[df._type == "link"]
    rows = []
    for seg in segs:
        in_seg_rssi = rssi[(rssi._t >= seg["t0"]) & (rssi._t < seg["t1"])]
        in_seg_link = link[(link._t >= seg["t0"]) & (link._t < seg["t1"])]
        row = {
            "d": seg["d"],
            "direction": seg["direction"],
            "label": seg["label"],
            "t0": seg["t0"],
            "t1": seg["t1"],
            "rssi_n": len(in_seg_rssi),
        }
        for src in ("adv", "conn"):
            vals = in_seg_rssi[in_seg_rssi.get("src") == src]["rssi"].dropna()
            row[f"rssi_{src}_mean"] = round(vals.mean(), 1) if len(vals) else None
            row[f"rssi_{src}_std"] = round(vals.std(), 1) if len(vals) > 1 else None
        for stage in LINK_STAGES:
            row[stage] = int((in_seg_link.get("event") == stage).sum())
        rows.append(row)
    return pd.DataFrame(rows)


def pathloss_fit(steps: pd.DataFrame) -> str | None:
    """Log-distance fit over segment means: RSSI = A - 10 n log10(d)."""
    pts = steps.dropna(subset=["rssi_adv_mean"])
    pts = pts[pts.d > 0]
    if pts.d.nunique() < 3:
        return None
    x = 10 * np.log10(pts.d.astype(float))
    y = pts.rssi_adv_mean.astype(float)
    n, a = np.polyfit(-x, y, 1)  # y = a - n * x
    resid = y - (a - n * x)
    return (
        f"log-distance fit over {pts.d.nunique()} distances "
        f"(adv-RSSI segment means):\n"
        f"  RSSI(d) = {a:.1f} - 10 * {n:.2f} * log10(d)\n"
        f"  path-loss exponent n = {n:.2f}, RSSI@1m = {a:.1f} dBm, "
        f"residual std = {resid.std():.1f} dB\n"
    )


def latency_table(df: pd.DataFrame) -> pd.DataFrame:
    msgs = df[df._type == "message"]
    sent = msgs[msgs.get("dir") == "sent"]
    delivered = msgs[msgs.get("dir") == "delivered"]
    if sent.empty:
        return pd.DataFrame()
    s = sent[["messageId", "_device", "_t", "payloadSize"]].rename(
        columns={"_t": "sentAt", "_device": "sender"})
    d = delivered[["messageId", "_t"]].rename(columns={"_t": "deliveredAt"})
    joined = s.merge(d.drop_duplicates("messageId"), on="messageId", how="left")
    joined["latencyMs"] = joined.deliveredAt - joined.sentAt
    return joined


def summarize(df: pd.DataFrame, latency: pd.DataFrame) -> str:
    lines = []
    t0, t1 = df._t.dropna().min(), df._t.dropna().max()
    lines.append(f"records: {len(df)}   span: {(t1 - t0) / 1000:.0f}s")
    for device, sub in df.groupby("_device"):
        lines.append(f"\ndevice {short(device)}:")
        counts = sub._type.value_counts().to_dict()
        lines.append(f"  records by type: {counts}")
        link = sub[sub._type == "link"]
        if not link.empty:
            stages = link.get("event").value_counts().to_dict()
            lines.append(f"  link stages: {stages}")
        if not latency.empty:
            mine = latency[latency.sender == device]
            if len(mine):
                ok = mine.latencyMs.notna()
                lines.append(
                    f"  messages sent: {len(mine)}, delivered: {int(ok.sum())} "
                    f"({100 * ok.mean():.0f}%)")
                if ok.any():
                    lat = mine.latencyMs.dropna()
                    lines.append(
                        f"  e2e latency ms: median {lat.median():.0f}, "
                        f"p90 {lat.quantile(0.9):.0f}, max {lat.max():.0f}")
        flows = sub[(sub._type == "flow") & (sub.get("event") == "stop")]
        for _, f in flows.iterrows():
            start = sub[(sub._type == "flow") & (sub.get("event") == "start")
                        & (sub.get("flow") == f.get("flow"))]
            window_ms = (f._t - start._t.iloc[0]) if len(start) else None
            acked_bytes = _num(f.get("ackedBytes"))
            goodput = (
                f"{acked_bytes / (window_ms / 1000):.0f} B/s"
                if window_ms else "n/a")
            lines.append(
                f"  flow {f.get('flow')}: sent {f.get('sent')}, "
                f"acked {f.get('acked')} ({acked_bytes} B), goodput {goodput}")
        wire = sub[sub._type == "wire"]
        if not wire.empty:
            totals: dict[str, int] = defaultdict(int)
            for _, w in wire.iterrows():
                for field in ("txBytes", "rxBytes"):
                    for k, v in _dict(w.get(field)).items():
                        totals[f"{field[:2]}:{k}"] += v
            lines.append(f"  wire bytes: {dict(sorted(totals.items()))}")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- #
# Plots
# --------------------------------------------------------------------------- #
def _marker_verticals(ax, df: pd.DataFrame, t_base: float):
    for _, m in df[df._type == "marker"].iterrows():
        label = m.get("label") or m.get("event")
        if m.get("event") in ("expStart", "expStop"):
            continue
        x = (m._t - t_base) / 1000
        ax.axvline(x, color="gray", linestyle=":", alpha=0.6)
        ax.annotate(str(label), (x, ax.get_ylim()[1]), fontsize=7,
                    rotation=90, va="top", ha="right", color="gray")


def plot_rssi(df: pd.DataFrame, out: Path):
    rssi = df[df._type == "rssi"]
    if rssi.empty:
        return
    t_base = df._t.dropna().min()
    fig, ax = plt.subplots(figsize=(11, 5))
    for (device, src), sub in rssi.groupby(["_device", "src"]):
        ax.plot((sub._t - t_base) / 1000, sub.rssi,
                marker="." if src == "adv" else "x", markersize=3,
                linestyle="none", label=f"{short(device)} {src}", alpha=0.7)
    ax.set_xlabel("time (s)")
    ax.set_ylabel("RSSI (dBm)")
    ax.legend(fontsize=8)
    ax.grid(alpha=0.3)
    _marker_verticals(ax, df, t_base)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_link_stages(df: pd.DataFrame, out: Path):
    link = df[df._type == "link"]
    if link.empty:
        return
    t_base = df._t.dropna().min()
    devices = sorted(df._device.unique())
    fig, ax = plt.subplots(figsize=(11, 1.2 + 1.4 * len(devices)))
    yticks, ylabels = [], []
    for di, device in enumerate(devices):
        sub = link[link._device == device]
        for si, stage in enumerate(LINK_STAGES):
            y = di * (len(LINK_STAGES) + 1) + si
            pts = sub[sub.get("event") == stage]
            if len(pts):
                ax.plot((pts._t - t_base) / 1000, [y] * len(pts),
                        "rv" if stage == "drop" else "o", markersize=5)
            yticks.append(y)
            ylabels.append(f"{short(device)}:{stage}")
    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=7)
    ax.set_xlabel("time (s)")
    ax.grid(alpha=0.3, axis="x")
    _marker_verticals(ax, df, t_base)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_wire(df: pd.DataFrame, out: Path):
    wire = df[df._type == "wire"]
    if wire.empty:
        return
    t_base = df._t.dropna().min()
    devices = sorted(wire._device.unique())
    fig, axes = plt.subplots(len(devices), 1,
                             figsize=(11, 3.2 * len(devices)), squeeze=False)
    for ax, device in zip(axes[:, 0], devices):
        sub = wire[wire._device == device].sort_values("_t")
        series: dict[str, list] = defaultdict(list)
        times = []
        keys = set()
        for _, w in sub.iterrows():
            tx = _dict(w.get("txBytes"))
            keys.update(tx.keys())
        for _, w in sub.iterrows():
            times.append((w._t - t_base) / 1000)
            tx = _dict(w.get("txBytes"))
            for k in keys:
                series[k].append(tx.get(k, 0))
        if times:
            ax.stackplot(times, *[series[k] for k in sorted(keys)],
                         labels=sorted(keys), alpha=0.8)
            ax.legend(fontsize=7, loc="upper right")
        ax.set_title(f"{short(device)} tx bytes / 10s window", fontsize=9)
        ax.set_xlabel("time (s)")
        ax.set_ylabel("bytes")
        ax.grid(alpha=0.3)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+",
                    help="traces.db and/or exp_*.jsonl files")
    ap.add_argument("--out", default="analysis", help="output directory")
    ap.add_argument("--exp", default=None,
                    help="only analyze this experiment name")
    args = ap.parse_args()

    frames = []
    for raw in args.inputs:
        p = Path(raw)
        if not p.exists():
            print(f"no such file: {p}", file=sys.stderr)
            return 1
        frames.append(load_db(p) if p.suffix == ".db" else load_jsonl([p]))
    df = pd.concat(frames, ignore_index=True)
    if df.empty:
        print("no records found", file=sys.stderr)
        return 1

    out_root = Path(args.out)
    for exp, edf in df.groupby("_exp"):
        if args.exp and exp != args.exp:
            continue
        out = out_root / exp
        out.mkdir(parents=True, exist_ok=True)

        latency = latency_table(edf)
        (out / "summary.txt").write_text(summarize(edf, latency))
        if not latency.empty:
            latency.to_csv(out / "latency.csv", index=False)

        segs = marker_segments(edf)
        if segs:
            steps = steps_table(edf, segs)
            steps.to_csv(out / "steps.csv", index=False)
            fit = pathloss_fit(steps)
            if fit:
                (out / "pathloss.txt").write_text(fit)

        plot_rssi(edf, out / "rssi_timeline.png")
        plot_link_stages(edf, out / "link_stages.png")
        plot_wire(edf, out / "wire_bytes.png")
        print(f"[{exp}] -> {out}/  "
              f"({len(edf)} records, {edf._device.nunique()} device(s), "
              f"{len(segs)} distance step(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
