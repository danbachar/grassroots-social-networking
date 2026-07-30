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
    <exp>/steps.csv            per position-step marker segment (d= or side=;
                               one row per repeat trial): RSSI stats
                               (adv/conn), stage events seen, drops
    <exp>/establishment.csv    repeat trials aggregated per (distance,
                               direction): fraction of trials that reached
                               each link stage — establishment probability
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

# A position marker: `d=<m>` (line sweep) or `side=<m>` (dilating clique).
# Trailing trial suffixes ("d=40 approach t2") don't affect the capture.
MARKER_POS_RE = re.compile(r"\b(?:d|side)\s*=\s*(\d+(?:\.\d+)?)")
LINK_STAGES = ["discovered", "connected", "session", "usable", "drop"]
# Runner control markers that annotate a step boundary but are not positions.
CONTROL_MARKERS = {"links-reset", "sessions-reset"}


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


def device_roles(df: pd.DataFrame) -> dict[str, str]:
    """Human roles instead of pubkey hex.

    The device that runs the plan stamps the step markers and originates the
    workload — the *sender* (the moving device in static+moving mode). The
    device that only records, receives and ACKs is the *receiver*. Ties or
    3+-device runs fall back to numbered senders/receivers so labels stay
    unique.
    """
    roles: dict[str, str] = {}
    msgs = df[df._type == "message"]
    senders, receivers = [], []
    for device in sorted(df._device.unique()):
        sub = msgs[msgs._device == device]
        sends = int((sub.get("dir") == "sent").sum()) if len(sub) else 0
        (senders if sends > 0 else receivers).append(device)
    for i, d in enumerate(senders):
        roles[d] = "sender" if len(senders) == 1 else f"sender{i + 1}"
    for i, d in enumerate(receivers):
        roles[d] = "receiver" if len(receivers) == 1 else f"receiver{i + 1}"
    return roles


def label_for(device: str, roles: dict[str, str]) -> str:
    """`sender (3c1a075c)` — role first, hex kept for traceability."""
    role = roles.get(device)
    return f"{role} ({short(device)})" if role else short(device)


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
    """Position segments from d=<x>/side=<x> markers: [{d, direction, t0, t1}].

    One segment per step. Repeat trials at the same distance carry distinct
    labels (…t1, …t2), so each stays its own segment. In static+moving mode
    only the moving device stamps position markers; the static device's
    records fall into these segments by timestamp. A duplicate identical label
    within 90s (e.g. both devices stamping) collapses to the earlier one.
    """
    markers = df[(df._type == "marker")].sort_values("_t")
    segs: list[dict] = []
    for _, m in markers.iterrows():
        label = m.get("label") or ""
        match = MARKER_POS_RE.search(str(label))
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


def steps_table(df: pd.DataFrame, segs: list[dict],
                latency: pd.DataFrame) -> pd.DataFrame:
    rssi = df[df._type == "rssi"]
    link = df[df._type == "link"]
    rows = []
    for seg in segs:
        in_seg_rssi = rssi[(rssi._t >= seg["t0"]) & (rssi._t < seg["t1"])]
        in_seg_link = link[(link._t >= seg["t0"]) & (link._t < seg["t1"])]
        # Messages SENT within this step (by any device) and their round-trip
        # latency — the send→ACK RTT, i.e. delivered.e2eLatencyMs. Gives the
        # latency-vs-distance curve and the per-step delivery ratio.
        seg_msgs = (
            latency[(latency.sentAt >= seg["t0"]) & (latency.sentAt < seg["t1"])]
            if not latency.empty else latency
        )
        dwell_sec = max((seg["t1"] - seg["t0"]) / 1000.0, 1e-9)
        adv = in_seg_rssi[in_seg_rssi.get("src") == "adv"]
        # Receiver-side advert visibility. The TX side cannot be measured
        # (the BLE controller broadcasts autonomously below the app), so the
        # denominator is the *known* advertising interval, and these two
        # receiver metrics carry the signal:
        #   advPerMin  — sightings/minute (app-side sampling is rate-limited
        #                to ~1/s per path, so this saturates around 60);
        #   advCoverage — fraction of dwell-seconds with >=1 sighting, which
        #                is robust to scan batching and the rate limit. This
        #                is the censoring-proof discovery-probability proxy.
        adv_seconds = set((adv._t // 1000).astype(int)) if len(adv) else set()
        row = {
            "d": seg["d"],
            "direction": seg["direction"],
            "label": seg["label"],
            "t0": seg["t0"],
            "t1": seg["t1"],
            "rssi_n": len(in_seg_rssi),
            "advPerMin": round(len(adv) / (dwell_sec / 60.0), 1),
            "advCoverage": round(len(adv_seconds) / dwell_sec, 3),
        }
        if len(seg_msgs):
            sent_n = len(seg_msgs)
            lat = seg_msgs["latencyMs"].dropna()
            row["msg_sent"] = sent_n
            row["msg_delivered"] = int(len(lat))
            row["delivery_rate"] = round(len(lat) / sent_n, 3)
            row["rtt_median_ms"] = round(lat.median()) if len(lat) else None
            row["rtt_p90_ms"] = round(lat.quantile(0.9)) if len(lat) else None
        else:
            row.update({"msg_sent": 0, "msg_delivered": 0,
                        "delivery_rate": None, "rtt_median_ms": None,
                        "rtt_p90_ms": None})
        for src in ("adv", "conn"):
            vals = in_seg_rssi[in_seg_rssi.get("src") == src]["rssi"].dropna()
            row[f"rssi_{src}_mean"] = round(vals.mean(), 1) if len(vals) else None
            row[f"rssi_{src}_std"] = round(vals.std(), 1) if len(vals) > 1 else None
        for stage in LINK_STAGES:
            row[stage] = int((in_seg_link.get("event") == stage).sum())
        rows.append(row)
    return pd.DataFrame(rows)


def pathloss_fit(steps: pd.DataFrame) -> str | None:
    """Log-distance fit RSSI = A - 10 n log10(d), over the per-distance mean
    adv RSSI so repeat trials at a distance don't over-weight it."""
    pts = steps.dropna(subset=["rssi_adv_mean"])
    pts = pts[pts.d > 0]
    if pts.d.nunique() < 3:
        return None
    means = pts.groupby("d")["rssi_adv_mean"].mean()
    x = 10 * np.log10(means.index.to_numpy(dtype=float))
    y = means.to_numpy(dtype=float)
    n, a = np.polyfit(-x, y, 1)  # y = a - n * x
    resid = y - (a - n * x)
    return (
        f"log-distance fit over {len(means)} distances "
        f"(per-distance mean adv RSSI):\n"
        f"  RSSI(d) = {a:.1f} - 10 * {n:.2f} * log10(d)\n"
        f"  path-loss exponent n = {n:.2f}, RSSI@1m = {a:.1f} dBm, "
        f"residual std = {resid.std():.1f} dB\n"
    )


def establishment_table(steps: pd.DataFrame) -> pd.DataFrame:
    """Aggregate repeat trials per (distance, direction): how often each link
    stage was reached — the establishment-probability-vs-distance result the
    `repeat` knob exists to produce. A stage counts as reached in a trial when
    its per-segment count > 0."""
    if steps.empty:
        return pd.DataFrame()
    rows = []
    for (d, direction), g in steps.groupby(["d", "direction"]):
        n = len(g)
        row = {"d": d, "direction": direction, "trials": n}
        for stage in LINK_STAGES:
            row[f"{stage}_rate"] = round((g[stage] > 0).sum() / n, 2)
        row["advCoverage_mean"] = round(g["advCoverage"].mean(), 3)
        adv = g["rssi_adv_mean"].dropna()
        row["rssi_adv_mean"] = round(adv.mean(), 1) if len(adv) else None
        sent = g["msg_sent"].sum()
        deliv = g["msg_delivered"].sum()
        row["delivery_rate"] = round(deliv / sent, 3) if sent else None
        rtt = g["rtt_median_ms"].dropna()
        row["rtt_median_ms"] = round(rtt.mean()) if len(rtt) else None
        rows.append(row)
    return pd.DataFrame(rows).sort_values(["direction", "d"])


def mesh_paths(df: pd.DataFrame, roles: dict[str, str]) -> pd.DataFrame:
    """Reconstruct each message's actual path through the mesh.

    A message is `sent` by one device, may be forwarded by relays (each logs a
    `relay` record for the packet it forwarded), and is `recv`d by the
    recipient. Joining those on the packet/message id across devices gives the
    real path — the only direct evidence of multi-hop delivery, since the
    envelope is sender-anonymous and no single device sees the whole route.

    Single-packet messages use packetId == messageId, so the ids join
    directly; fragmented messages (multi-packet) are reported by their
    relayed packet ids and counted separately.
    """
    msgs = df[df._type == "message"]
    if msgs.empty:
        return pd.DataFrame()
    relays = df[df._type == "relay"]
    sent = msgs[msgs.get("dir") == "sent"]
    recv = msgs[msgs.get("dir") == "recv"]
    if sent.empty:
        return pd.DataFrame()

    relay_by_id: dict[str, list] = defaultdict(list)
    for _, r in relays.iterrows():
        if r.get("event") == "dup":
            continue
        relay_by_id[str(r.get("packetId"))].append(r)

    rows = []
    for _, s_row in sent.iterrows():
        mid = str(s_row.get("messageId"))
        hops = sorted(relay_by_id.get(mid, []), key=lambda r: r._t)
        got = recv[recv.get("messageId") == mid]
        delivered = len(got) > 0
        path = [roles.get(s_row._device, short(s_row._device))]
        path += [roles.get(h._device, short(h._device)) for h in hops]
        if delivered:
            path.append(roles.get(got.iloc[0]._device,
                                  short(got.iloc[0]._device)))
        rows.append({
            "messageId": mid,
            "sentAt": s_row._t,
            "path": " -> ".join(path),
            "relayHops": len(hops),
            "delivered": delivered,
            "deliveredAt": int(got.iloc[0]._t) if delivered else None,
            "latencyMs": int(got.iloc[0]._t - s_row._t) if delivered else None,
            # The receiver's own view of distance travelled (TTL drop).
            "recvRelayHops": (int(got.iloc[0].get("relayHops"))
                              if delivered and pd.notna(got.iloc[0].get("relayHops"))
                              else None),
            "carried": any(bool(h.get("carried")) for h in hops),
        })
    return pd.DataFrame(rows)


def mesh_summary(paths: pd.DataFrame, df: pd.DataFrame) -> str:
    """Hop-count distribution, relay/custody evidence, duplication factor."""
    if paths.empty:
        return ""
    lines = ["", "=== mesh ==="]
    n = len(paths)
    d = int(paths.delivered.sum())
    lines.append(f"messages sent: {n}, delivered: {d} ({100 * d / n:.0f}%)")
    hop_counts = paths[paths.delivered].recvRelayHops.dropna()
    if len(hop_counts):
        dist = hop_counts.astype(int).value_counts().sort_index().to_dict()
        lines.append(f"delivered by relay hops (receiver TTL view): {dist}")
        multi = int((hop_counts > 0).sum())
        lines.append(f"  MULTI-HOP deliveries: {multi}/{len(hop_counts)}")
    relayed = paths[paths.relayHops > 0]
    if len(relayed):
        lines.append(f"messages observed being forwarded by a relay: "
                     f"{len(relayed)}")
        for path, grp in relayed.groupby("path"):
            lat = grp.latencyMs.dropna()
            lines.append(f"  {path}: {len(grp)} msg"
                         + (f", median {lat.median():.0f} ms" if len(lat) else ""))
    carried = paths[paths.carried]
    if len(carried):
        lat = carried.latencyMs.dropna()
        lines.append(f"store-carry-forward: {len(carried)} message(s) entered "
                     "a relay's custody"
                     + (f", carry→delivery median {lat.median() / 1000:.1f}s"
                        if len(lat) else ""))
    cust = df[df._type == "custody"]
    if not cust.empty:
        ev = cust.get("event").value_counts().to_dict()
        lines.append(f"custody events: {ev}")
    # Two distinct duplication questions — keep them apart:
    #   packetDup: redundant PACKETS on the air (dual-leg delivery, re-floods,
    #              custody conveyance), dropped by the packetId bloom;
    #   message dup: the same logical MESSAGE arriving again after it was
    #              already delivered — should be ~0, and is the correctness
    #              claim ("dedup means delivered exactly once").
    fresh = df[(df._type == "message") & (df.get("dir") == "recv")]
    pkt_dups = df[df._type == "packetDup"]
    msg_dups = df[(df._type == "message") & (df.get("dir") == "dup")]
    if len(fresh):
        lines.append(
            f"packet redundancy: {len(pkt_dups)} redundant packet arrival(s) "
            f"for {len(fresh)} delivered message(s) "
            f"= {1 + len(pkt_dups) / len(fresh):.2f} copies on the air per "
            "message (dual-leg pairs deliver every flood twice)")
        lines.append(
            f"message re-delivery: {len(msg_dups)} (must be 0 — a duplicate "
            "of an already-delivered message triggers nothing)")
    return "\n".join(lines) + "\n"


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
    roles = device_roles(df)
    lines = []
    t0, t1 = df._t.dropna().min(), df._t.dropna().max()
    lines.append(f"records: {len(df)}   span: {(t1 - t0) / 1000:.0f}s")
    for device, sub in df.groupby("_device"):
        lines.append(f"\n{label_for(device, roles)}:")
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
        if label in CONTROL_MARKERS:
            continue  # links-reset / sessions-reset — one per step, too noisy
        x = (m._t - t_base) / 1000
        ax.axvline(x, color="gray", linestyle=":", alpha=0.6)
        ax.annotate(str(label), (x, ax.get_ylim()[1]), fontsize=7,
                    rotation=90, va="top", ha="right", color="gray")


def plot_rssi(df: pd.DataFrame, out: Path):
    rssi = df[df._type == "rssi"]
    if rssi.empty:
        return
    t_base = df._t.dropna().min()
    roles = device_roles(df)
    fig, ax = plt.subplots(figsize=(11, 5))
    for (device, src), sub in rssi.groupby(["_device", "src"]):
        ax.plot((sub._t - t_base) / 1000, sub.rssi,
                marker="." if src == "adv" else "x", markersize=3,
                linestyle="none", label=f"{label_for(device, roles)} {src}", alpha=0.7)
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
    roles = device_roles(df)
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
            ylabels.append(f"{roles.get(device, short(device))}:{stage}")
    ax.set_yticks(yticks)
    ax.set_yticklabels(ylabels, fontsize=7)
    ax.set_xlabel("time (s)")
    ax.grid(alpha=0.3, axis="x")
    _marker_verticals(ax, df, t_base)
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)


def plot_wire(df: pd.DataFrame, out: Path):
    """tx bytes per 10s window, split by what the bytes carry.

    The ledger classifies by outer type; for OUR OWN sealed packets it also
    resolves the inner content at seal time, so tx `secure` arrives already
    split as `secure:data` / `secure:ack` / `secure:receipt` / `secure:sync`
    (exact, not inferred). Older traces predating that split show a single
    `secure` band. Rx is deliberately never split — a peer on the air cannot
    tell sealed content apart either.
    """
    wire = df[df._type == "wire"]
    if wire.empty:
        return
    t_base = df._t.dropna().min()
    roles = device_roles(df)
    devices = sorted(wire._device.unique())
    fig, axes = plt.subplots(len(devices), 1,
                             figsize=(11, 3.4 * len(devices)), squeeze=False)
    nice = {
        "announce": "announce",
        "handshake": "handshake",
        "secure": "secure (unsplit)",
        "secure:data": "secure: data",
        "secure:data:say": "secure: chat message",
        "secure:data:friendshipOffer": "secure: friend request",
        "secure:data:friendshipAccept": "secure: friend accept",
        "secure:data:friendshipRevoke": "secure: unfriend",
        "secure:data:testbed": "secure: testbed payload",
        "secure:data:other": "secure: data (other)",
        "secure:ack": "secure: ack",
        "secure:receipt": "secure: read receipt",
        "secure:sync": "secure: sync (custody)",
        "secure:signaling": "secure: signaling",
    }
    for ax, device in zip(axes[:, 0], devices):
        sub = wire[wire._device == device].sort_values("_t")
        keys: set[str] = set()
        for _, w in sub.iterrows():
            keys.update(_dict(w.get("txBytes")).keys())
        order = [k for k in nice if k in keys] + sorted(keys - set(nice))
        times, series = [], defaultdict(list)
        for _, w in sub.iterrows():
            tx = _dict(w.get("txBytes"))
            times.append((w._t - t_base) / 1000)
            for k in order:
                series[k].append(tx.get(k, 0))
        if times and order:
            ax.stackplot(times, *[series[k] for k in order],
                         labels=[nice.get(k, k) for k in order], alpha=0.85)
            ax.legend(fontsize=7, loc="upper right")
        ax.set_title(f"{label_for(device, roles)} — tx bytes / 10s window",
                     fontsize=10)
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
        roles = device_roles(edf)
        paths = mesh_paths(edf, roles)
        summary = summarize(edf, latency)
        if not paths.empty:
            paths.to_csv(out / "mesh_paths.csv", index=False)
            summary += mesh_summary(paths, edf)
        (out / "summary.txt").write_text(summary)
        if not latency.empty:
            latency.to_csv(out / "latency.csv", index=False)

        segs = marker_segments(edf)
        if segs:
            steps = steps_table(edf, segs, latency)
            steps.to_csv(out / "steps.csv", index=False)
            est = establishment_table(steps)
            if not est.empty:
                est.to_csv(out / "establishment.csv", index=False)
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
