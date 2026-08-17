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
    <exp>/steps.csv            one row per step marker segment (per repeat
                               trial): RSSI stats (adv/conn), stage events
                               seen, drops, delivery, and the per-step cost
                               metrics — payloadB, lanes, msg_per_s,
                               goodput_Bps, airB_per_msg and air_overhead
    <exp>/establishment.csv    repeat trials aggregated per (distance,
                               direction): fraction of trials that reached
                               each link stage — establishment probability
    <exp>/power_ladder.csv     power-baseline conditions per device: median
                               draw, SEM, and the delta against each
                               condition's baseline (charging samples and the
                               first 60 s of every segment excluded)
    <exp>/ladder.csv           establishment LATENCY per stage over all
                               trials: reach rate plus median/p90/max seconds
                               from the step marker to discovered / connected
                               / session / usable (usable = first ACK back)
    <exp>/pathloss.txt         log-distance fit RSSI = A - 10 n log10(d)
                               (needs >= 3 distinct d= markers)
    <exp>/rssi_timeline.png    RSSI vs time per device, markers as verticals
    <exp>/link_stages.png      link-stage event timeline per device
    <exp>/wire_bytes.png       tx/rx bytes per packet type over time
    <exp>/latency.csv          per-message e2e latency (sent joined to
                               delivered on messageId)
    <exp>/dial_probe.csv       dial grid: one row per establishment, keyed
                               (device, pop_n, m, rep), with the window's
                               establishment count and, per connection, ms
                               to GATT-usable / session / dual-leg converged
                               plus the in-flight dial count, live inbound
                               legs and total live legs at that instant.
                               pop_n = radios up, m = allowed parallel dials
    <exp>/dial_scores.csv      per (device, pop_n): establishments per window
                               at each m, the saturation knee (smallest m
                               already as good as the best), median ms to
                               usable / session / converged at the knee, and
                               the max in-flight / peripheral / TOTAL links
                               observed — the device's link-budget ceiling
    <exp>/dial_probe_N<n>.png  four shared-X panels of median-vs-m per device
                               at population n (p10-p90 bars): establishments
                               per window, then ms to GATT-usable, to Noise
                               session, to dual-leg convergence
    <exp>/dial_probe.png       the same figure at the largest population
                               present (the headline)

Markers drive the ground truth: every step marker opens a segment that runs
until the next one (or the ``end`` marker), and the step's variables are read
off its label — ``d=<m>``/``side=<m>`` for position, ``p=<n>B`` for the
throughput payload arm, ``lanes=<n>`` for the ceiling sweep,
``approach``/``retreat`` for sweep direction. A step
without a position (a stationary throughput step) still gets a row; it simply
has no distance. Runner control markers (resets, ``link-settled``,
``saturate-start``, ``end``) never open a segment.

Rates are computed over the ACTIVE window (first send -> last ACK), not the
marker span: the link teardown/handshake sits at a step's head and the
auto-advance gap at its tail, and nothing is sent in either — dividing by the
span understates throughput by ~40% in a typical cycle-check. ``active_s``
next to ``t0``/``t1`` makes the difference visible.

``airB_per_msg`` is every sealed byte both devices put on the air during the
step (data + acks + custody sync) divided by the messages delivered, and
``air_overhead`` is that over the payload size. This is what the payload arm
measures: a payload above one sealed packet (136 B) fragments, and each
fragment re-pays the full 100-byte header.

Usage:
    python3 analyze.py data/traces.db --out analysis
    python3 analyze.py exp_dry-1.jsonl other_device_exp_dry-1.jsonl --out analysis
    python3 analyze.py data/traces.db --exp dry-1 --out analysis

Dependencies: pandas, numpy, matplotlib (see analysis_requirements.txt).
"""
from __future__ import annotations

import argparse
import collections
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
# A payload-arm marker: `p=<n>B` (throughput arm). The size is also measured
# from the traffic itself; this is the declared value.
MARKER_PAYLOAD_RE = re.compile(r"\bp\s*=\s*(\d+)\s*B\b", re.I)
# A ceiling-sweep marker: `lanes=<n>` — how many sends were pushed
# concurrently, i.e. the offered-load knob.
MARKER_LANES_RE = re.compile(r"\blanes\s*=\s*(\d+)", re.I)
# A raw-link marker: `leg=<notify|write|stripe>` — which GATT leg the raw
# blobs rode.
MARKER_LEG_RE = re.compile(r"\bleg\s*=\s*(\w+)", re.I)
LINK_STAGES = ["discovered", "connected", "session", "usable", "drop"]
# FragmentHandler.fragmentThreshold: payloads above this are split, and each
# fragment gets a RANDOM packetId — so relay records can no longer be joined
# to the messageId and hop counts for such messages are not trustworthy.
FRAGMENT_THRESHOLD_B = 136  # 247 - 3 - (54 hdr + 25 noise + 21 frame) - 8
# Runner markers that annotate a boundary or an event but are not steps. Every
# OTHER marker opens a step segment — a throughput step ("saturate", "p=264B")
# has no position at all, and dropping it would make the whole experiment
# invisible in steps.csv.
CONTROL_MARKERS = {"links-reset", "sessions-reset", "custody-reset",
                   "link-settled", "saturate-start", "raw-start", "end",
                   "aborted",
                   # Manual-join lifecycle stamps: the shared-anchor proof,
                   # the radio transitions, and the battery stop. Events on
                   # the timeline, not dwell windows — as segments they were
                   # splitting real steps and polluting steps.csv.
                   "placement", "bt-on", "bt-off", "battery-floor"}
# Marker span != active time. A step's markers are all stamped at its start,
# and the auto-advance gap between steps trails the dwell, so rates are taken
# over the ACTIVE window (first send -> last ACK) instead. See steps_table.


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


def _drop_pre_arm(df: pd.DataFrame) -> pd.DataFrame:
    """Keep only the arm that counted, when a device was armed more than once.

    A phone can be armed, aborted and armed again (field day 2026-08-08: one
    tapped ~10 min early caught the earlier wall-clock boundary, ran alone for
    7 s against peers whose recorders were not up, and was aborted). The
    abandoned arm stamps ordinary step labels — `n=3 t1` is indistinguishable
    from the real one — so it reads as an extra rep unless it is cut here.

    Which arm counted is READ, not guessed: the runner stamps `end` when a run
    finishes and `aborted` when it is abandoned. Per device the records are
    split at its `placement` markers, and the block kept is the last one
    containing an `end` — or the last block if none does (nothing completed,
    so the latest arm is the live one). Keeping a block rather than a floor is
    what stops a stray re-arm at the tail from deleting a COMPLETED run.

    The cut is then id-aware. Message ids are UUIDv5 over
    `field|expId|src|dst|step|seq` with no per-run term, so an abandoned arm
    mints ids identical to the real run's. Cutting only the re-armed device
    leaves its peers' `recv` rows behind, and those join the real run's later
    `sent` for the same id — which manufactures negative latencies and trips
    the "every latency is biased LOW" verdict. Those ids are unusable either
    way: the receiver's packet bloom saw them during the abandoned arm, so the
    real run's copies were dropped as duplicates and never delivered. They
    leave on every device.

    The recording is not modified: the abandoned arm stays in the trace, it
    simply stops being read as part of the run.
    """
    if df.empty or "_device" not in df.columns:
        return df
    marks = df[df._type == "marker"]
    if marks.empty:
        # main() forces `marker` into any --types set precisely so this
        # cannot silently pass an unguarded frame through.
        print("  WARNING: no marker records loaded — re-arm guard INACTIVE")
        return df
    labels = _col(marks, "label")
    placements = marks[labels == "placement"]
    if placements.empty:
        return df

    keep = pd.Series(True, index=df.index)
    abandoned = pd.Series(False, index=df.index)
    cuts = []
    completed_elsewhere = []
    for dev, pl in placements.groupby("_device"):
        arms = sorted(pl._t.tolist())
        if len(arms) < 2:
            continue
        dev_marks = marks[marks._device == dev]
        ends = sorted(dev_marks[_col(dev_marks, "label") == "end"]._t.tolist())
        chosen = len(arms) - 1
        for i, lo in enumerate(arms):
            hi = arms[i + 1] if i + 1 < len(arms) else math.inf
            if any(lo <= e < hi for e in ends):
                chosen = i
        mine = df._device == dev
        for i, lo in enumerate(arms):
            if i == chosen:
                continue
            hi = arms[i + 1] if i + 1 < len(arms) else math.inf
            block = mine & (df._t >= lo) & (df._t < hi)
            n = int(block.sum())
            if not n:
                continue
            keep &= ~block
            # Whether THIS block finished decides whether its ids are dead.
            if any(lo <= e < hi for e in ends):
                completed_elsewhere.append((str(dev)[:8], n))
            else:
                abandoned |= block
            cuts.append((str(dev)[:8], len(arms), n))
    if not cuts:
        return df

    # Ids from an ABANDONED arm are dead everywhere: the receiver's bloom saw
    # them, so the surviving run's copies were dropped as duplicates. Ids from
    # a COMPLETED earlier run are NOT dead — message ids carry no per-run term,
    # so two runs under one experiment id mint the SAME ids, and tainting them
    # would delete the surviving run's own traffic. That mistake cost 65k
    # records on 2026-08-10 before it was caught.
    tainted: set[str] = set()
    dropped = df[abandoned]
    for col in ("messageId", "packetId"):
        if col in dropped.columns:
            tainted |= {str(v) for v in dropped[col].dropna()}
    extra = 0
    if tainted:
        hit = pd.Series(False, index=df.index)
        for col in ("messageId", "packetId"):
            if col in df.columns:
                hit |= df[col].astype(str).isin(tainted)
        hit &= keep
        extra = int(hit.sum())
        keep &= ~hit

    for dev, arms, n in cuts:
        print(f"  re-arm: {dev} armed {arms}x, {n} record(s) outside the arm "
              f"that counted ignored")
    if completed_elsewhere:
        devs = sorted({d for d, _ in completed_elsewhere})
        tot = sum(n for _, n in completed_elsewhere)
        print(f"  !! {len(devs)} device(s) recorded MORE THAN ONE COMPLETE run "
              f"under this experiment id ({tot} record(s) in the earlier "
              f"run(s), ignored). Only the last is analysed. Message ids carry "
              f"no per-run term, so the runs share ids — split the ids and "
              f"re-record rather than trusting a merge.")
    if extra:
        print(f"  re-arm: {extra} further record(s) on other devices carried "
              f"ids minted by a dropped arm — dead on arrival, also ignored")
    return df[keep]


def load_db(path: Path, exp: str | None = None,
            types: set[str] | None = None) -> pd.DataFrame:
    """Load records, filtering in SQL rather than in pandas.

    A saturating multi-hour run is millions of records, and materialising all
    of them as dicts before building one sparse DataFrame is what gets the
    process OOM-killed. Both filters are pushed into the query so the rows
    are never read, and the cursor is streamed rather than fetchall'd.

    The type filter is the big lever: message/custody/session records are
    routinely 99.5% of a trace, while a power ladder needs only `power` and
    `marker` — a thousandfold reduction for that analysis.
    """
    conn = sqlite3.connect(path)
    sql = "SELECT upload_id, device_id, type, t, body FROM records"
    where, params = [], []
    if exp:
        # upload_id is "exp_<name>.jsonl:<len>[:<chunk>]", so match the prefix.
        where.append("upload_id LIKE ?")
        params.append(f"exp_{exp}.jsonl%")
    if types:
        where.append(f"type IN ({','.join('?' * len(types))})")
        params.extend(sorted(types))
    if where:
        sql += " WHERE " + " AND ".join(where)
    cur = conn.execute(sql, params)
    out = []
    while True:
        rows = cur.fetchmany(50_000)
        if not rows:
            break
        for upload_id, device_id, rtype, t, body in rows:
            rec = json.loads(body)
            rec["_exp"] = _exp_from_upload_id(upload_id)
            rec["_device"] = device_id
            rec["_type"] = rtype
            rec["_t"] = t
            out.append(rec)
    conn.close()
    if not out and (exp or types):
        print(f"  no records matched (exp={exp}, types={types})",
              file=sys.stderr)
    return pd.DataFrame(out)


def load_jsonl(paths: list[Path]) -> pd.DataFrame:
    """Load exp_*.jsonl, tolerating a damaged tail.

    Read with errors="replace", not strictly: a record file is appended to
    repeatedly during a run, so a process kill mid-append can leave a partial
    line — and one bad byte would otherwise cost the entire file. The
    replacement char makes that line fail json.loads and be skipped, which is
    the behaviour the per-line handler already wanted. Damaged lines are
    counted and reported rather than dropped silently: a trace with holes
    must not read as a trace without them.
    """
    out = []
    for p in paths:
        stem = p.stem  # exp_dry-1 -> device label fallback = file stem
        exp = stem[len("exp_"):] if stem.startswith("exp_") else stem
        skipped = 0
        for line in p.read_text(errors="replace").splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                skipped += 1
                continue
            rec["_exp"] = exp
            rec["_device"] = stem
            rec["_type"] = rec.get("type")
            rec["_t"] = rec.get("t")
            out.append(rec)
        if skipped:
            print(f"  [{p.name}] skipped {skipped} unparseable line(s)",
                  file=sys.stderr)
    return pd.DataFrame(out)


def short(device: str) -> str:
    return device[:8]


def device_roles(df: pd.DataFrame) -> dict[str, str]:
    """Human roles instead of pubkey hex.

    The device that runs the plan stamps the step markers and originates the
    workload — the *sender* (the moving device in static+moving mode). A
    device that only forwards other people's packets is a *relay* (the middle
    node of a multi-hop run, which by design never sends or receives the
    traffic it carries). The device that receives and ACKs is the *receiver*.
    Ties or 3+-device runs fall back to numbered labels so they stay unique.
    """
    roles: dict[str, str] = {}
    msgs = df[df._type == "message"]
    relays = df[df._type == "relay"]
    senders, receivers, forwarders = [], [], []
    for device in sorted(df._device.unique()):
        sub = msgs[msgs._device == device]
        sends = int((_col(sub, "dir") == "sent").sum()) if len(sub) else 0
        recvs = int((_col(sub, "dir") == "recv").sum()) if len(sub) else 0
        forwards = int((relays._device == device).sum()) if len(relays) else 0
        if sends > 0:
            senders.append(device)
        elif recvs > 0:
            receivers.append(device)
        elif forwards > 0:
            forwarders.append(device)
        else:
            receivers.append(device)
    for group, name in ((senders, "sender"), (forwarders, "relay"),
                        (receivers, "receiver")):
        for i, d in enumerate(group):
            roles[d] = name if len(group) == 1 else f"{name}{i + 1}"
    return roles


def label_for(device: str, roles: dict[str, str]) -> str:
    """`sender (3c1a075c)` — role first, hex kept for traceability."""
    role = roles.get(device)
    return f"{role} ({short(device)})" if role else short(device)


def _dict(v) -> dict:
    """A record field that should be a dict; pandas yields NaN when absent."""
    return v if isinstance(v, dict) else {}


def _col(df: pd.DataFrame, name: str) -> pd.Series:
    """A record field that may be absent from THIS trace, as an index-aligned
    Series. `df.get(name)` returns None when the column is missing, and
    `None == "x"` is the scalar False — which pandas then rejects as an
    indexer, so a trace that happens to contain no such record crashes the
    run. This keeps the comparison a proper all-False mask.
    """
    if name in df.columns:
        return df[name]
    return pd.Series([None] * len(df), index=df.index, dtype=object)


def _num(v, default=0):
    """A numeric record field; NaN (missing) becomes the default."""
    return default if v is None or (isinstance(v, float) and math.isnan(v)) else v


# --------------------------------------------------------------------------- #
# Per-experiment analyses
# --------------------------------------------------------------------------- #
def marker_segments(df: pd.DataFrame) -> list[dict]:
    """One segment per step marker: [{d, payloadB, direction, label, t0, t1}].

    Every marker that is not a runner control marker opens a segment, and its
    step variables are read off the label where present: `d=`/`side=` gives the
    position (NaN for a stationary step), `p=<n>B` the declared payload size.
    Repeat trials carry distinct labels (…t1, …t2), so each stays its own
    segment. In static+moving mode only the moving device stamps step markers;
    the static device's records fall into these segments by timestamp. A
    duplicate identical label within 90s (both devices stamping) collapses to
    the earlier one.
    """
    markers = df[(df._type == "marker")].sort_values("_t")
    segs: list[dict] = []
    end_t = None
    for _, m in markers.iterrows():
        # expStart/expStop carry `event`, not `label` — lifecycle, not a step.
        # (A missing field is NaN, which is truthy: test for str, not falsiness.)
        raw = m.get("label")
        label = raw if isinstance(raw, str) else ""
        # The runner stamps `end` when the last dwell finishes, BEFORE the
        # settle window. Closing the final segment there keeps per-second
        # rates honest — settle time carries late ACKs, not sends.
        if label in ("end", "aborted") and end_t is None:
            end_t = m._t
        if not label or label in CONTROL_MARKERS:
            continue
        # The same label from ANOTHER device is the same step: every phone
        # stamps each step at the shared wall-clock start, so cross-device
        # duplicates need no time tolerance — device identity decides. The
        # same label from the SAME device is the plan repeating a label, a
        # new step. (This replaces a 90 s window that would have merged any
        # same-device repeat closer than 90 s and split cross-device stamps
        # skewed wider — both fictions.)
        if segs and segs[-1]["label"] == label \
                and str(m._device) != segs[-1]["dev"]:
            continue
        if segs:
            segs[-1]["t1"] = m._t
        pos = MARKER_POS_RE.search(label)
        payload = MARKER_PAYLOAD_RE.search(label)
        lanes = MARKER_LANES_RE.search(label)
        leg = MARKER_LEG_RE.search(label)
        direction = (
            "approach"
            if "approach" in label.lower()
            else "retreat" if "retreat" in label.lower() else ""
        )
        segs.append({"d": float(pos.group(1)) if pos else float("nan"),
                     "payloadB": int(payload.group(1)) if payload else None,
                     "lanes": int(lanes.group(1)) if lanes else None,
                     "leg": leg.group(1) if leg else None,
                     "direction": direction, "dev": str(m._device),
                     "label": label, "t0": m._t, "t1": None})
    end = end_t if end_t is not None else df._t.dropna().max()
    if segs and segs[-1]["t1"] is None:
        segs[-1]["t1"] = end
    return segs


def steps_table(df: pd.DataFrame, segs: list[dict],
                latency: pd.DataFrame) -> pd.DataFrame:
    rssi = df[df._type == "rssi"]
    link = df[df._type == "link"]
    msgs = df[df._type == "message"]
    wire = df[df._type == "wire"]
    power = df[df._type == "power"]
    rows = []
    for seg in segs:
        in_seg_rssi = rssi[(rssi._t >= seg["t0"]) & (rssi._t < seg["t1"])]
        in_seg_link = link[(link._t >= seg["t0"]) & (link._t < seg["t1"])]
        # Messages SENT within this step (by any device) and their round-trip
        # latency — the WIRE RTT (deliveredAt - the sent record's own stamp),
        # not the app's create->ACK figure. Gives the latency-vs-distance
        # curve and the per-step delivery ratio.
        seg_msgs = (
            latency[(latency.sentAt >= seg["t0"]) & (latency.sentAt < seg["t1"])]
            if not latency.empty else latency
        )
        dwell_sec = max((seg["t1"] - seg["t0"]) / 1000.0, 1e-9)
        adv = in_seg_rssi[_col(in_seg_rssi, "src") == "adv"]
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
        # Payload size MEASURED from the step's own sends (the label's `p=`
        # value is only the declaration); this also fills it in for steps whose
        # label says nothing about payload.
        seg_rows = msgs[(msgs._t >= seg["t0"]) & (msgs._t < seg["t1"])]
        # `sent` and `recv` records both carry it; `delivered`/`dup` do not.
        sizes = (seg_rows["payloadSize"].dropna()
                 if "payloadSize" in seg_rows.columns else pd.Series(dtype=float))
        payload_b = int(sizes.median()) if len(sizes) else seg["payloadB"]
        # ACTIVE window: first send -> last ACK. The marker span is longer than
        # the step actually worked — the link teardown/handshake sits at its
        # head and the auto-advance gap at its tail, and nothing is sent in
        # either. Dividing by the marker span understates every rate (in a
        # 5x60s cycle-check by ~40%), so rates use this window and the table
        # reports it as active_s next to the span.
        sent_t = (seg_rows[seg_rows["dir"] == "sent"]["_t"]
                  if "dir" in seg_rows.columns else pd.Series(dtype=float))
        # Total SEALED bytes this step put on the air, both devices, all
        # content (data + acks + custody sync). Divided by the delivered
        # messages this is the real per-message cost — the number the payload
        # arm exists to produce, since a payload above one packet pays a full
        # 104-byte header again per fragment. Wire records are drained on a
        # timer, so counts at a segment boundary can spill by one window.
        in_seg_wire = wire[(wire._t >= seg["t0"]) & (wire._t < seg["t1"])]
        air_b = 0
        raw_tx = raw_rx = 0
        raw_tx_windows = raw_rx_windows = 0
        for _, w in in_seg_wire.iterrows():
            for key, val in _dict(w.get("txBytes")).items():
                if str(key).startswith("secure"):
                    air_b += int(val)
                if key == "raw":
                    raw_tx += int(val)
                    raw_tx_windows += 1
            rxr = int(_dict(w.get("rxBytes")).get("raw", 0))
            if rxr:
                raw_rx += rxr
                raw_rx_windows += 1
        row = {
            "d": seg["d"],
            "payloadB": payload_b,
            "lanes": seg["lanes"],
            "leg": seg["leg"],
            "direction": seg["direction"],
            "label": seg["label"],
            "t0": seg["t0"],
            "t1": seg["t1"],
            "rssi_n": len(in_seg_rssi),
            "advPerMin": round(len(adv) / (dwell_sec / 60.0), 1),
            "advCoverage": round(len(adv_seconds) / dwell_sec, 3),
        }
        # Fuel-gauge power per step, PER DEVICE (columns suffixed with the
        # device's short id — absolute draw is dominated by the screen and
        # differs per phone, so never pool across devices; compare steps
        # WITHIN a device). Samples taken while charging are excluded: a
        # plugged-in phone reports charge current, not consumption.
        in_seg_pw = power[(power._t >= seg["t0"]) & (power._t < seg["t1"])]
        for dev, g in in_seg_pw.groupby("_device"):
            tag = str(dev)[:8]
            # astype(bool) matters: the column loads as object dtype and `~`
            # on objects is BITWISE (True -> -2), which then indexes columns.
            chg_mask = _col(g, "charging").fillna(False).astype(bool)
            ok = g[~chg_mask]
            cur = pd.to_numeric(_col(ok, "currentNowUa"),
                                errors="coerce").dropna()
            if len(cur):
                row[f"power_mA_{tag}"] = round(cur.abs().median() / 1000, 1)
            cc = pd.to_numeric(_col(ok, "chargeCounterUah"),
                               errors="coerce").dropna()
            if len(cc) >= 2:
                # Discharge over the step (positive = energy spent).
                row[f"energy_mAh_{tag}"] = round(
                    (cc.iloc[0] - cc.iloc[-1]) / 1000, 3)
            if chg_mask.any():
                row[f"power_charging_{tag}"] = True

        if raw_tx or raw_rx:
            # Raw-link step: offered vs carried BYTES from the wire ledgers
            # (sender tx, receiver rx). No messages exist in this mode. The
            # denominator is windows-with-raw x the ledger's fixed 10s drain
            # period, not the marker span — the span includes the settle
            # before raw-start and the auto-advance gap, which understated
            # every rate ~14% on the synthetic check.
            row["raw_tx_Bps"] = (round(raw_tx / (raw_tx_windows * 10), 1)
                                 if raw_tx_windows else 0.0)
            row["raw_rx_Bps"] = (round(raw_rx / (raw_rx_windows * 10), 1)
                                 if raw_rx_windows else 0.0)
            row["raw_loss"] = (round(1 - raw_rx / raw_tx, 3)
                               if raw_tx else None)
        if len(seg_msgs):
            sent_n = len(seg_msgs)
            lat = seg_msgs["latencyMs"].dropna()
            recv_n = int(seg_msgs["receivedAt"].notna().sum())
            row["msg_sent"] = sent_n
            # One-way: the receiver logged the message. THE reachability
            # numerator (received/sent per distance).
            row["msg_recv"] = recv_n
            row["recv_rate"] = round(recv_n / sent_n, 3)
            # Round trip: the ACK made it back to the sender too.
            row["msg_delivered"] = int(len(lat))
            row["delivery_rate"] = round(len(lat) / sent_n, 3)
            # Most complete arrival evidence: a message ARRIVED if the receiver
            # logged `recv` OR an ACK came back (an ACK is proof of receipt).
            # `recv` alone misses arrivals whose recv record was never written
            # but whose ACK returned; `delivered` alone misses arrivals whose
            # ACK was lost on the return path. The union recovers both, so it is
            # the honest reachability numerator when either log has holes.
            arrived_n = int((seg_msgs["receivedAt"].notna()
                             | seg_msgs["latencyMs"].notna()).sum())
            row["msg_arrived"] = arrived_n
            row["arrival_rate"] = round(arrived_n / sent_n, 3)
            row["rtt_median_ms"] = round(lat.median()) if len(lat) else None
            row["rtt_p90_ms"] = round(lat.quantile(0.9)) if len(lat) else None
            applat = pd.to_numeric(seg_msgs.get("appLatencyMs"),
                                   errors="coerce").dropna()
            row["applat_median_ms"] = (round(applat.median())
                                       if len(applat) else None)
            # Throughput: delivered (ACKed) messages only — a send that never
            # landed moved no data.
            acked_t = (seg_msgs.sentAt + seg_msgs.latencyMs).dropna()
            active_t0 = sent_t.min() if len(sent_t) else seg["t0"]
            active_t1 = max(
                sent_t.max() if len(sent_t) else seg["t0"],
                acked_t.max() if len(acked_t) else seg["t0"],
            )
            active_sec = max((active_t1 - active_t0) / 1000.0, 1e-9)
            row["active_s"] = round(active_sec, 1)
            row["msg_per_s"] = round(len(lat) / active_sec, 2)
            row["goodput_Bps"] = (round(len(lat) * payload_b / active_sec, 1)
                                  if payload_b else None)
            row["airB_per_msg"] = (round(air_b / len(lat), 1)
                                   if len(lat) else None)
            row["air_overhead"] = (round(air_b / (len(lat) * payload_b), 2)
                                   if len(lat) and payload_b else None)
        else:
            row.update({"msg_sent": 0, "msg_recv": 0, "recv_rate": None,
                        "msg_delivered": 0, "msg_arrived": 0,
                        "arrival_rate": None,
                        "delivery_rate": None, "rtt_median_ms": None,
                        "rtt_p90_ms": None, "applat_median_ms": None,
                        "active_s": None, "msg_per_s": None,
                        "goodput_Bps": None, "airB_per_msg": None,
                        "air_overhead": None})
        for src in ("adv", "conn"):
            vals = _col(in_seg_rssi[_col(in_seg_rssi, "src") == src],
                        "rssi").dropna()
            row[f"rssi_{src}_mean"] = round(vals.mean(), 1) if len(vals) else None
            row[f"rssi_{src}_std"] = round(vals.std(), 1) if len(vals) > 1 else None
        # Establishment LATENCY, not just whether the stage happened: seconds
        # from the step marker to the first time each stage is reached. With
        # resetLinks on, every step starts from a torn-down link, so this is a
        # cold discovered->connected->session->usable ladder per trial and the
        # percentiles over many trials are the establishment result itself.
        for stage in LINK_STAGES:
            if stage == "drop":
                continue
            hit = in_seg_link[_col(in_seg_link, "event") == stage]
            row[f"t_{stage}_s"] = (round((hit._t.min() - seg["t0"]) / 1000.0, 2)
                                   if len(hit) else None)
        for stage in LINK_STAGES:
            row[stage] = int((_col(in_seg_link, "event") == stage).sum())
        rows.append(row)
    return pd.DataFrame(rows)


def pathloss_coeffs(steps: pd.DataFrame) -> tuple[float, float, float, int] | None:
    """`(A, n, residual_std, n_distances)` of the log-distance fit
    RSSI = A - 10 n log10(d), over the per-distance mean adv RSSI so repeat
    trials at a distance don't over-weight it. None when fewer than three
    distances carry an RSSI mean — two points fit any line exactly."""
    if steps.empty or "rssi_adv_mean" not in steps.columns:
        return None
    pts = steps.dropna(subset=["rssi_adv_mean"])
    pts = pts[pts.d > 0]
    if pts.d.nunique() < 3:
        return None
    means = pts.groupby("d")["rssi_adv_mean"].mean()
    x = 10 * np.log10(means.index.to_numpy(dtype=float))
    y = means.to_numpy(dtype=float)
    n, a = np.polyfit(-x, y, 1)  # y = a - n * x
    resid = y - (a - n * x)
    return float(a), float(n), float(resid.std()), len(means)


def pathloss_fit(steps: pd.DataFrame) -> str | None:
    """The log-distance fit as the text block `pathloss.txt` carries."""
    fit = pathloss_coeffs(steps)
    if fit is None:
        return None
    a, n, resid_std, n_d = fit
    return (
        f"log-distance fit over {n_d} distances "
        f"(per-distance mean adv RSSI):\n"
        f"  RSSI(d) = {a:.1f} - 10 * {n:.2f} * log10(d)\n"
        f"  path-loss exponent n = {n:.2f}, RSSI@1m = {a:.1f} dBm, "
        f"residual std = {resid_std:.1f} dB\n"
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
        recv_n = g["msg_recv"].sum()
        deliv = g["msg_delivered"].sum()
        # received/sent is the one-way reachability curve vs distance;
        # acked/sent additionally requires the reverse path.
        row["msg_sent"] = int(sent)
        row["recv_rate"] = round(recv_n / sent, 3) if sent else None
        row["delivery_rate"] = round(deliv / sent, 3) if sent else None
        rtt = g["rtt_median_ms"].dropna()
        row["rtt_median_ms"] = round(rtt.mean()) if len(rtt) else None
        rows.append(row)
    # No rows when no step declared a position (a stationary experiment such
    # as the throughput arm): there is no distance to aggregate over.
    if not rows:
        return pd.DataFrame()
    return pd.DataFrame(rows).sort_values(["direction", "d"])


def mesh_paths(df: pd.DataFrame, roles: dict[str, str]) -> pd.DataFrame:
    """Reconstruct each message's actual path through the mesh.

    A message is `sent` by one device, may be forwarded by relays (each logs a
    `relay` record for the packet it forwarded), and is `recv`d by the
    recipient. Joining those on the packet/message id across devices gives the
    real path — the only direct evidence of multi-hop delivery, since the
    envelope is sender-anonymous and no single device sees the whole route.

    Single-packet messages use packetId == messageId, so the ids join
    directly. FRAGMENTED messages do not: each fragment carries a random
    packetId, so relay records cannot be matched to the messageId and such a
    message reports relayHops 0 even when it was relayed. The column
    `fragmented` flags those rows so the hop counts are not read as truth.

    Ordering: when relays log `fromPeer` (the authenticated neighbour that
    handed them the packet) the chain is built from those EDGES — the actual
    topology. Only hops whose edge is unknown fall back to time ordering,
    which is an inference and is marked in `pathExact`.
    """
    msgs = df[df._type == "message"]
    if msgs.empty:
        return pd.DataFrame()
    relays = df[df._type == "relay"]
    sent = msgs[_col(msgs, "dir") == "sent"]
    recv = msgs[_col(msgs, "dir") == "recv"]
    if sent.empty:
        return pd.DataFrame()
    # One sent per messageId: the FIRST is the origination. A held message
    # re-sealed after a later session logs a real second transmission, and
    # joining a delivery to that re-send manufactures a negative latency.
    sent = sent.sort_values("_t").drop_duplicates(subset="messageId",
                                                  keep="first")

    # Hops as plain dicts holding only the four fields the walk reads, built
    # from column arrays. `relays.iterrows()` mints a pandas Series per row —
    # on a field trace that is millions of Series, each carrying the whole
    # merged column set, and the dict holds them all at once: gigabytes to
    # store what is really four scalars a row.
    relay_by_id: dict[str, list] = defaultdict(list)
    if not relays.empty:
        def _arr(name):
            return (relays[name].to_numpy() if name in relays.columns
                    else np.full(len(relays), None, dtype=object))
        r_pkt, r_ev = _arr("packetId"), _arr("event")
        r_from, r_carried = _arr("fromPeer"), _arr("carried")
        r_t, r_dev = _arr("_t"), _arr("_device")
        for i in range(len(relays)):
            if r_ev[i] == "dup":
                continue
            relay_by_id[str(r_pkt[i])].append({
                "_t": r_t[i], "_device": r_dev[i],
                "fromPeer": r_from[i], "carried": r_carried[i],
            })

    # Deliveries indexed by messageId, ONCE. Filtering `recv` per sent message
    # instead is O(sent x recv): a boolean mask over an object column, rebuilt
    # for every send. At field scale (millions of message records) that is
    # days of CPU — it only looked fine on desk-sized traces, where both sides
    # are a few hundred rows. Only the first delivery per id is ever read, so
    # the index keeps exactly that, in the frame's own order.

    recv_first: dict[str, pd.Series] = {}
    if not recv.empty and "messageId" in recv.columns:
        for _, r in recv.drop_duplicates(subset="messageId",
                                         keep="first").iterrows():
            recv_first[str(r.get("messageId"))] = r

    # Devices seen in this run, so an edge can be labelled by role.
    def label(dev: str) -> str:
        return roles.get(dev, short(dev))

    rows = []
    for _, s_row in sent.iterrows():
        mid = str(s_row.get("messageId"))
        hops = sorted(relay_by_id.get(mid, []), key=lambda r: r["_t"])
        got = recv_first.get(mid)
        delivered = got is not None

        # Edge-based chain: every hop names the peer it received FROM, so the
        # parent of each forwarder is known rather than guessed. Walk forward
        # from the sender, following whoever received from the current node.
        by_parent: dict[str, list] = defaultdict(list)
        edges_known = True
        for h in hops:
            parent = h.get("fromPeer")
            if parent is None or (isinstance(parent, float) and pd.isna(parent)):
                edges_known = False
                break
            by_parent[str(parent)].append(h)
        if delivered:
            last = got.get("fromPeer")
            if last is None or (isinstance(last, float) and pd.isna(last)):
                edges_known = False

        path_devs = [s_row._device]
        if edges_known and hops:
            cursor = str(s_row._device)
            seen_hops = 0
            while by_parent.get(cursor):
                nxt = by_parent[cursor].pop(0)
                path_devs.append(nxt["_device"])
                cursor = str(nxt["_device"])
                seen_hops += 1
            # A hop nobody claims as a child means the chain forked or a
            # forwarder's parent was outside the experiment: fall back.
            if seen_hops != len(hops):
                edges_known = False
        if not edges_known:
            path_devs = [s_row._device] + [h["_device"] for h in hops]
        if delivered:
            path_devs.append(got._device)

        rows.append({
            "messageId": mid,
            "sentAt": s_row._t,
            "path": " -> ".join(label(str(d)) for d in path_devs),
            # True/False only when the chain HAS edges to verify; a message
            # that was never received and never relayed has no path at all,
            # and calling that "exact" would be vacuous.
            "pathExact": (bool(edges_known)
                          if (len(hops) + (1 if delivered else 0)) > 0
                          else None),
            "relayHops": len(hops),
            "fragmented": bool(
                (s_row.get("payloadSize") or 0) > FRAGMENT_THRESHOLD_B),
            "delivered": delivered,
            "deliveredAt": int(got._t) if delivered else None,
            "latencyMs": int(got._t - s_row._t) if delivered else None,
            # The receiver's own view of distance travelled (TTL drop).
            "recvRelayHops": (int(got.get("relayHops"))
                              if delivered and pd.notna(got.get("relayHops"))
                              else None),
            "carried": any(bool(h.get("carried")) for h in hops),
        })
    return pd.DataFrame(rows)


def mesh_summary(paths: pd.DataFrame, df: pd.DataFrame,
                 clocks: dict | None = None) -> str:
    """Hop-count distribution, relay/custody evidence, duplication factor."""
    if paths.empty:
        return ""
    lines = ["", "=== mesh ==="]
    # Cross-device latency is only as good as the clocks AND the stamps.
    # Both are measured here, separately, so neither is inferred:
    #
    # Clocks — every phone stamps each step marker at the shared wall-clock
    # instant, so cross-device deltas of the same label ARE the clock
    # offsets, message-independent.
    #
    # Stamps — a negative one-way latency is physically impossible; once the
    # markers prove the clocks agree, a negative can only be the recorder
    # stamping `sent` after the wire write (the receiver logged the arrival
    # before the sender's own stamp ran). That bias shrinks every latency,
    # not just the ones it pushes below zero.
    # Measured clock offsets, from tools/sync_phone_clocks.sh --json. This is
    # the ONLY sound source for them. The marker-derived number below cannot
    # be one: in a manual-join run every phone stamps its step markers at the
    # same SCHEDULED epoch, so a phone whose clock is 22 s slow writes exactly
    # the same timestamp as everyone else and simply reaches it 22 s late. The
    # markers measure how well the phones agree on the SCHEDULE, not on the
    # time — and in a tap-anchored run they measure the spread of the taps.
    # Both were previously printed as "device clocks", which on 2026-08-08
    # reported a 0.017 s spread for a fleet holding a 22 s offset, and on the
    # tap-anchored run before it labelled a phone that started 10 min early as
    # a -640 s clock error.
    if clocks:
        measured = []
        for d in clocks.get("devices", []):
            pk = str(d.get("pubkey") or "").lower()
            if not pk:
                continue
            hit = [dev for dev in df._device.dropna().unique()
                   if str(dev).lower().startswith(pk)]
            for dev in hit:
                measured.append((str(dev), float(d.get("offsetS") or 0.0),
                                 float(d.get("errS") or 0.0),
                                 str(d.get("model") or "")))
        if measured:
            roles_m = device_roles(df)
            lines.append("measured clock offsets (tools/sync_phone_clocks.sh, "
                         f"synced {clocks.get('measuredAtMs')}):")
            for dev, off, err, model in sorted(measured, key=lambda m: -abs(m[1])):
                lines.append(f"  {label_for(dev, roles_m)} {model} "
                             f"{off:+.3f}s ±{err:.3f}s")
            unmapped = [d.get("serial") for d in clocks.get("devices", [])
                        if not d.get("pubkey")]
            if unmapped:
                lines.append(f"  {len(unmapped)} synced device(s) have no "
                             f"pubkey in tools/fleet_map.json and are not "
                             f"shown: {', '.join(str(u) for u in unmapped)}")
        else:
            lines.append("!! --clocks given but no device matched this "
                         "experiment (fill tools/fleet_map.json with "
                         "serial -> pubkey)")
    else:
        lines.append("!! clock offsets NOT measured for this run — pass "
                     "--clocks from tools/sync_phone_clocks.sh --json. Every "
                     "cross-device latency below is uncorrected and carries "
                     "whatever offset the phones held.")

    marks = df[(df._type == "marker")]
    lbl = marks.get("label")
    lbl = lbl if lbl is not None else pd.Series(dtype=object)
    step_marks = marks[lbl.apply(lambda v: isinstance(v, str))
                       & ~lbl.isin(CONTROL_MARKERS)]
    offsets = {}
    if not step_marks.empty:
        firsts = (step_marks.sort_values("_t")
                  .drop_duplicates(subset=["label", "_device"], keep="first"))
        shared = firsts.groupby("label").filter(
            lambda g: g._device.nunique() > 1)
        if not shared.empty:
            med = shared.groupby("label")._t.transform("median")
            per_dev = (shared._t - med).groupby(shared._device).median()
            offsets = {str(d): v for d, v in per_dev.items()}
    spread = (max(offsets.values()) - min(offsets.values())) if offsets else None
    if offsets:
        roles = device_roles(df)
        parts = " ".join(
            f"{label_for(d, roles)} {v / 1000:+.3f}s"
            for d, v in sorted(offsets.items()))
        lines.append(f"step scheduling spread (NOT clock offset): {parts} "
                     f"— max spread {spread / 1000:.3f}s. This is how closely "
                     f"the phones agreed on WHEN each step opens; a constant "
                     f"clock offset is invisible to it.")
    neg = paths[paths.latencyMs.notna() & (paths.latencyMs < 0)].copy()
    if len(neg):
        lines.append(f"!! {len(neg)} impossible orderings "
                     "(delivery logged before the send):")
        ends = neg.path.str.split(" -> ")
        neg["endpoints"] = ends.str[0] + " -> " + ends.str[-1]
        for pair, grp in neg.groupby("endpoints"):
            off = -grp.latencyMs.min() / 1000
            lines.append(f"!!   {pair}: {len(grp)} msg, worst {off:.1f}s")
        worst = -neg.latencyMs.min() / 1000
        if clocks:
            lines.append(
                f"!! worst impossible ordering is {worst:.1f}s. Compare it "
                "against the MEASURED offsets above: a pair whose offsets "
                "differ by about that much is a clock artifact, and anything "
                "left over is the sender's own sent stamp lagging the wire "
                "write. Both shrink latency, neither is corrected here.")
        elif spread is not None:
            lines.append(
                f"!! {worst:.1f}s of impossible ordering, and the clocks were "
                "NOT measured for this run — the scheduling spread above "
                f"({spread / 1000:.3f}s) cannot bound it, because scheduled "
                "markers cannot see a clock offset. Do not attribute this to "
                "sent-stamp lag without --clocks.")
        else:
            lines.append(
                "!! no shared step markers in this run: cannot separate "
                "clock skew from sent-stamp lag — treat e2e latency with "
                "suspicion")
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
        ev = _col(cust, "event").value_counts().to_dict()
        lines.append(f"custody events: {ev}")
    # Two distinct duplication questions — keep them apart:
    #   packetDup: redundant PACKETS on the air (dual-leg delivery, re-floods,
    #              custody conveyance), dropped by the packetId bloom;
    #   message dup: the same logical MESSAGE arriving again after it was
    #              already delivered — should be ~0, and is the correctness
    #              claim ("dedup means delivered exactly once").
    # Raw-link runs: totals over the WHOLE recording (boundary drain windows
    # cancel run-wide; per-step loss columns are polluted by the 10s drain
    # phase crossing step boundaries and by the OS write queue draining into
    # the next step, so this is the only trustworthy loss figure).
    raw_tx = raw_rx = 0
    for _, w in df[df._type == "wire"].iterrows():
        raw_tx += int(_dict(w.get("txBytes")).get("raw", 0))
        raw_rx += int(_dict(w.get("rxBytes")).get("raw", 0))
    if raw_tx:
        lines.append(
            f"raw blobs: {raw_tx} B accepted by the sender's stack, "
            f"{raw_rx} B delivered = {100 * raw_rx / raw_tx:.1f}% "
            f"(the gap is bytes still queued at step end or dropped by the "
            f"stack under overrun — the OS accepts writes far faster than "
            f"the air drains them)")
    fresh = df[(df._type == "message") & (_col(df, "dir") == "recv")]
    pkt_dups = df[df._type == "packetDup"]
    msg_dups = df[(df._type == "message") & (_col(df, "dir") == "dup")]
    if len(fresh):
        lines.append(
            f"redundant arrivals for us: {len(pkt_dups)} for {len(fresh)} "
            f"delivered message(s) = {1 + len(pkt_dups) / len(fresh):.2f} per "
            "message. NOT a duplication factor: the numerator counts outer "
            "PACKETS addressed to us (a duplicate ack is one, and acks are "
            "not deliveries) and it sees nothing of the transit traffic a "
            "relay drops. Use the packets-per-delivery figure below for cost")
        lines.append(
            f"message re-delivery: {len(msg_dups)} (must be 0 — a duplicate "
            "of an already-delivered message triggers nothing)")

    # The honest cost figure: everything the fleet PUT ON THE AIR against the
    # packets that actually reached the node they were addressed to. Both
    # sides are packets, so the ratio means something — unlike a packet
    # numerator over a message denominator. Transmissions come from the wire
    # ledger, which counts per link (a broadcast over N links is N packets,
    # which is what the radio actually paid for).
    tx_sealed = collections.Counter()
    rx_all = collections.Counter()
    for _, w in df[df._type == "wire"].iterrows():
        for name, n in _dict(w.get("txPackets")).items():
            tx_sealed[name] += int(n)
        for name, n in _dict(w.get("rxPackets")).items():
            rx_all[name] += int(n)
    sealed_tx = sum(n for name, n in tx_sealed.items()
                    if name == "secure" or name.startswith("secure:"))
    # Reached its final destination = accepted by the node it was addressed
    # to, first time: a data packet delivered (recv) or an ack that got home
    # (ackRx). Anything else on the air was transit, a duplicate, or a sync
    # offer nobody wanted.
    acks_home = len(df[(df._type == "message") & (_col(df, "dir") == "ackRx")])
    arrived = len(fresh) + acks_home
    if sealed_tx and arrived:
        # Sync frames can NEVER appear in the denominator: an offer/request is
        # dispatched to the sync handlers and produces no `recv` and no ack,
        # so counting it against deliveries is not a like-for-like ratio. Keep
        # it out of the cost figure and report it as what it is — the share of
        # the air spent on reconciliation rather than on carrying anything.
        sync_tx = sum(n for name, n in tx_sealed.items()
                      if name.startswith("secure:sync"))
        payload_tx = sealed_tx - sync_tx
        parts = ", ".join(f"{k} {v}" for k, v in
                          sorted(tx_sealed.items(), key=lambda kv: -kv[1])
                          if k == "secure" or k.startswith("secure:"))
        lines.append(
            f"packets per delivery: {payload_tx} carrying packet(s) on the "
            f"air (data + ack, including every relayed and conveyed copy) "
            f"for {arrived} that reached their destination ({len(fresh)} "
            f"data + {acks_home} ack) = {payload_tx / arrived:.1f} "
            f"transmissions per delivered packet")
        if sync_tx:
            lines.append(
                f"sync overhead: {sync_tx} sync packet(s) = "
                f"{100 * sync_tx / sealed_tx:.0f}% of all sealed air, and "
                f"{sync_tx / arrived:.1f} per delivered packet. These carry "
                f"no payload and by construction never appear as a delivery — "
                f"they are the price of reconciling buffers, not of moving "
                f"messages")
        lines.append(f"  sealed tx by kind: [{parts}]")

    # EVERY packet on the air, whatever it carries. ANNOUNCE and sync compete
    # for the same radio as payload, so a congestion figure that leaves them
    # out understates what the medium is actually carrying. Three stages, each
    # a strict subset of the one before:
    #   aired    — writes the radio paid for (a broadcast over N links is N)
    #   received — the same packets arriving at SOME node, transit included
    #   arrived  — accepted by the node they were addressed to, first time
    # aired - received is what the air itself swallowed; received - arrived is
    # what the mesh carried for someone else or threw away as a duplicate.
    tx_total = sum(tx_sealed.values())
    rx_total = sum(rx_all.values())
    if tx_total:
        tx_kinds = ", ".join(f"{k} {v}" for k, v in tx_sealed.most_common())
        rx_kinds = ", ".join(f"{k} {v}" for k, v in rx_all.most_common())
        lines.append(
            f"packets on the air: {tx_total} aired -> {rx_total} received "
            f"({100 * rx_total / tx_total:.0f}%) -> {arrived} reached their "
            f"destination ({100 * arrived / tx_total:.1f}% of what was aired)")
        lines.append(f"  aired by kind:    [{tx_kinds}]")
        lines.append(f"  received by kind: [{rx_kinds}]")

        # DATA PLANE vs CONTROL PLANE. Mixing them hides which one is
        # expensive: control traffic scales with neighbours and buffer churn,
        # data traffic with what the user actually sent, and only the second
        # is what the mesh exists to move.
        data_tx = tx_sealed.get("secure", 0) + sum(
            v for k, v in tx_sealed.items() if k.startswith("secure:data"))
        ack_tx = sum(v for k, v in tx_sealed.items()
                     if k.startswith("secure:ack"))
        ann_tx = tx_sealed.get("announce", 0)
        hs_tx = tx_sealed.get("handshake", 0)
        ctrl_tx = sync_tx + ack_tx + ann_tx + hs_tx
        ann_rx = rx_all.get("announce", 0)
        lines.append(
            f"  DATA plane:    {data_tx} aired -> {len(fresh)} delivered"
            + (f" = {data_tx / len(fresh):.1f} per delivery" if len(fresh)
               else ""))
        lines.append(
            f"  CONTROL plane: {ctrl_tx} aired "
            f"({100 * ctrl_tx / tx_total:.0f}% of the air) — sync {sync_tx}, "
            f"ack {ack_tx}, announce {ann_tx}, handshake {hs_tx}")
        lines.append(
            f"    of which delivered: ack {acks_home} home, announce {ann_rx} "
            f"received. Sync arrivals are NOT separable: the receive side "
            f"classifies by the outer type byte alone, so a received sync "
            f"packet is indistinguishable from a data one and sits inside "
            f"rx `secure`. Splitting it would need the packetId (which "
            f"survives relaying unchanged) joined back to the originator's "
            f"own record of what it sealed")
    joined = packet_join(df)
    if joined:
        lines.append(joined)
    return "\n".join(lines) + "\n"


def packet_join(df: pd.DataFrame) -> str:
    """Follow individual packets by id, from the sender that minted them to
    every node that saw them.

    The packetId survives relaying unchanged --- `decrementTtl` carries it
    through, because it IS the dedup key --- so the id the originator wrote is
    the id every hop reads. That makes an offline join possible where the wire
    itself is deliberately uninformative: a relay cannot tell a data packet
    from an ack, but the originator recorded which it sealed, and the analysis
    can put the two together afterwards.

    What this can and cannot see, stated plainly:
      * data  — `message/sealed` lists the packetIds of every message sent
      * ack   — `ackTx` names the packetId of every ack sent
      * sync  — INVISIBLE. Sync frames are traced on neither side: the sender
                logs no per-frame record and the receiver logs nothing for a
                packet it neither delivers nor relays. Sync is also TTL 1, so
                it never appears in a `relay` record either. Any figure below
                therefore describes data and ack traffic only, and the sync
                share has to come from the wire ledger's tx counts.
    """
    msgs = df[df._type == "message"]
    if msgs.empty:
        return ""
    kind: dict[str, str] = {}
    origin: dict[str, str] = {}
    msg_to_packets: dict[str, list[str]] = {}
    for _, r in msgs[_col(msgs, "dir") == "sealed"].iterrows():
        ids = r.get("packetIds")
        ids = list(ids) if isinstance(ids, (list, tuple)) else []
        msg_to_packets[str(r.get("messageId"))] = [str(i) for i in ids]
        for i in ids:
            kind[str(i)] = "data"
            origin[str(i)] = str(r.get("_device"))
    for _, r in msgs[_col(msgs, "dir") == "ackTx"].iterrows():
        kind[str(r.get("packetId"))] = "ack"
        origin[str(r.get("packetId"))] = str(r.get("_device"))
    if not kind:
        return ""

    # Where a packet was SEEN. Each of these is a node reporting an arrival:
    # forwarded on (relay), stored or conveyed for someone (custody), dropped
    # as a duplicate (packetDup), or accepted as an ack (ackRx).
    #
    # Only ANOTHER node's record counts. The originator stores every packet it
    # sends in its own DTN buffer, so counting custody records without this
    # filter reports 100% "seen" for free and measures nothing.
    seen: dict[str, set[str]] = collections.defaultdict(set)
    for t in ("relay", "custody", "packetDup"):
        sub = df[df._type == t]
        if sub.empty:
            continue
        for pid, dev in zip(_col(sub, "packetId"), sub["_device"]):
            if pd.isna(pid):
                continue
            if origin.get(str(pid)) == str(dev):
                continue
            seen[str(pid)].add(t)
    for _, r in msgs[_col(msgs, "dir") == "ackRx"].iterrows():
        seen[str(r.get("packetId"))].add("arrived")
    # A delivered message names its messageId; the sender's own `sealed`
    # record is what maps that back to the packets it was cut into.
    for _, r in msgs[_col(msgs, "dir") == "recv"].iterrows():
        for pid in msg_to_packets.get(str(r.get("messageId")), []):
            if origin.get(pid) != str(r.get("_device")):
                seen[pid].add("arrived")

    lines = ["", "Packet join (by packetId, which survives relaying)"]
    lines.append("-" * 60)
    for k in ("data", "ack"):
        ids = {i for i, v in kind.items() if v == k}
        if not ids:
            continue
        obs = {i for i in ids if seen.get(i)}
        home = {i for i in ids if "arrived" in seen.get(i, ())}
        relayed = {i for i in ids if "relay" in seen.get(i, ())}
        carried = {i for i in ids if "custody" in seen.get(i, ())}
        lines.append(
            f"  {k:5}: {len(ids)} minted -> {len(obs)} seen by ANOTHER node "
            f"({100 * len(obs) / len(ids):.0f}%) -> {len(home)} reached the "
            f"node they were addressed to ({100 * len(home) / len(ids):.0f}%)"
            f"; {len(relayed)} were forwarded by a relay, {len(carried)} "
            f"entered a buffer")
        lost = ids - obs
        if lost:
            lines.append(
                f"         {len(lost)} left no trace on any OTHER node — "
                f"never relayed, never buffered elsewhere, never delivered: "
                f"as far as the fleet is concerned they never left the "
                f"sender")
    lines.append(
        "  sync: not joinable — sync frames are traced on neither side and "
        "are TTL 1, so they never appear as a relay either. Their cost is "
        "visible only as tx `secure:sync` above.")
    return "\n".join(lines)


def ladder_table(steps: pd.DataFrame) -> pd.DataFrame:
    """Establishment-latency percentiles per stage over all trials.

    One row per link stage: how many trials reached it, and how long it took
    from the step marker. `usable` is the end-to-end one — first ACK back —
    so its reach-rate is the establishment probability the control-plane
    evaluation reports, and its percentiles are the time-to-first-message.
    """
    rows = []
    trials = len(steps)
    for stage in LINK_STAGES:
        col = f"t_{stage}_s"
        if stage == "drop" or col not in steps.columns:
            continue
        v = steps[col].dropna()
        if v.empty:
            continue
        rows.append({
            "stage": stage,
            "trials": trials,
            "reached": len(v),
            "reach_rate": round(len(v) / trials, 3) if trials else None,
            "median_s": round(v.median(), 2),
            "p90_s": round(v.quantile(0.9), 2),
            "max_s": round(v.max(), 2),
        })
    return pd.DataFrame(rows)


# Segment head to discard in the power ladder. The two phones tap seconds
# apart and a BLE bring-up lands inside the head of an "up" segment, so the
# first samples of a segment do not yet describe its condition.
POWER_TRIM_HEAD_S = 60
# Canonical ladder order and what each condition is contrasted against. A
# condition's cost is only meaningful as a DELTA from a baseline that differs
# in exactly one thing; absolute draw is dominated by the screen.
POWER_LADDER = [
    ("base", None, "screen + app + sampling floor"),
    ("solo", "base", "own radio up alone: advertise + scan"),
    ("solo2", "base", "peer's radio up alone (this device idle)"),
    ("linked", "base", "connected + ANNOUNCE upkeep"),
    ("light", "linked", "marginal cost of sending ~1 msg/s"),
    ("light2", "linked", "marginal cost of RECEIVING ~1 msg/s"),
    ("heavy", "linked", "sending at capacity"),
    ("heavy2", "linked", "receiving at capacity"),
]


def power_ladder(df: pd.DataFrame, segs: list[dict],
                 roles: dict[str, str]) -> pd.DataFrame:
    """Per-device condition deltas from the power-baseline ladder.

    One row per (device, condition), pooling that condition's repeats. Reports
    the median draw in MILLIWATTS, its standard error, and the delta against
    the condition's baseline with the delta's own standard error — the only
    number worth quoting, since absolute draw is screen-dominated and differs
    per device.

    Milliwatts, not milliamps: battery voltage sags roughly 150 mV over a 2-hour
    run, so a constant power draw reads as a steadily rising current and every
    late condition is biased against every early one. Multiplying by the
    sampled voltage removes that drift, and makes two phones comparable in
    absolute terms instead of only in deltas.

    Two exclusions are applied and reported rather than assumed: samples taken
    while charging (a plugged phone reports charge current, not consumption)
    and the first [POWER_TRIM_HEAD_S] of every segment (tap skew + BLE
    bring-up). Rows never mix devices — comparing two phones' absolute draw
    measures the phones.
    """
    power = df[df._type == "power"]
    if power.empty:
        return pd.DataFrame()

    # Label by LADDER role, not by send/recv role: both phones send (in their
    # own light/heavy segments), so the generic sender/receiver labels would
    # be arbitrary here. P1 is whoever sends during `light` — the plan's own
    # definition. Falls back to the generic roles if that cannot be seen.
    msgs = df[df._type == "message"]
    ladder_role: dict[str, str] = {}
    for seg in segs:
        if str(seg["label"]).split(" r")[0].strip() != "light":
            continue
        sent = msgs[(msgs._t >= seg["t0"]) & (msgs._t < seg["t1"])]
        sent = sent[_col(sent, "dir") == "sent"]
        senders = set(sent._device.unique())
        if len(senders) != 1:
            continue
        p1 = str(next(iter(senders)))
        ladder_role = {p1: "P1"}
        for dev in df._device.unique():
            ladder_role.setdefault(str(dev), "P2")
        break

    def label(dev: str) -> str:
        return ladder_role.get(dev, roles.get(dev, short(dev)))

    # condition -> device -> samples, pooling repeats ("light r1", "light r2").
    pooled: dict[str, dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(list))
    charging_seen = False
    for seg in segs:
        name = str(seg["label"]).split(" r")[0].strip()
        start = seg["t0"] + POWER_TRIM_HEAD_S * 1000
        if start >= seg["t1"]:
            continue  # segment shorter than the trim: nothing usable
        in_seg = power[(power._t >= start) & (power._t < seg["t1"])]
        for dev, g in in_seg.groupby("_device"):
            chg = _col(g, "charging").fillna(False).astype(bool)
            if chg.any():
                charging_seen = True
            live = g[~chg].sort_values("_t")
            # Drop consecutive repeats of the SAME gauge reading. The fuel
            # gauge refreshes every ~20-30s while the recorder samples every
            # 10s, so each real reading is captured 2-3 times. Counting those
            # as independent shrinks the SEM by ~sqrt(3) and makes deltas look
            # resolved that a rep-to-rep comparison says are not.
            keep = ((live["currentNowUa"] != live["currentNowUa"].shift()) |
                    (live["voltageMv"] != live["voltageMv"].shift()))
            live = live[keep]
            cur = pd.to_numeric(_col(live, "currentNowUa"), errors="coerce")
            volt = pd.to_numeric(_col(live, "voltageMv"), errors="coerce")
            # POWER, not current. Battery voltage sags ~150mV over a 2h run, so
            # a constant draw reads as a rising current and every late
            # condition is biased against every early one. mA x V = mW cancels
            # it, and also makes two phones with different battery chemistry
            # comparable in absolute terms rather than only in deltas.
            # MainActivity returns voltageMv = -1 when the sticky battery
            # intent is null; multiplying the sentinel in silently pools
            # small negative mW values. Volt must be plausible or the sample
            # is unusable.
            valid = volt > 0
            mW = (cur[valid].abs() / 1000.0) * (volt[valid] / 1000.0)
            pooled[name][str(dev)].extend(mW.dropna().tolist())

    def sem(vals: list[float]) -> float | None:
        if len(vals) < 2:
            return None
        return float(np.std(vals, ddof=1) / math.sqrt(len(vals)))

    rows = []
    for cond, baseline, meaning in POWER_LADDER:
        for dev in sorted(pooled.get(cond, {})):
            vals = pooled[cond][dev]
            if not vals:
                continue
            base_vals = pooled.get(baseline, {}).get(dev, []) if baseline else []
            delta = (float(np.median(vals) - np.median(base_vals))
                     if base_vals else None)
            s_cond, s_base = sem(vals), sem(base_vals) if base_vals else None
            delta_sem = (math.sqrt(s_cond ** 2 + s_base ** 2)
                         if s_cond is not None and s_base is not None else None)
            rows.append({
                "device": label(dev),
                "condition": cond,
                "interpretation": meaning,
                "samples": len(vals),
                "median_mW": round(float(np.median(vals)), 1),
                "sem_mW": round(s_cond, 1) if s_cond is not None else None,
                "vs": baseline,
                "delta_mW": round(delta, 1) if delta is not None else None,
                "delta_sem_mW": (round(delta_sem, 1)
                                 if delta_sem is not None else None),
                # A delta smaller than ~2 SEM is not distinguishable from zero;
                # reporting it as a bound is the honest form.
                "resolved": (bool(abs(delta) > 2 * delta_sem)
                             if delta is not None and delta_sem else None),
            })
    out = pd.DataFrame(rows)
    if not out.empty and charging_seen:
        out.attrs["charging_excluded"] = True
    return out


# --------------------------------------------------------------------------- #
# Session cap sizing
# --------------------------------------------------------------------------- #
# Cost of one failed AEAD open and of one Noise XX handshake, in microseconds.
# HARDWARE constants: run `CryptoBench` (testbed screen -> "Crypto bench") on
# the device in question and paste its numbers here.
#
# Measured, from CryptoBench:
#   Nexus 5X (2015, Cortex-A53/A57)   350 us   84_100 us    <- the default
#   arm64 laptop (2024)                35 us    4_250 us
#
# The default is the SLOW device on purpose. The fleet's weakest phone is what
# decides whether a design is affordable, and defaulting to a laptop
# understated every derived figure by 10x. On the 5X the per-attempt cost is
# flat from S=32 upward (360.8 us at 32, 350.1 us at 128); the S=1 reading of
# 583.7 us is residual JIT warm-up, not a table-size effect.
T_FAIL_US = 350.0
T_HANDSHAKE_US = 84_100.0

# Extra cost a re-handshake pays beyond CPU: three BLE round trips before the
# session exists. Taken from the establishment ladder, not from the bench.
T_HANDSHAKE_BLE_US = 200_000.0


# A peer sighting more than this long after the previous one from the same
# peer starts a NEW encounter. Sightings are ANNOUNCE arrivals, which repeat
# every ~10s while a peer is nearby, so raw sightings would count one coffee
# break as hundreds of encounters. 60s clears the 20s stale-sweep eviction
# with margin.
ENCOUNTER_GAP_S = 60.0


def _encounter_sequence(df: pd.DataFrame,
                        gap_s: float = ENCOUNTER_GAP_S) -> dict[str, list[str]]:
    """Per device, the ordered list of peers it encountered.

    Built from `link/discovered` sightings rather than from `link/session`,
    and the distinction is load-bearing: a `session` record fires only when a
    handshake actually ran, i.e. only on a cache MISS. Deriving the sequence
    from those would make every entry a miss and the hit-rate curve below
    identically zero. Sightings happen whether or not a session already
    existed, which is exactly what the counterfactual needs.
    """
    ev = _col(df, "event")
    peer = _col(df, "peer")
    rows = df[(df._type == "link") & (ev == "discovered") & peer.notna()]
    if rows.empty:
        return {}
    seq: dict[str, list[str]] = {}
    for dev, g in rows.sort_values("t").groupby("_device"):
        last_t: dict[str, float] = {}
        order: list[str] = []
        for t, pk in zip(g["t"], g["peer"].astype(str)):
            prev = last_t.get(pk)
            if prev is None or (t - prev) / 1000.0 > gap_s:
                order.append(pk)
            last_t[pk] = t
        if order:
            seq[dev] = order
    return seq


def _hit_rate_curve(seq: list[str], caps: list[int]) -> dict[int, float]:
    """LRU hit rate at every cap, from one pass over the encounter sequence.

    Classic stack distance: when a peer recurs, count how many *distinct*
    other peers were seen since its last occurrence. LRU with cap N keeps the
    entry exactly when that distance is < N, so one histogram answers every
    cap at once — no need to simulate each candidate separately.
    """
    last_seen: dict[str, int] = {}
    distances: list[int] = []
    for i, peer in enumerate(seq):
        prev = last_seen.get(peer)
        if prev is not None:
            distances.append(len(set(seq[prev + 1:i])))
        last_seen[peer] = i
    if not distances:
        return {n: 0.0 for n in caps}
    return {n: sum(1 for d in distances if d < n) / len(distances) for n in caps}


def session_cap(df: pd.DataFrame, caps: list[int] | None = None,
                t_fail_us: float = T_FAIL_US,
                t_handshake_us: float = T_HANDSHAKE_US + T_HANDSHAKE_BLE_US,
                ) -> pd.DataFrame:
    """Cost of every candidate `maxSessions`, from this trace's own traffic.

    Holding a session is a standing cost and avoiding a handshake is a
    one-off saving, so the two only compare per unit time:

        cost(N) = R_miss x min(N, peers) x t_fail          (walk the table)
                + encounters/s x (1 - hit(N)) x t_handshake  (re-handshake)

    R_miss is the rate of inbound sealed packets that do NOT open under any
    session. Today that is near zero, because the envelope's recipient field
    rejects other people's traffic before it ever reaches the trial-decrypt
    loop -- so the first term vanishes and the cap wants to be large. Drop
    that field and every transit packet becomes a miss, the first term
    dominates, and the cap wants to be small. That coupling is the point of
    this table: the right cap is not a constant, it follows from whether the
    recipient stays in the envelope.
    """
    caps = caps or [8, 16, 32, 64, 128, 256, 512, 1024]
    seq_by_dev = _encounter_sequence(df)
    if not seq_by_dev:
        return pd.DataFrame()

    span_s = max((df["t"].max() - df["t"].min()) / 1000.0, 1.0)

    ev = _col(df, "event")
    misses = int(((df._type == "session") & (ev == "decryptMiss")).sum())
    hits = int(((df._type == "session") & (ev == "decryptHit")).sum())
    r_miss = misses / span_s

    rows = []
    for dev, seq in seq_by_dev.items():
        hit = _hit_rate_curve(seq, caps)
        distinct = len(set(seq))
        enc_rate = len(seq) / span_s
        for n in caps:
            walk_us = r_miss * min(n, distinct) * t_fail_us
            hs_us = enc_rate * (1.0 - hit[n]) * t_handshake_us
            rows.append({
                "device": short(dev),
                "cap": n,
                "encounters": len(seq),
                "distinct_peers": distinct,
                "hit_rate": round(hit[n], 4),
                "walk_us_per_s": round(walk_us, 1),
                "handshake_us_per_s": round(hs_us, 1),
                "total_us_per_s": round(walk_us + hs_us, 1),
                "cpu_pct": round((walk_us + hs_us) / 10_000.0, 3),
            })
    out = pd.DataFrame(rows)
    out.attrs["r_miss_per_s"] = round(r_miss, 3)
    out.attrs["decrypt_hits"] = hits
    out.attrs["decrypt_misses"] = misses
    return out


def session_cap_summary(cap: pd.DataFrame) -> str:
    if cap.empty:
        return ""
    lines = ["", "Session cap (LRU) sizing", "-" * 60,
             f"  inbound sealed packets that opened nothing: "
             f"{cap.attrs.get('decrypt_misses', 0)} "
             f"({cap.attrs.get('r_miss_per_s', 0)}/s)",
             f"  inbound sealed packets that opened: "
             f"{cap.attrs.get('decrypt_hits', 0)}"]
    for dev, g in cap.groupby("device"):
        best = g.loc[g["total_us_per_s"].idxmin()]
        lines.append(f"  {dev}: {int(best['encounters'])} pairings with "
                     f"{int(best['distinct_peers'])} distinct peers -> "
                     f"cheapest cap {int(best['cap'])} "
                     f"(hit {best['hit_rate']:.2f}, "
                     f"{best['cpu_pct']:.3f}% of one core)")
    if cap.attrs.get("decrypt_misses", 0) == 0:
        lines.append("  NOTE: no failed trial-decrypts in this trace, so the "
                     "table-walk term is zero and the cheapest cap is simply "
                     "the largest. That is the correct answer WHILE the "
                     "envelope still carries a recipient; re-run against a "
                     "recipient-less arm to get the trade-off.")
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- #
# Loss & occupancy (drop / buf records)
# --------------------------------------------------------------------------- #
def drop_table(df: pd.DataFrame) -> pd.DataFrame:
    """Loss counts by site and reason, per device. One uniform record type
    covers every drop point (TTL death, rate-limit refusal, decrypt failure,
    malformed input, reassembly abandonment, transport send failures,
    handshake deaths...), so packet loss is countable without per-site
    parsing."""
    drops = df[df._type == "drop"]
    if drops.empty:
        return pd.DataFrame()
    out = (drops.groupby(["_device", "where", "reason"]).size()
           .reset_index(name="count"))
    out["_device"] = out["_device"].map(short)
    return out.sort_values("count", ascending=False)


def buf_table(df: pd.DataFrame) -> pd.DataFrame:
    """Peak and final occupancy per buffer per device, from the periodic
    `buf` snapshots — the memory-utilization summary."""
    bufs = df[df._type == "buf"]
    if bufs.empty:
        return pd.DataFrame()
    fields = [c for c in ("dtnPackets", "dtnRecipients", "dtnBytes", "preSeal",
                          "preSealBytes", "ackIndex", "sessions", "reassembly",
                          "reassemblyBytes", "sealedContentIds",
                          "outgoingTracked", "traceBufferedBytes")
              if c in bufs.columns]
    rows = []
    for dev, g in bufs.sort_values("t").groupby("_device"):
        for f in fields:
            series = pd.to_numeric(g[f], errors="coerce").dropna()
            if series.empty:
                continue
            rows.append({
                "device": short(dev),
                "buffer": f,
                "peak": int(series.max()),
                "final": int(series.iloc[-1]),
                "samples": len(series),
            })
    return pd.DataFrame(rows)


def bench_constants(df: pd.DataFrame) -> tuple[float, float] | None:
    """CryptoBench constants from the trace itself, when a bench record was
    written during the run — measured on the exact device, superseding the
    module-level defaults."""
    bench = df[df._type == "bench"]
    if bench.empty:
        return None
    row = bench.iloc[-1]
    rows = row.get("decrypt")
    ths = row.get("tHandshakeUs")
    if not isinstance(rows, list) or not rows:
        return None
    tfail = rows[-1].get("tFailUs")  # largest S = converged, least warm-up
    if tfail is None or ths is None:
        return None
    return float(tfail), float(ths)


def latency_table(df: pd.DataFrame) -> pd.DataFrame:
    msgs = df[df._type == "message"]
    sent = msgs[_col(msgs, "dir") == "sent"]
    delivered = msgs[_col(msgs, "dir") == "delivered"]
    # One delivered per messageId: traces recorded before the duplicate-ACK
    # guard can carry re-fires with later timestamps, which silently skew
    # every latency join. First wins.
    if not delivered.empty and "messageId" in delivered.columns:
        delivered = (delivered.sort_values("_t")
                     .drop_duplicates(subset="messageId", keep="first"))
    if sent.empty:
        return pd.DataFrame()
    sent = sent.sort_values("_t").drop_duplicates(subset="messageId",
                                                  keep="first")
    s = sent[["messageId", "_device", "_t", "payloadSize"]].rename(
        columns={"_t": "sentAt", "_device": "sender"})
    d_cols = ["messageId", "_t"] + (
        ["appLatencyMs"] if "appLatencyMs" in delivered.columns else [])
    d = delivered[d_cols].rename(columns={"_t": "deliveredAt"})
    joined = s.merge(d.drop_duplicates("messageId"), on="messageId", how="left")
    # ONE-WAY reception, from the RECEIVER's recv records. Distinct from the
    # ACK join above: at the range edge B may receive a message whose ACK
    # never survives the trip back, so received/sent > acked/sent there —
    # conflating them would understate one-way reachability by the reverse
    # path's loss.
    recv = msgs[_col(msgs, "dir") == "recv"]
    r = recv[["messageId", "_t"]].rename(columns={"_t": "receivedAt"})
    joined = joined.merge(
        r.drop_duplicates("messageId"), on="messageId", how="left")
    # TWO different latencies, deliberately kept apart:
    #   latencyMs    — WIRE RTT: the sealed packet hitting the transport until
    #                  its ACK came back. Both stamps are trace records on the
    #                  sender, one clock, no queueing in between.
    #   appLatencyMs — the app's own view, from when the message was CREATED:
    #                  enqueue + seal + waiting for the session and the settled
    #                  link are all inside it.
    # The gap between them is the send path's own cost and is worth reporting:
    # it fell from ~92ms to ~15ms per message when the payload stopped
    # fragmenting and the flood stopped writing both GATT legs.
    joined["latencyMs"] = joined.deliveredAt - joined.sentAt
    if "appLatencyMs" not in joined.columns:
        joined["appLatencyMs"] = pd.NA
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
            stages = _col(link, "event").value_counts().to_dict()
            lines.append(f"  link stages: {stages}")
        if not latency.empty:
            mine = latency[latency.sender == device]
            if len(mine):
                ok = mine.latencyMs.notna()
                recv_ok = mine.receivedAt.notna()
                lines.append(
                    f"  messages sent: {len(mine)}, received: "
                    f"{int(recv_ok.sum())} ({100 * recv_ok.mean():.0f}%), "
                    f"ACK-confirmed: {int(ok.sum())} ({100 * ok.mean():.0f}%)")
                if ok.any():
                    lat = mine.latencyMs.dropna()
                    lines.append(
                        f"  wire RTT ms (send->ACK): median {lat.median():.0f}, "
                        f"p90 {lat.quantile(0.9):.0f}, max {lat.max():.0f}")
                    app = pd.to_numeric(mine.appLatencyMs,
                                        errors="coerce").dropna()
                    if len(app):
                        lines.append(
                            f"  app latency ms (create->ACK): median "
                            f"{app.median():.0f}, p90 {app.quantile(0.9):.0f} "
                            f"— the extra over wire RTT is enqueue + seal + "
                            f"waiting for a settled link")
        flows = sub[(sub._type == "flow") & (_col(sub, "event") == "stop")]
        for _, f in flows.iterrows():
            start = sub[(sub._type == "flow") & (_col(sub, "event") == "start")
                        & (_col(sub, "flow") == f.get("flow"))]
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
    power = df[df._type == "power"]
    for dev, g in power.groupby("_device"):
        g = g.sort_values("_t")
        lvl = pd.to_numeric(_col(g, "levelPct"), errors="coerce").dropna()
        chg_mask = _col(g, "charging").fillna(False).astype(bool)
        cur = pd.to_numeric(
            _col(g[~chg_mask], "currentNowUa"), errors="coerce").dropna()
        if len(lvl):
            line = (f"battery {label_for(str(dev), roles)}: "
                    f"{lvl.iloc[0]:.0f}% -> {lvl.iloc[-1]:.0f}%")
            if len(cur):
                line += (f", median draw {cur.abs().median() / 1000:.0f} mA "
                         f"({len(cur)} samples)")
            if chg_mask.any():
                line += (f" [WARNING: {int(chg_mask.sum())}/{len(g)} samples "
                         f"while charging — excluded from draw]")
            lines.append(line)

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


# Categorical slots 1-3 of the validated reference palette. Adjacent pairs
# (blue/orange, orange/aqua) clear the CVD and normal-vision floors; identity
# is additionally carried by direct labels, never colour alone.
_C_SESSION, _C_USABLE, _C_DELIVERY = '#2a78d6', '#eb6834', '#1baf7a'
_INK, _INK_2, _INK_MUTED, _SURFACE = '#0b0b0b', '#52514e', '#8a8880', '#fcfcfb'


def power_series(df: pd.DataFrame) -> pd.DataFrame:
    """Per-sample power, for plotting a real discharge curve.

    Every other power output aggregates (a median per condition, a delta per
    step). A discharge run's whole point is the SHAPE over time — where the
    knee is, whether draw holds as voltage sags — and that needs the samples
    themselves. Kilobytes even for a five-hour run, since the gauge only
    updates every ~30s.

    Charging samples are excluded and consecutive repeats of one gauge
    reading are collapsed, matching `power_ladder` so the two never disagree.
    """
    pw = df[df._type == "power"]
    if pw.empty:
        return pd.DataFrame()
    out = []
    for dev, g in pw.sort_values("_t").groupby("_device"):
        chg = _col(g, "charging").fillna(False).astype(bool)
        g = g[~chg]
        if g.empty:
            continue
        keep = ((g["currentNowUa"] != g["currentNowUa"].shift()) |
                (g["voltageMv"] != g["voltageMv"].shift()))
        g = g[keep]
        t0 = g["_t"].min()
        cur = pd.to_numeric(_col(g, "currentNowUa"), errors="coerce").abs()
        volt = pd.to_numeric(_col(g, "voltageMv"), errors="coerce")
        out.append(pd.DataFrame({
            "device": short(str(dev)),
            "t": g["_t"],
            "elapsed_s": ((g["_t"] - t0) / 1000).round(1),
            "levelPct": _col(g, "levelPct"),
            "mA": (cur / 1000).round(1),
            "mV": volt.round(0),
            # Power, not current: voltage sags across a discharge, so a
            # constant draw reads as a rising current.
            "mW": ((cur / 1000) * (volt / 1000)).round(1),
            "tempC": pd.to_numeric(_col(g, "tempDeciC"),
                                   errors="coerce") / 10.0,
            "chargeCounterUah": _col(g, "chargeCounterUah"),
        }))
    return pd.concat(out, ignore_index=True) if out else pd.DataFrame()


def mesh_scale(df: pd.DataFrame, segs: list[dict]) -> pd.DataFrame:
    """Cost and reach per device count, aggregated over that count's repeats.

    The question managed flooding has to answer is whether adding nodes buys
    reach without the redundant traffic running away. Both halves are here:
    `delivery_rate` is the reach, `dup_per_delivered` is the cost, and the
    result is one holding while the other does not.

    Every N is measured several times (`n=5 t1`..`t10`) and the reps are
    aggregated here, reporting the SPREAD across them rather than only a
    central value — the power ladder showed between-rep spread, not
    within-rep scatter, is where the real uncertainty sits, and a curve
    quoted without it invites reading noise as structure.

    Segments match the plan's own labels, not `degreeAtEvent`: the label is
    what the plan scripted, degree is a snapshot that moves as links form and
    drop mid-step. Degree is reported alongside so the two can be compared —
    a large gap means devices were not joining when their step said they
    would.
    """
    per_rep: dict[int, list[dict]] = {}
    for seg in segs:
        m = re.match(r"n=(\d+)\b", str(seg["label"]).strip())
        if not m:
            continue
        n = int(m.group(1))
        win = df[(df._t >= seg["t0"]) & (df._t < seg["t1"])]
        if win.empty:
            continue
        ev, dirs = _col(win, "event"), _col(win, "dir")
        sent = int(((win._type == "message") & (dirs == "sent")).sum())
        recv = int(((win._type == "message") & (dirs == "recv")).sum())
        dup = int((win._type == "packetDup").sum())
        relays = win[(win._type == "relay") & (ev != "dup") & (ev != "aired")]
        hops = pd.to_numeric(_col(win[win._type == "message"], "relayHops"),
                             errors="coerce").dropna()
        deg = pd.to_numeric(_col(win, "degreeAtEvent"), errors="coerce").dropna()
        tx = 0
        for _, r in win[win._type == "wire"].iterrows():
            for k in ("txBytes", "rxBytes"):
                v = r.get(k)
                if isinstance(v, dict):
                    tx += sum(v.values())
        per_rep.setdefault(n, []).append({
            "sent": sent, "recv": recv, "dup": dup,
            "delivery_rate": recv / sent if sent else None,
            "dup_per_delivered": dup / recv if recv else None,
            "relays": len(relays),
            "relaying_devices": int(relays._device.nunique())
                                if not relays.empty else 0,
            "wire_B_per_delivered": tx / recv if recv else None,
            "hops_median": float(hops.median()) if not hops.empty else None,
            "hops_max": float(hops.max()) if not hops.empty else None,
            "degree_median": float(deg.median()) if not deg.empty else None,
            "devices": int(win._device.nunique()),
        })

    def agg(vals: list, fn):
        clean = [v for v in vals if v is not None]
        return round(fn(clean), 4) if clean else None

    rows = []
    for n in sorted(per_rep):
        reps = per_rep[n]
        dr = [r["delivery_rate"] for r in reps if r["delivery_rate"] is not None]
        dd = [r["dup_per_delivered"] for r in reps
              if r["dup_per_delivered"] is not None]
        rows.append({
            "n": n,
            "reps": len(reps),
            "sent": sum(r["sent"] for r in reps),
            "recv": sum(r["recv"] for r in reps),
            "dup": sum(r["dup"] for r in reps),
            # Reach: does adding nodes still deliver.
            "delivery_rate": agg(dr, lambda v: sum(v) / len(v)),
            "delivery_min": agg(dr, min),
            "delivery_max": agg(dr, max),
            # THE cost number, with its spread across reps beside it.
            "dup_per_delivered": agg(dd, lambda v: sum(v) / len(v)),
            "dup_spread": (round(max(dd) - min(dd), 3) if len(dd) > 1 else None),
            "relays": sum(r["relays"] for r in reps),
            "relays_per_device": agg(
                [r["relays"] / max(r["devices"], 1) for r in reps],
                lambda v: sum(v) / len(v)),
            "relaying_devices": agg([r["relaying_devices"] for r in reps], max),
            "wire_B_per_delivered": agg(
                [r["wire_B_per_delivered"] for r in reps],
                lambda v: sum(v) / len(v)),
            "hops_median": agg([r["hops_median"] for r in reps],
                               lambda v: sum(v) / len(v)),
            "hops_max": agg([r["hops_max"] for r in reps], max),
            # Cross-check on the label: a median degree well below n-1 means
            # the mesh had not converged when the step was measured.
            "degree_median": agg([r["degree_median"] for r in reps],
                                 lambda v: sum(v) / len(v)),
            "devices_seen": agg([r["devices"] for r in reps], max),
        })
    return pd.DataFrame(rows)


def plot_range(steps: pd.DataFrame, out: Path):
    """Establishment and delivery against distance — the range result.

    Two stacked panels sharing the distance axis rather than one chart with
    two y-scales: success fractions and dBm are different units, and a dual
    axis would invite reading a crossing point that means nothing.

    The panels answer different questions and the gap between them IS the
    finding: a pair can keep forming a session long after it can carry
    traffic, so "maximum range" depends on whether establishment or
    sustained delivery is the criterion.
    """
    if steps.empty or "d" not in steps.columns:
        return
    df = steps[steps["d"].notna()].copy()
    if df.empty:
        return

    rows = []
    for d, g in df.groupby("d"):
        n = len(g)
        def frac(col):
            if col not in g.columns:
                return float("nan")
            return float((pd.to_numeric(g[col], errors="coerce").fillna(0) > 0).sum()) / n
        dr = pd.to_numeric(_col(g, "delivery_rate"), errors="coerce").dropna()
        rs = pd.to_numeric(_col(g, "rssi_adv_mean"), errors="coerce").dropna()
        rows.append({
            "d": float(d), "n": n,
            "session": frac("session"), "usable": frac("usable"),
            "delivery": float(dr.mean()) if not dr.empty else float("nan"),
            "rssi": float(rs.mean()) if not rs.empty else float("nan"),
            "rssi_sd": float(rs.std(ddof=1)) if len(rs) > 1 else 0.0,
        })
    r = pd.DataFrame(rows).sort_values("d")
    if len(r) < 2:
        return

    fig, (ax, ax2) = plt.subplots(
        2, 1, figsize=(11.5, 8.2), sharex=True,
        gridspec_kw={"height_ratios": [2.15, 1]})
    fig.patch.set_facecolor(_SURFACE)
    for a in (ax, ax2):
        a.set_facecolor(_SURFACE)
        a.grid(color="#e8e7e2", lw=0.8, zorder=0)
        for side in ("top", "right"):
            a.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            a.spines[side].set_color("#d9d8d2")
        a.tick_params(colors=_INK_2, labelsize=10)

    series = [
        ("session", _C_SESSION, "Noise session formed"),
        ("usable", _C_USABLE, "Link usable (first ACK)"),
        ("delivery", _C_DELIVERY, "Message delivery rate"),
    ]
    for col, color, label in series:
        ax.plot(r["d"], r[col], color=color, lw=2.0, marker="o", ms=8,
                markeredgecolor=_SURFACE, markeredgewidth=2,
                label=label, zorder=3, solid_capstyle="round")

    # The reliable range: the largest distance at which EVERY criterion is
    # still perfect. Stated as a rule so the figure cannot drift from it.
    perfect = r[(r["session"] >= 1.0) & (r["usable"] >= 1.0) &
                (r["delivery"] >= 1.0)]
    if not perfect.empty:
        d_rel = float(perfect["d"].max())
        ax.axvline(d_rel, color=_INK_MUTED, lw=1.2, ls=(0, (5, 4)), zorder=1)
        ax.annotate(f"reliable to {d_rel:.0f} m\n(all criteria 100%)",
                    xy=(d_rel, 0.5), xytext=(d_rel + 2.5, 0.52),
                    fontsize=10.5, color=_INK, va="center", linespacing=1.4)

    ax.set_ylim(-0.04, 1.08)
    ax.set_yticks([0, 0.25, 0.5, 0.75, 1.0])
    ax.set_yticklabels(["0%", "25%", "50%", "75%", "100%"])
    ax.set_ylabel("fraction of trials succeeding", fontsize=11, color=_INK_2,
                  labelpad=9)
    leg = ax.legend(loc="lower left", frameon=True, fontsize=10.5,
                    facecolor=_SURFACE, edgecolor="#e8e7e2", borderpad=0.9)
    for t in leg.get_texts():
        t.set_color(_INK_2)

    ax2.errorbar(r["d"], r["rssi"], yerr=r["rssi_sd"], color=_INK_2, lw=1.8,
                 marker="o", ms=6, markeredgecolor=_SURFACE,
                 markeredgewidth=1.5, capsize=3, ecolor="#c9c8c2", zorder=3)
    ax2.set_ylabel("advertisement RSSI (dBm)", fontsize=11, color=_INK_2,
                   labelpad=9)
    ax2.set_xlabel("separation (m)", fontsize=11, color=_INK_2, labelpad=9)
    ax2.set_xticks(r["d"].tolist())

    n_min, n_max = int(r["n"].min()), int(r["n"].max())
    trials = f"{n_min}" if n_min == n_max else f"{n_min}-{n_max}"
    fig.text(0.055, 0.965, "BLE link establishment and delivery against distance",
             fontsize=15, color=_INK, fontweight="bold", va="top")
    fig.text(0.055, 0.925,
             f"{trials} trials per distance, each from a cold start "
             "(links dropped, sessions reset, DTN buffer cleared).",
             fontsize=10.5, color=_INK_2, va="top")
    fig.text(0.055, 0.045,
             "Establishment outlasts throughput: the pair keeps forming a session well past "
             "the range where it can carry traffic.",
             fontsize=9.5, color=_INK_MUTED, va="top")

    fig.subplots_adjust(left=0.085, right=0.975, top=0.875, bottom=0.115,
                        hspace=0.13)
    fig.savefig(out, dpi=160, facecolor=_SURFACE)
    plt.close(fig)


# --------------------------------------------------------------------------- #
# Field line sweep — the `fieldday_*` tables and figures
# --------------------------------------------------------------------------- #
# What the OS puts on the air for ADVERTISING is a MODEL, not a measurement:
# the controller broadcasts autonomously below the app, so no wire ledger ever
# sees those bytes (the same reason `steps_table` only reports receiver-side
# advPerMin / advCoverage). The model is one advertising event per interval per
# advertising device, repeated on all three primary channels, each carrying a
# full-size advertising PDU. The constants are stated here rather than buried
# in an expression so the figure can be recomputed when the advertising
# parameters change.
ADV_PDU_B = 37            # AdvA (6) + AdvData (31), the maximum legacy PDU
ADV_CHANNELS = 3          # 37/38/39, one copy of the PDU on each
ADV_INTERVAL_S = 0.130    # effective advertising interval per device


def _sem(vals: pd.Series) -> float:
    """Standard error of the mean. NaN below two samples — one sample has no
    spread to report, and reporting 0 there would read as a resolved point."""
    v = pd.to_numeric(vals, errors="coerce").dropna()
    if len(v) < 2:
        return float("nan")
    return float(v.std(ddof=1) / math.sqrt(len(v)))


def _line_steps(steps: pd.DataFrame) -> pd.DataFrame:
    """The distance-carrying steps of a line sweep, or an empty frame. Two
    distances are the minimum that makes any of these figures a curve."""
    if steps.empty or "d" not in steps.columns:
        return pd.DataFrame()
    df = steps[pd.to_numeric(steps["d"], errors="coerce").notna()].copy()
    if df.empty or df["d"].nunique() < 2:
        return pd.DataFrame()
    return df


# Establishment stages the time table reports, and how the figure names them.
# `connected` is deliberately absent: a raw GATT link with no session carries
# nothing, so the three stages that matter are seeing the peer, having a
# session, and having a message acknowledged.
_LINE_STAGES = [
    ("t_discovered_s", "Discovered"),
    ("t_session_s", "Noise session up"),
    ("t_usable_s", "Usable (first ACK back)"),
]


def line_experiment_tables(steps: pd.DataFrame,
                           df: pd.DataFrame | None = None
                           ) -> dict[str, pd.DataFrame]:
    """The three `fieldday_*` tables of a line sweep, keyed by file stem.

    A key is present only when the run carries what that table needs, so a
    trace without wire or power records simply yields fewer tables rather
    than failing:

    * `fieldday_establish_time` — per distance, the cold establishment ladder:
      how many trials reached each stage and the mean / median / standard
      error of the seconds it took. Derived from `steps` alone.
    * `fieldday_establish_bytes` — per distance, the control-plane bytes one
      trial costs: ANNOUNCE and Noise handshake read off the wire ledger
      (both devices), next to the modelled OS advertising cost. Needs `wire`
      records.
    * `fieldday_power` — per device, the whole run's discharge: hours, battery
      level travelled, charge drawn, mean draw, the gauge's own capacity
      estimate and the runtime that implies. Needs `power` records.
    """
    line = _line_steps(steps)
    if line.empty:
        return {}
    out: dict[str, pd.DataFrame] = {}

    rows = []
    for d, g in line.groupby("d"):
        row: dict[str, float] = {"d": float(d), "trials": len(g)}
        for col, _ in _LINE_STAGES:
            v = (pd.to_numeric(g[col], errors="coerce").dropna()
                 if col in g.columns else pd.Series(dtype=float))
            row[f"n_{col}"] = len(v)
            row[f"mean_{col}"] = float(v.mean()) if len(v) else float("nan")
            row[f"median_{col}"] = float(v.median()) if len(v) else float("nan")
            row[f"sem_{col}"] = _sem(v)
        rows.append(row)
    out["fieldday_establish_time"] = pd.DataFrame(rows).sort_values("d")

    if df is not None and not df.empty:
        wire = df[df._type == "wire"] if "_type" in df.columns else pd.DataFrame()
        if not wire.empty:
            out["fieldday_establish_bytes"] = _establish_bytes(line, wire, df)
        power = df[df._type == "power"] if "_type" in df.columns else pd.DataFrame()
        if not power.empty:
            pw = _line_power(df)
            if not pw.empty:
                out["fieldday_power"] = pw
    return out


def _establish_bytes(line: pd.DataFrame, wire: pd.DataFrame,
                     df: pd.DataFrame) -> pd.DataFrame:
    """Control-plane bytes per trial, per distance.

    ANNOUNCE and handshake bytes are summed over BOTH devices inside each
    step's marker span and divided by the distance's trial count — the cost of
    one trial to the pair, which is what the establishment argument is about.

    `dwell_s` is the plan's declared dwell, recovered as the SHORTEST step span
    in the run: every other span is inflated by the inter-step link bounce and
    the settle window that follow the dwell, so the minimum is the only span
    that is close to what the plan asked for.
    """
    spans = (pd.to_numeric(line["t1"], errors="coerce")
             - pd.to_numeric(line["t0"], errors="coerce")) / 1000.0
    dwell_s = round(float(spans.min()), 1) if spans.notna().any() else float("nan")
    # Devices that ever advertised, which for a two-phone line sweep is both.
    n_adv = int(df["_device"].nunique()) if "_device" in df.columns else 0
    os_adv = dwell_s * n_adv * ADV_CHANNELS * ADV_PDU_B / ADV_INTERVAL_S

    rows = []
    for d, g in line.groupby("d"):
        totals = {"announce": 0.0, "handshake": 0.0}
        for _, s in g.iterrows():
            in_step = wire[(wire._t >= s["t0"]) & (wire._t < s["t1"])]
            for _, w in in_step.iterrows():
                tx = _dict(w.get("txBytes"))
                for key in totals:
                    totals[key] += float(tx.get(key, 0))
        n = len(g)
        rows.append({
            "d": float(d),
            "os_adv": os_adv,
            "announce": totals["announce"] / n,
            "handshake": totals["handshake"] / n,
            "dwell_s": dwell_s,
            "usable_n": int((pd.to_numeric(g.get("usable"), errors="coerce")
                             .fillna(0) > 0).sum()),
            "trials": n,
        })
    return pd.DataFrame(rows).sort_values("d")


def _line_power(df: pd.DataFrame) -> pd.DataFrame:
    """Whole-run discharge, one row per device.

    Built on `power_series`, so the charging exclusion and the collapse of
    repeated gauge readings match every other power output. `capacity_mAh` is
    the FUEL GAUGE's own view — charge counter divided by reported level,
    averaged over the run — not charge drawn divided by level travelled: the
    level percentage is an integer, so the endpoints of a 30-point discharge
    carry a whole point of quantisation each. `runtime_h` is that capacity at
    the run's mean draw: how long this workload would flatten a full battery.
    """
    series = power_series(df)
    if series.empty:
        return pd.DataFrame()
    # Line-sweep roles: the phone that sends is the one that walks the line.
    roles = device_roles(df)
    named = {short(str(dev)): ("mover (sends)" if role.startswith("sender")
                               else "relay (forwards)" if role.startswith("relay")
                               else "static (receives)")
             for dev, role in roles.items()}
    rows = []
    for dev, g in series.groupby("device"):
        g = g.sort_values("t")
        cc = pd.to_numeric(g["chargeCounterUah"], errors="coerce").dropna()
        lvl = pd.to_numeric(g["levelPct"], errors="coerce")
        mA = pd.to_numeric(g["mA"], errors="coerce").dropna()
        if cc.empty or mA.empty or lvl.dropna().empty:
            continue
        hours = float(g["t"].max() - g["t"].min()) / 3_600_000.0
        mah_used = float(cc.iloc[0] - cc.iloc[-1]) / 1000.0
        mean_mA = float(mA.mean())
        gauge = pd.to_numeric(g["chargeCounterUah"], errors="coerce")[lvl > 0]
        capacity = float((gauge / (10.0 * lvl[lvl > 0])).mean())
        rows.append({
            "dev": dev,
            "role": named.get(dev, dev),
            "hours": hours,
            "level_from": int(lvl.dropna().iloc[0]),
            "level_to": int(lvl.dropna().iloc[-1]),
            "mAh_used": mah_used,
            "mean_mA": mean_mA,
            "capacity_mAh": capacity,
            "runtime_h": capacity / mean_mA if mean_mA else float("nan"),
        })
    return pd.DataFrame(rows)


def _field_axes(fig, axes) -> None:
    """The house style shared by the fieldday figures: paper-white ground, no
    top/right spines, a light grid behind everything."""
    fig.patch.set_facecolor(_SURFACE)
    for a in axes:
        a.set_facecolor(_SURFACE)
        a.grid(color="#e8e7e2", lw=0.8, zorder=0)
        for side in ("top", "right"):
            a.spines[side].set_visible(False)
        for side in ("left", "bottom"):
            a.spines[side].set_color("#d9d8d2")
        a.tick_params(colors=_INK_2, labelsize=10)


def _usable_header(ax, d: list[float], usable: list[int],
                   trials: list[int]) -> None:
    """`10/10`, `0/10` … above each distance: how many trials at that distance
    ever became usable. Red at zero, because a point plotted from no usable
    trial says nothing and the reader has to be told."""
    ax.text(-0.012, 1.02, "usable", transform=ax.transAxes, ha="right",
            va="bottom", fontsize=10.5, color=_INK_2)
    for x, u, n in zip(d, usable, trials):
        ax.text(x, 1.02, f"{u}/{n}", transform=ax.get_xaxis_transform(),
                ha="center", va="bottom", fontsize=11,
                color="#d13b2e" if u == 0 else _INK)


def plot_line_experiment(steps: pd.DataFrame, tables: dict[str, pd.DataFrame],
                         df: pd.DataFrame, out: Path) -> None:
    """The field line sweep's figures, written into [out].

    Emits `fieldday_establish_time.png`, `fieldday_establish_bytes.png`,
    `fieldday_power.png` and `fieldday_lineexp.png`. Each is skipped when the
    run does not carry its inputs, so a line sweep with no wire ledger still
    gets the ones it can support.

    The fifth field-day figure, `throughput_story.png`, is NOT here: its
    panels are the lane / GATT-leg / payload arms of the laboratory runs, and
    a line sweep carries none of them. It self-gates in
    `plot_throughput_story`, called from `main` for whichever run holds those
    arms.
    """
    line = _line_steps(steps)
    if line.empty:
        return
    _plot_establish_time(tables.get("fieldday_establish_time"),
                         tables.get("fieldday_establish_bytes"),
                         out / "fieldday_establish_time.png")
    _plot_establish_bytes(tables.get("fieldday_establish_bytes"),
                          out / "fieldday_establish_bytes.png")
    _plot_field_power(tables.get("fieldday_power"), line, df,
                      out / "fieldday_power.png")
    _plot_lineexp(line, out / "fieldday_lineexp.png")


def _plot_establish_time(t: pd.DataFrame | None, b: pd.DataFrame | None,
                         out: Path) -> None:
    """Mean seconds to each establishment stage against distance, +/- SEM, with
    the usable-trial count over each distance. The three curves separating is
    the finding: discovery holds up long after an ACK can come back."""
    if t is None or t.empty:
        return
    fig, ax = plt.subplots(figsize=(11.5, 6.4))
    _field_axes(fig, [ax])
    colors = [_C_DELIVERY, _C_USABLE, _C_SESSION]
    for (col, label), color in zip(_LINE_STAGES, colors):
        ax.errorbar(t["d"], t[f"mean_{col}"], yerr=t[f"sem_{col}"],
                    color=color, lw=2.0, marker="o", ms=9,
                    markeredgecolor=_SURFACE, markeredgewidth=2,
                    capsize=3, ecolor=color, elinewidth=1.4,
                    label=label, zorder=3)
    ax.set_ylim(bottom=0)
    ax.set_xlabel("Distance (m)", fontsize=12, color=_INK_2, labelpad=9)
    ax.set_ylabel("Control plane establishment time (s)", fontsize=12,
                  color=_INK_2, labelpad=9)
    ax.set_xticks(t["d"].tolist())
    usable = (b["usable_n"].tolist() if b is not None and not b.empty
              else t["n_t_usable_s"].tolist())
    _usable_header(ax, t["d"].tolist(), [int(u) for u in usable],
                   [int(n) for n in t["trials"]])
    leg = ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.12), ncol=3,
                    frameon=False, fontsize=11.5)
    for txt in leg.get_texts():
        txt.set_color(_INK_2)
    fig.subplots_adjust(left=0.085, right=0.98, top=0.93, bottom=0.2)
    fig.savefig(out, dpi=160, facecolor=_SURFACE)
    plt.close(fig)


def _plot_establish_bytes(b: pd.DataFrame | None, out: Path) -> None:
    """What one establishment trial costs the pair on the air, in kB: ANNOUNCE
    stacked under the Noise handshake. The bar shrinking with distance is not
    a saving — it is trials that never got far enough to spend the bytes."""
    if b is None or b.empty:
        return
    fig, ax = plt.subplots(figsize=(11.5, 6.4))
    _field_axes(fig, [ax])
    width = (float(b["d"].diff().dropna().min()) * 0.55
             if len(b) > 1 else 0.8)
    ann = b["announce"] / 1000.0
    hs = b["handshake"] / 1000.0
    ax.bar(b["d"], ann, width=width, color=_C_USABLE, label="ANNOUNCE",
           zorder=3)
    ax.bar(b["d"], hs, width=width, bottom=ann, color=_C_DELIVERY,
           label="Noise handshake", zorder=3)
    ax.set_xlabel("Distance (m)", fontsize=12, color=_INK_2, labelpad=9)
    ax.set_ylabel("kB per trial (both devices)", fontsize=12, color=_INK_2,
                  labelpad=9)
    ax.set_xticks(b["d"].tolist())
    _usable_header(ax, b["d"].tolist(),
                   [int(u) for u in b["usable_n"]],
                   [int(n) for n in b["trials"]])
    ax.set_title("Control plane costs", fontsize=15, color=_INK,
                 loc="left", pad=34)
    leg = ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.12), ncol=2,
                    frameon=False, fontsize=11.5)
    for txt in leg.get_texts():
        txt.set_color(_INK_2)
    fig.subplots_adjust(left=0.085, right=0.98, top=0.88, bottom=0.2)
    fig.savefig(out, dpi=160, facecolor=_SURFACE)
    plt.close(fig)


def _plot_field_power(pw: pd.DataFrame | None, line: pd.DataFrame,
                      df: pd.DataFrame, out: Path) -> None:
    """Left: charge drawn since the run started, per device — the discharge
    curve itself, which is what says the draw is flat rather than bursty.
    Right: mean draw during each step, against distance. Distance costs the
    static receiver more (it scans harder for a fading peer) and the mover
    less (fewer sends complete)."""
    series = power_series(df) if df is not None and not df.empty else pd.DataFrame()
    if series.empty:
        return
    role_of = (dict(zip(pw["dev"], pw["role"])) if pw is not None
               and not pw.empty else {})
    colors = {}
    palette = [_C_USABLE, _C_SESSION, _C_DELIVERY]

    fig, (ax, ax2) = plt.subplots(1, 2, figsize=(13.5, 6.2))
    _field_axes(fig, [ax, ax2])
    for i, (dev, g) in enumerate(sorted(series.groupby("device"))):
        colors[dev] = palette[i % len(palette)]
        g = g.sort_values("t")
        cc = pd.to_numeric(g["chargeCounterUah"], errors="coerce")
        if cc.dropna().empty:
            continue
        drawn = (cc.iloc[0] - cc) / 1000.0
        ax.plot(g["elapsed_s"] / 3600.0, drawn, color=colors[dev], lw=1.8,
                label=role_of.get(dev, dev), zorder=3)
    ax.set_xlabel("Elapsed (h)", fontsize=12, color=_INK_2, labelpad=9)
    ax.set_ylabel("Charge drawn since start (mAh)", fontsize=12, color=_INK_2,
                  labelpad=9)
    leg = ax.legend(loc="upper left", frameon=False, fontsize=11.5)
    for txt in leg.get_texts():
        txt.set_color(_INK_2)

    drawn_any = False
    for dev, color in colors.items():
        col = f"power_mA_{dev}"
        if col not in line.columns:
            continue
        agg = line.groupby("d")[col]
        mean = agg.mean()
        sem = agg.apply(_sem)
        if mean.dropna().empty:
            continue
        ax2.errorbar(mean.index, mean.values, yerr=sem.values, color=color,
                     lw=1.8, marker="o", ms=8, markeredgecolor=_SURFACE,
                     markeredgewidth=2, capsize=3, ecolor=color,
                     elinewidth=1.4, label=role_of.get(dev, dev), zorder=3)
        drawn_any = True
    if drawn_any:
        ax2.set_ylim(bottom=0)
        ax2.set_xticks(sorted(line["d"].unique()))
        leg2 = ax2.legend(loc="lower left", frameon=False, fontsize=11.5)
        for txt in leg2.get_texts():
            txt.set_color(_INK_2)
    ax2.set_xlabel("Distance (m)", fontsize=12, color=_INK_2, labelpad=9)
    ax2.set_ylabel("Mean draw during dwell (mA)", fontsize=12, color=_INK_2,
                   labelpad=9)
    fig.subplots_adjust(left=0.07, right=0.98, top=0.95, bottom=0.12,
                        wspace=0.22)
    fig.savefig(out, dpi=160, facecolor=_SURFACE)
    plt.close(fig)


def _plot_lineexp(line: pd.DataFrame, out: Path) -> None:
    """The line sweep on one sheet: what fraction of trials reached each link
    stage, how much of the offered traffic arrived one-way versus round trip,
    and the path loss the RSSI implies. The three panels share only the x
    axis on purpose — they are three different questions about one walk."""
    ds = sorted(line["d"].unique())
    fig, axes = plt.subplots(1, 3, figsize=(17, 5.4))
    _field_axes(fig, list(axes))
    ax_p, ax_d, ax_r = axes

    # (a) establishment probability — a stage counts as reached when its
    # per-step event count is above zero, the same rule establishment.csv uses.
    stages = [("discovered", _C_DELIVERY, 6.0, "Discovered"),
              ("session", _C_USABLE, 3.0, "Noise session"),
              ("usable", _C_SESSION, 1.2, "Usable (ACK back)")]
    for col, color, lw, label in stages:
        if col not in line.columns:
            continue
        pct = line.assign(_hit=pd.to_numeric(line[col], errors="coerce")
                          .fillna(0) > 0).groupby("d")["_hit"].mean() * 100
        ax_p.plot(pct.index, pct.values, color=color, lw=lw, marker="o",
                  ms=7, solid_capstyle="round", label=label, zorder=3)
    ax_p.set_ylim(-3, 105)
    ax_p.set_ylabel("Trials reaching the stage (%)", fontsize=11,
                    color=_INK_2, labelpad=8)
    ax_p.set_title("Establishment probability", fontsize=13, color=_INK,
                   loc="left")
    leg = ax_p.legend(loc="lower left", frameon=False, fontsize=10.5)
    for txt in leg.get_texts():
        txt.set_color(_INK_2)

    # (b) delivery — pooled over the distance's trials, not averaged over
    # them: a trial that sent nothing must not weigh as much as one that sent
    # a hundred. The gap between the two curves is the return path's cost.
    sent = line.groupby("d")["msg_sent"].sum()
    recv = line.groupby("d")["msg_recv"].sum()
    deliv = line.groupby("d")["msg_delivered"].sum()
    ok = sent > 0
    fwd = (100.0 * recv[ok] / sent[ok])
    rtt = (100.0 * deliv[ok] / sent[ok])
    ax_d.fill_between(fwd.index, rtt.values, fwd.values, color=_C_USABLE,
                      alpha=0.12, zorder=2)
    ax_d.plot(fwd.index, fwd.values, color=_C_SESSION, lw=1.8, marker="o",
              ms=6, label="Received (forward path)", zorder=3)
    ax_d.plot(rtt.index, rtt.values, color=_C_USABLE, lw=1.8, marker="o",
              ms=6, label="ACK-confirmed (round trip)", zorder=3)
    for x in ds:
        ax_d.text(x, 1.02, f"{int(sent.get(x, 0))}",
                  transform=ax_d.get_xaxis_transform(), ha="center",
                  va="bottom", fontsize=9.5, color=_INK_2)
    ax_d.set_ylim(-3, 105)
    ax_d.set_ylabel("Share of messages sent (%)", fontsize=11, color=_INK_2,
                    labelpad=8)
    ax_d.set_title("Delivery: forward vs. round trip", fontsize=13,
                   color=_INK, loc="left", pad=22)
    leg = ax_d.legend(loc="lower left", frameon=False, fontsize=10.5)
    for txt in leg.get_texts():
        txt.set_color(_INK_2)

    # (c) path loss — measured advert RSSI per distance with its spread, over
    # the log-distance fit `pathloss.txt` reports in words.
    if "rssi_adv_mean" in line.columns:
        m = line.groupby("d")["rssi_adv_mean"].mean()
        sd = line.groupby("d")["rssi_adv_mean"].std(ddof=1)
        fit = pathloss_coeffs(line)
        if fit is not None:
            a, n, _, _ = fit
            xs = np.linspace(max(min(ds), 1.0), max(ds), 200)
            ax_r.plot(xs, a - 10 * n * np.log10(xs), color=_C_USABLE, lw=2.0,
                      label="Log-distance fit", zorder=2)
        ax_r.errorbar(m.index, m.values, yerr=sd.values, color=_C_SESSION,
                      lw=0, marker="o", ms=7, capsize=3, ecolor=_C_SESSION,
                      elinewidth=1.4, label="Measured (mean +- sd)", zorder=3)
        leg = ax_r.legend(loc="lower left", frameon=False, fontsize=10.5)
        for txt in leg.get_texts():
            txt.set_color(_INK_2)
    ax_r.set_ylabel("Advertisement RSSI (dBm)", fontsize=11, color=_INK_2,
                    labelpad=8)
    ax_r.set_title("Path loss", fontsize=13, color=_INK, loc="left")

    for a in axes:
        a.set_xlabel("Distance (m)", fontsize=11, color=_INK_2, labelpad=8)
        a.set_xticks(ds)
    fig.subplots_adjust(left=0.05, right=0.99, top=0.9, bottom=0.13,
                        wspace=0.24)
    fig.savefig(out, dpi=160, facecolor=_SURFACE)
    plt.close(fig)


def plot_throughput_story(steps: pd.DataFrame, out: Path) -> None:
    """The laboratory characterisation of one pair at close range, as up to
    four panels — each drawn only when the run actually carried that arm, and
    the figure skipped entirely when none of them did.

    The arms are the throughput-ceiling lane sweep (`lanes=`), the raw-GATT
    leg comparison (`leg=`) and the payload arm (`p=<n>B`). A line sweep
    carries none of them, so a line-sweep-only trace produces nothing here.
    """
    if steps.empty:
        return
    lanes = (steps[pd.to_numeric(steps.get("lanes"), errors="coerce").notna()]
             if "lanes" in steps.columns else pd.DataFrame())
    legs = (steps[steps["leg"].notna()] if "leg" in steps.columns
            else pd.DataFrame())
    if not legs.empty and "raw_rx_Bps" in legs.columns:
        legs = legs[pd.to_numeric(legs["raw_rx_Bps"], errors="coerce").notna()]
    else:
        legs = pd.DataFrame()
    payloads = pd.DataFrame()
    if {"payloadB", "airB_per_msg"} <= set(steps.columns):
        p = steps.dropna(subset=["payloadB", "airB_per_msg"])
        if p["payloadB"].nunique() > 1:
            payloads = p

    panels = []
    if not lanes.empty and "active_s" in lanes.columns:
        panels += ["capacity", "latency"]
    if not legs.empty:
        panels.append("raw")
    if not payloads.empty:
        panels.append("payload")
    if not panels:
        return

    # A floor on the width: one panel alone still has to leave room for the
    # figure title and the y-axis label, which a 4.6" canvas clips.
    fig, axes = plt.subplots(1, len(panels),
                             figsize=(max(4.6 * len(panels), 9.5), 4.6),
                             squeeze=False)
    axes = list(axes[0])
    _field_axes(fig, axes)
    by_name = dict(zip(panels, axes))

    if "capacity" in by_name:
        # Offered = every message pushed into the send path; carried = those
        # whose end-to-end ACK came back. Both per second of the step's ACTIVE
        # window, with each trial plotted as a dot over the bar: two trials do
        # not make a tight estimate and the figure should not pretend they do.
        ax = by_name["capacity"]
        ns = sorted(lanes["lanes"].unique())
        off, car, off_pts, car_pts = [], [], [], []
        for n in ns:
            g = lanes[lanes["lanes"] == n]
            a = pd.to_numeric(g["active_s"], errors="coerce")
            o = pd.to_numeric(g["msg_sent"], errors="coerce") / a
            c = pd.to_numeric(g["msg_delivered"], errors="coerce") / a
            off.append(o.mean())
            car.append(c.mean())
            off_pts.append(o.dropna().tolist())
            car_pts.append(c.dropna().tolist())
        x = np.arange(len(ns), dtype=float)
        ax.bar(x - 0.19, off, width=0.36, color="#e0a51f", label="Offered",
               zorder=3)
        ax.bar(x + 0.19, car, width=0.36, color=_C_SESSION, label="Carried",
               zorder=3)
        for xi, pts in zip(x - 0.19, off_pts):
            ax.plot([xi] * len(pts), pts, "o", ms=4, color=_INK_MUTED, zorder=4)
        for xi, pts in zip(x + 0.19, car_pts):
            ax.plot([xi] * len(pts), pts, "o", ms=4, color=_INK_MUTED, zorder=4)
        ax.set_xticks(x)
        ax.set_xticklabels([str(int(n)) for n in ns])
        ax.set_xlabel("Concurrent senders", fontsize=11, color=_INK_2)
        ax.set_ylabel("Messages/s", fontsize=11, color=_INK_2)
        ax.set_title("Capacity does not scale", fontsize=12, color=_INK,
                     loc="left")
        leg = ax.legend(frameon=False, fontsize=10)
        for txt in leg.get_texts():
            txt.set_color(_INK_2)

    if "latency" in by_name:
        # Log scale, because the interesting range spans two decades. The
        # reference line is the run's OWN fastest step median: everything
        # above it is queueing, not loss — the delivery panel shows nothing
        # was dropped at the same points.
        ax = by_name["latency"]
        ns = sorted(lanes["lanes"].unique())
        med = [pd.to_numeric(lanes[lanes["lanes"] == n]["rtt_median_ms"],
                             errors="coerce").mean() for n in ns]
        p90 = [pd.to_numeric(lanes[lanes["lanes"] == n]["rtt_p90_ms"],
                             errors="coerce").mean() for n in ns]
        ax.plot(range(len(ns)), med, color=_C_SESSION, lw=1.8, marker="o",
                ms=6, label="RTT median", zorder=3)
        ax.plot(range(len(ns)), p90, color=_C_USABLE, lw=1.8, marker="o",
                ms=6, label="RTT p90", zorder=3)
        floor = pd.to_numeric(steps.get("rtt_median_ms"),
                              errors="coerce").min()
        if pd.notna(floor) and floor > 0:
            ax.axhline(floor, color="#d13b2e", lw=1.1, ls=":", zorder=2)
            ax.text(0.02, floor, f"unsaturated {floor:.0f} ms",
                    transform=ax.get_yaxis_transform(), va="bottom",
                    fontsize=9.5, color="#d13b2e")
        ax.set_yscale("log")
        ax.set_xticks(range(len(ns)))
        ax.set_xticklabels([str(int(n)) for n in ns])
        ax.set_xlabel("Concurrent senders", fontsize=11, color=_INK_2)
        ax.set_ylabel("Round trip (ms, log)", fontsize=11, color=_INK_2)
        ax.set_title("Bufferbloat, not loss", fontsize=12, color=_INK,
                     loc="left")
        leg = ax.legend(frameon=False, fontsize=10)
        for txt in leg.get_texts():
            txt.set_color(_INK_2)

    if "raw" in by_name:
        # Counted at the RECEIVER: a raw write completes at enqueue, so the
        # sender's own ledger measures the queue, not the air. The reference
        # line is what a pair would carry if its two GATT legs added up — the
        # gap to `stripe` is the measurement that says they share one radio.
        ax = by_name["raw"]
        seen = set(legs["leg"])
        order = [name for name in ("notify", "write", "stripe") if name in seen]
        order += [name for name in sorted(seen) if name not in order]
        means, pts = [], []
        for name in order:
            v = pd.to_numeric(legs[legs["leg"] == name]["raw_rx_Bps"],
                              errors="coerce").dropna() / 1000.0
            means.append(v.mean())
            pts.append(v.tolist())
        ax.bar(range(len(order)), means,
               color=[_C_SESSION, _C_USABLE, "#5b3ec4"][:len(order)]
               if len(order) <= 3 else _C_SESSION, width=0.6, zorder=3)
        for i, v in enumerate(pts):
            ax.plot([i] * len(v), v, "o", ms=4, color=_INK_MUTED, zorder=4)
            ax.text(i, max([means[i]] + v), f"n={len(v)}", ha="center",
                    va="bottom", fontsize=9.5, color=_INK_2)
        both = {name: m for name, m in zip(order, means)
                if name in ("notify", "write")}
        if len(both) == 2:
            total = sum(both.values())
            ax.axhline(total, color="#d13b2e", lw=1.1, ls=":", zorder=2)
            ax.text(0.02, total, "if the two legs added up",
                    transform=ax.get_yaxis_transform(), va="bottom",
                    fontsize=9.5, color="#d13b2e")
            ax.set_ylim(top=total * 1.18)
        ax.set_xticks(range(len(order)))
        ax.set_xticklabels(order)
        ax.set_xlabel("GATT leg used", fontsize=11, color=_INK_2)
        ax.set_ylabel("Received (KB/s)", fontsize=11, color=_INK_2)
        ax.set_title("Raw pipe: one shared radio", fontsize=12, color=_INK,
                     loc="left")

    if "payload" in by_name:
        # Air bytes per delivered message against payload size, labelled with
        # the ratio to the payload: flat overhead means a bigger message is
        # cheaper per byte, which is the whole argument for batching.
        ax = by_name["payload"]
        sizes = sorted(payloads["payloadB"].unique())
        vals = [pd.to_numeric(payloads[payloads["payloadB"] == s]
                              ["airB_per_msg"], errors="coerce").mean()
                for s in sizes]
        ax.bar(range(len(sizes)), vals, color=_C_SESSION, width=0.6, zorder=3)
        for i, (s, v) in enumerate(zip(sizes, vals)):
            if s:
                ax.text(i, v, f"{v / s:.2f}x", ha="center", va="bottom",
                        fontsize=9.5, color=_INK_2)
        ax.set_xticks(range(len(sizes)))
        ax.set_xticklabels([f"{int(s)} B" for s in sizes])
        ax.set_xlabel("Payload per message", fontsize=11, color=_INK_2)
        ax.set_ylabel("Air bytes per message", fontsize=11, color=_INK_2)
        ax.set_title("Wire cost is flat in payload", fontsize=12, color=_INK,
                     loc="left")

    fig.suptitle("Laboratory characterization: the same pair at close range",
                 fontsize=14, color=_INK, x=0.012, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.92), w_pad=2.4)
    fig.savefig(out, dpi=160, facecolor=_SURFACE)
    plt.close(fig)


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
            pts = sub[_col(sub, "event") == stage]
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


_LOAD_SWEEP_LABEL = re.compile(r"^N=(\d+)\s+L=(\S+)\s+t(\d+)$")


def load_sweep_points(steps: pd.DataFrame) -> pd.DataFrame:
    """Per-step (clique size N, offered load, arrival) for a load-sweep run.

    Recognises the diluting-clique / load-sweep labels `N=<n> L=<level> t<rep>`
    (level is a percent like `30%` or a name like `low`/`sat`). The offered
    load is the ACHIEVED rate each node originated in the step — messages sent
    / N / dwell seconds, in msg/s — so the x-axis is a measured rate rather
    than a nominal knob and stays comparable across clique sizes. Arrival is
    recv-OR-ACK (see steps_table). Empty when the run is not a load sweep.
    """
    rows = []
    for _, r in steps.iterrows():
        m = _LOAD_SWEEP_LABEL.match(str(r.get("label", "")))
        if not m:
            continue
        sent = r.get("msg_sent") or 0
        arr = r.get("arrival_rate")
        if not sent or arr is None or pd.isna(arr):
            continue
        n = int(m.group(1))
        dwell = max((r["t1"] - r["t0"]) / 1000.0, 1e-9)
        rows.append({"N": n, "level": m.group(2),
                     "rate_msg_s": sent / n / dwell,
                     "arrival_pct": 100.0 * float(arr)})
    return pd.DataFrame(rows)


# Clique size is encoded by MARKER SHAPE (+ line style), not colour, so the
# same N reads identically across panels and survives greyscale / CVD.
# Keys 1 and 9 exist for the dial probe's DUT rotation (nine phones); the
# load sweep's N=2..8 encodings are unchanged.
_SWEEP_MARKER = {1: "v", 2: "o", 3: "s", 4: "^", 5: "x", 6: "+", 7: "*",
                 8: "D", 9: "P"}
_SWEEP_LINE = {1: (0, (4, 2)), 2: "-", 3: "--", 4: "-.", 5: ":",
               6: (0, (3, 1, 1, 1)), 7: (0, (5, 1)), 8: (0, (1, 1)),
               9: (0, (6, 1, 1, 1))}


def plot_load_sweep(ax, pts: pd.DataFrame, title: str) -> None:
    """Draw arrival-vs-offered-load curves, one line per clique size N, onto
    [ax]. Each point is the mean over the repeat trials at that (N, level) with
    a +/- sd bar; x is the mean achieved msg/s per node. N is distinguished by
    marker shape and line style rather than colour."""
    ns = sorted(pts.N.unique())
    for n in ns:
        g = pts[pts.N == n].groupby("level")
        agg = sorted(
            ((grp.rate_msg_s.mean(), grp.arrival_pct.mean(),
              grp.arrival_pct.std(ddof=0)) for _, grp in g),
            key=lambda p: p[0])
        xs = [a[0] for a in agg]
        ys = [a[1] for a in agg]
        es = [a[2] for a in agg]
        ax.errorbar(xs, ys, yerr=es, marker=_SWEEP_MARKER.get(n, "o"),
                    ms=8, lw=1.5, capsize=3, color="#222222",
                    markeredgewidth=1.6,
                    linestyle=_SWEEP_LINE.get(n, "-"), label=f"N={n}")
    ax.set_xscale("log")
    ax.set_xlabel("offered load per node (msg/s)")
    ax.set_ylabel("delivery — arrived (recv or ACK), %")
    ax.set_ylim(0, 100)
    ax.grid(True, which="both", alpha=0.3)
    ax.legend(title="clique size", ncol=2, fontsize=9)
    ax.set_title(title)


def write_load_sweep(steps: pd.DataFrame, out: Path, exp: str) -> bool:
    """Emit the single-run load-sweep delivery graph, or return False when the
    run's labels are not a load sweep."""
    pts = load_sweep_points(steps)
    if pts.empty:
        return False
    fig, ax = plt.subplots(figsize=(10, 6))
    plot_load_sweep(ax, pts, f"{exp} — arrival vs offered load, per clique size "
                             "(mean ± sd over repeats)")
    fig.tight_layout()
    fig.savefig(out, dpi=150)
    plt.close(fig)
    return True


# --------------------------------------------------------------------------- #
# Dial grid probe (dial-2-nm-grid-converge)
# --------------------------------------------------------------------------- #
# The failure deadline: a dial not GATT-usable within the step dwell counts
# failed. Matches the preset's dwellSec (20 s).
DIAL_PROBE_DEADLINE_MS = 20_000


def dial_probe_table(df: pd.DataFrame) -> pd.DataFrame:
    """One row per ESTABLISHMENT of the dial grid, keyed by its cell.

    The grid has TWO variables and the runner stamps both on the marker that
    OPENS each step, so a cell is a per-device window and needs no inference:

      popN        the population — how many phones have their radio up
      maxParallel M — the cap on how many central dials this phone may have
                  IN FLIGHT during the step. The transport dials greedily on
                  its own; M only bounds it, which is why the answer is a
                  RATE (establishments per fixed window) and not the fate of
                  a scripted burst.

    Windows are PER DEVICE, opened by that device's own step marker and
    closed by its next marker — every phone runs every cell, so there is no
    device under test and nothing to join across clocks.

    Inside the window each central `connected` link record is one
    establishment, and it carries its own attribution:

      inFlight         other central dials still underway when it landed
      peripheralLinks  live inbound legs at that instant
      totalLinks       live legs across both roles

    The last two are the experiment's confound control. Nothing caps inbound
    links — only a central dials — but both roles draw on ONE controller
    link budget, so at (N=8, M=2) a phone can be holding 7 inbound legs and
    failing for want of slots rather than for dial concurrency. The two
    numbers are what tells those apart.

    Each establishment also gets the rest of the ladder: `ms_to_session` (the
    Noise session on that leg or its peer) and `ms_to_converged` (the first
    instant the phone holds BOTH legs to that peer identity — its own central
    leg usable AND an inbound peripheral leg from the same peer). Leg
    liveness is the per-path `connected` -> `drop` interval over the WHOLE
    device trace, snapshots included, because a peer's reverse leg can
    predate the window.

    A cell that established NOTHING still gets a row (established=0, every ms
    null): an absent row would be indistinguishable from a phone that never
    ran the step, and the zero cells are exactly where the ceiling shows.
    `recorded` is the runner's own `dialcell` count for the same step — an
    independent witness to the count derived here.
    """
    markers = df[df._type == "marker"]
    if markers.empty or "maxParallel" not in markers.columns:
        return pd.DataFrame()
    link = df[df._type == "link"]
    cells = df[df._type == "dialcell"] if "dialcell" in set(df._type) else None
    rows = []
    for dev, dm in markers.groupby("_device"):
        dm = dm.sort_values("_t")
        marker_ts = dm._t.tolist()
        dl = link[link._device == dev].sort_values("_t")
        ev = _col(dl, "event")
        path = _col(dl, "path")
        peer = _col(dl, "peer")
        role = _col(dl, "role")
        # Whole-trace path -> peer hex binding (first sighting wins; a
        # pathId never migrates between identities within one run).
        bound: dict = {}
        for p_, h in zip(path.tolist(), peer.tolist()):
            if isinstance(p_, str) and isinstance(h, str) and p_ not in bound:
                bound[p_] = h
        # Per-path liveness intervals: `connected` opens (snapshots
        # included — a leg alive since before the recording), the next
        # `drop` closes, an unclosed leg runs to the end of the trace.
        opens: dict = {}
        live: dict = {}
        for p_, e, t in zip(path.tolist(), ev.tolist(), dl._t.tolist()):
            if not isinstance(p_, str):
                continue
            if e == "connected":
                opens.setdefault(p_, t)
            elif e == "drop" and p_ in opens:
                live.setdefault(p_, []).append((opens.pop(p_), t))
        for p_, t in opens.items():
            live.setdefault(p_, []).append((t, math.inf))
        # The runner's own per-step count, keyed by step label.
        recorded: dict = {}
        if cells is not None:
            dc = cells[cells._device == dev]
            for _, c in dc.iterrows():
                lbl = c.get("step")
                if isinstance(lbl, str):
                    recorded[lbl] = int(_num(c.get("established"), 0))
        for i, (_, mk) in enumerate(dm.iterrows()):
            m = mk.get("maxParallel")
            if m is None or (isinstance(m, float) and math.isnan(m)):
                continue
            t0 = mk._t
            t1 = marker_ts[i + 1] if i + 1 < len(marker_ts) else math.inf
            label = mk.get("label", "")
            cell = {
                "device": dev,
                "pop_n": int(_num(mk.get("popN"), 0)),
                "m": int(m),
                "rep": int(_num(mk.get("rep"), 1)),
                "step": label if isinstance(label, str) else "",
                "recorded": recorded.get(label),
            }
            in_win = (dl._t >= t0) & (dl._t < t1)
            est = dl[in_win & (ev == "connected") & (role == "central")]
            cell["established"] = len(est)
            if est.empty:
                rows.append({**cell, "conn_idx": 0, "ms_to_establish": None,
                             "in_flight": None, "peripheral_links": None,
                             "total_links": None, "ms_to_session": None,
                             "ms_to_converged": None})
                continue
            for k, (_, e) in enumerate(est.iterrows(), start=1):
                target = e.get("path")
                t_usable = e._t
                target_peer = e.get("peer")
                if not isinstance(target_peer, str):
                    target_peer = bound.get(target)
                sess_mask = path == target
                if target_peer is not None:
                    sess_mask = sess_mask | (peer == target_peer)
                hit = dl[in_win & sess_mask & (ev == "session")
                         & (dl._t >= t_usable)]
                ms_sess = None if hit.empty else float(hit._t.iloc[0] - t0)
                # Dual-leg convergence: earliest instant >= this leg's usable
                # stamp at which an inbound peripheral leg bound to the same
                # identity is live, while our central leg still is.
                ms_conv = None
                if target_peer is not None:
                    c_end = next((y for x, y in live.get(target, [])
                                  if x <= t_usable < y), math.inf)
                    best = math.inf
                    for p_, ivs in live.items():
                        if not p_.startswith("peripheral:"):
                            continue
                        if bound.get(p_) != target_peer:
                            continue
                        for x, y in ivs:
                            cand = max(t_usable, x)
                            if cand < y and cand < c_end:
                                best = min(best, cand)
                    if best < t1:
                        ms_conv = float(best - t0)
                rows.append({
                    **cell,
                    "conn_idx": k,
                    "ms_to_establish": float(t_usable - t0),
                    "in_flight": _num(e.get("inFlight"), None),
                    "peripheral_links": _num(e.get("peripheralLinks"), None),
                    "total_links": _num(e.get("totalLinks"), None),
                    "ms_to_session": ms_sess,
                    "ms_to_converged": ms_conv,
                })
    return pd.DataFrame(rows)


# How far below the best median establishment count still counts as "as good
# as it gets" — half an establishment, i.e. inside the resolution of the
# measurement itself.
KNEE_TOL = 0.5


def dial_scores(dial: pd.DataFrame) -> pd.DataFrame:
    """Per (device, population): establishments per window against M, and the
    M at which the count stops rising.

    The SATURATION KNEE is the verdict. Raising M raises the establishment
    rate only while the phone's dial pipeline is the binding constraint; past
    that the curve flattens (or falls) and the extra parallelism buys
    nothing. `knee_m` is the smallest M whose median count is within
    [KNEE_TOL] of the best median seen at that population — the first M that
    is already as good as it gets, which is the M worth shipping. It is
    reported per POPULATION because a phone's dial capacity is not a property
    of the phone alone: the same M lands differently in a room of 3 and a
    room of 8.

    `max_total_links` is the link-budget ceiling this device was actually
    observed at, across both roles. Read it beside the knee: a knee that
    coincides with the device's max_total_links flattening is the
    CONTROLLER's limit, not the dial path's, and the two are otherwise the
    same number.
    """
    rows = []
    for (dev, pop_n), g in dial.groupby(["device", "pop_n"]):
        row = {"device": dev, "pop_n": pop_n}
        # One count per WINDOW: `established` repeats on each of a cell's
        # rows, so the cell is deduped before any of this is averaged.
        cells = g.drop_duplicates(subset=["m", "rep"])[
            ["m", "rep", "established"]]
        med = {}
        for m, gm in cells.groupby("m"):
            v = float(gm.established.median())
            med[int(m)] = v
            row[f"est_m{int(m)}"] = round(v, 2)
        best = max(med.values()) if med else 0.0
        knee = None
        for m in sorted(med):
            if med[m] >= best - KNEE_TOL:
                knee = m
                break
        row["knee_m"] = knee
        row["best_est"] = round(best, 2)
        row["max_m"] = max(med) if med else None
        for col, name in (("ms_to_establish", "median_ms_establish_at_knee"),
                          ("ms_to_session", "median_ms_session_at_knee"),
                          ("ms_to_converged", "median_ms_converged_at_knee")):
            v = g[g.m == knee][col].dropna() if knee is not None \
                else pd.Series(dtype=float)
            row[name] = round(float(v.median()), 1) if len(v) else None
        for col, name in (("in_flight", "max_in_flight"),
                          ("peripheral_links", "max_peripheral_links"),
                          ("total_links", "max_total_links")):
            v = g[col].dropna()
            row[name] = int(v.max()) if len(v) else None
        rows.append(row)
    return pd.DataFrame(rows)


def plot_dial_probe(dial: pd.DataFrame, out: Path) -> list[Path]:
    """One figure per POPULATION N, plus a headline copy at the largest N.

    X is M, the allowed parallel dials. The top panel is the experiment's
    answer — establishments per fixed window — and the three below it are the
    formation ladder for the legs that did establish: GATT-usable, Noise
    session, dual-leg convergence. Every panel is a median with p10-p90 bars,
    one series per DEVICE, shape- and line-coded so the figure survives
    greyscale.

    Splitting by population is the whole point of the grid: overlaying every
    N on one axis would put M=4 in a five-phone room on the same point as M=4
    in an eight-phone room. [out] is the headline path; the per-N files sit
    beside it as `<stem>_N<n><suffix>`. Returns every file written.
    """
    written: list[Path] = []
    pops = sorted(int(n) for n in dial.pop_n.unique())
    devs = sorted(str(d) for d in dial.device.unique())
    keyed = {d: i + 1 for i, d in enumerate(devs)}
    for pop_n in pops:
        sub = dial[dial.pop_n == pop_n]
        if sub.empty:
            continue
        fig, (ax_e, ax_u, ax_s, ax_c) = plt.subplots(
            4, 1, figsize=(10, 14), sharex=True,
            gridspec_kw={"height_ratios": [3, 3, 3, 3]})
        panels = [
            (ax_u, "ms_to_establish",
             "ms to GATT-usable\n(median, p10-p90)"),
            (ax_s, "ms_to_session", "ms to Noise session\n(median, p10-p90)"),
            (ax_c, "ms_to_converged",
             "ms to dual-leg converged\n(median, p10-p90)"),
        ]
        for dev, g in sub.groupby("device"):
            k = keyed[str(dev)]
            style = dict(marker=_SWEEP_MARKER.get(k, "o"), ms=7, lw=1.4,
                         color="#222222", markeredgewidth=1.5,
                         linestyle=_SWEEP_LINE.get(k, "-"))
            # The headline panel: one point per window, so the cell is
            # deduped before the median.
            cells = g.drop_duplicates(subset=["m", "rep"])
            ms, med, lo, hi = [], [], [], []
            for m, gm in sorted(cells.groupby("m"), key=lambda kv: kv[0]):
                v = gm.established
                ms.append(m)
                med.append(float(v.median()))
                lo.append(float(v.median() - v.quantile(0.10)))
                hi.append(float(v.quantile(0.90) - v.median()))
            if ms:
                ax_e.errorbar(ms, med, yerr=[lo, hi], capsize=3,
                              label=f"{short(str(dev))}", **style)
            for ax, col, _ in panels:
                ms, med, lo, hi = [], [], [], []
                for m, gm in sorted(g.groupby("m"), key=lambda kv: kv[0]):
                    v = gm[col].dropna()
                    if not len(v):
                        continue
                    ms.append(m)
                    med.append(float(v.median()))
                    lo.append(float(v.median() - v.quantile(0.10)))
                    hi.append(float(v.quantile(0.90) - v.median()))
                if ms:
                    ax.errorbar(ms, med, yerr=[lo, hi], capsize=3, **style)
        ax_e.legend(fontsize=8, ncol=2)
        ax_e.set_title(f"population N={pop_n} radios up", fontsize=11)
        ax_e.set_ylabel("establishments per window\n(median, p10-p90)",
                        fontsize=9)
        for ax, _, ylabel in panels:
            ax.set_ylabel(ylabel, fontsize=9)
        for ax in (ax_e, ax_u, ax_s, ax_c):
            ax.grid(alpha=0.3)
        ax_c.set_xlabel("allowed parallel dials M")
        ax_c.set_xticks(sorted(sub.m.unique()))
        fig.tight_layout()
        per_n = out.with_name(f"{out.stem}_N{pop_n}{out.suffix}")
        fig.savefig(per_n, dpi=150)
        written.append(per_n)
        # The headline figure IS the largest population's — the crowded room
        # is the one that decides whether the extra parallelism pays.
        if pop_n == pops[-1]:
            fig.savefig(out, dpi=150)
            written.append(out)
        plt.close(fig)
    return written


# --------------------------------------------------------------------------- #
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+",
                    help="traces.db and/or exp_*.jsonl files")
    ap.add_argument("--out", default="analysis", help="output directory")
    ap.add_argument("--exp", default=None,
                    help="only analyze this experiment name (filtered in SQL, "
                         "so other experiments are never read)")
    ap.add_argument("--clocks", default=None, metavar="PATH",
                    help="clock offsets measured by "
                         "tools/sync_phone_clocks.sh --json. The only sound "
                         "source: markers are stamped on a schedule, so they "
                         "cannot reveal a constant offset.")
    ap.add_argument("--types", default=None,
                    help="comma-separated record types to load, e.g. "
                         "'power,marker' for a power ladder. Cuts memory by "
                         "orders of magnitude on a saturating run, where "
                         "message/custody/session are ~99.5%% of records. "
                         "Omit to load everything.")
    args = ap.parse_args()

    clocks = None
    if args.clocks:
        try:
            clocks = json.loads(Path(args.clocks).read_text())
        except (OSError, ValueError) as e:
            print(f"cannot read --clocks {args.clocks}: {e}", file=sys.stderr)
            return 1

    types = ({t.strip() for t in args.types.split(",") if t.strip()}
             if args.types else None)
    if types and "marker" not in types:
        # The re-arm guard finds an abandoned arm from `placement` markers.
        # Without them it cannot see one, and an unguarded frame reads the
        # abandoned arm's sends as part of the run — silently, because the
        # guard has nothing to warn about. Markers are ~1000 rows.
        print("  --types has no 'marker': adding it (the re-arm guard needs it)")
        types = types | {"marker"}

    frames = []
    for raw in args.inputs:
        p = Path(raw)
        if not p.exists():
            print(f"no such file: {p}", file=sys.stderr)
            return 1
        frames.append(load_db(p, exp=args.exp, types=types)
                      if p.suffix == ".db" else load_jsonl([p]))
    df = pd.concat(frames, ignore_index=True)
    if df.empty:
        print("no records found", file=sys.stderr)
        return 1

    out_root = Path(args.out)
    for exp, edf in df.groupby("_exp"):
        edf = _drop_pre_arm(edf)
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
            summary += mesh_summary(paths, edf, clocks)
        (out / "summary.txt").write_text(summary)
        if not latency.empty:
            latency.to_csv(out / "latency.csv", index=False)

        dropt = drop_table(edf)
        if not dropt.empty:
            dropt.to_csv(out / "drops.csv", index=False)
            with (out / "summary.txt").open("a") as fh:
                fh.write("\nPacket loss by site (drop records)\n" + "-" * 60 + "\n")
                fh.write(dropt.to_string(index=False) + "\n")
        buft = buf_table(edf)
        if not buft.empty:
            buft.to_csv(out / "buffers.csv", index=False)
        aborts = edf[(edf._type == "runner")]
        if not aborts.empty:
            with (out / "summary.txt").open("a") as fh:
                fh.write("\nRUNNER ABORTS — this run is NOT clean\n" + "-" * 60 + "\n")
                for _, r in aborts.iterrows():
                    fh.write(f"  {short(r._device)}: {r.get('event')} at step "
                             f"'{r.get('step')}' ({r.get('detail')})\n")

        bench = bench_constants(edf)
        series = power_series(edf)
        if not series.empty:
            series.to_csv(out / "power_series.csv", index=False)

        cap = session_cap(edf) if bench is None else session_cap(
            edf, t_fail_us=bench[0],
            t_handshake_us=bench[1] + T_HANDSHAKE_BLE_US)
        if not cap.empty:
            cap.to_csv(out / "session_cap.csv", index=False)
            with (out / "summary.txt").open("a") as fh:
                fh.write(session_cap_summary(cap))

        segs = marker_segments(edf)
        if segs:
            steps = steps_table(edf, segs, latency)
            steps.to_csv(out / "steps.csv", index=False)
            est = establishment_table(steps)
            if not est.empty:
                est.to_csv(out / "establishment.csv", index=False)
            ladder = ladder_table(steps)
            if not ladder.empty:
                ladder.to_csv(out / "ladder.csv", index=False)
            pw = power_ladder(edf, segs, device_roles(edf))
            if not pw.empty:
                pw.to_csv(out / "power_ladder.csv", index=False)
            fit = pathloss_fit(steps)
            if fit:
                (out / "pathloss.txt").write_text(fit)
            plot_range(steps, out / "range.png")
            # The field line sweep's own tables and figures. Gated on the run
            # carrying distances, so a stationary experiment writes none of
            # them; each individual table is skipped again when the trace
            # lacks its records (wire, power).
            fieldday = line_experiment_tables(steps, edf)
            for stem, table in fieldday.items():
                table.to_csv(out / f"{stem}.csv", index=False)
            if fieldday:
                plot_line_experiment(steps, fieldday, edf, out)
            write_load_sweep(steps, out / "load_sweep_delivery.png", exp)
            # The lab companion to the line sweep. Self-gating on its own arms
            # (lanes / GATT leg / payload sizes) rather than on distance,
            # because those arms are run stationary — gating it on distance
            # would mean it could never be produced at all.
            plot_throughput_story(steps, out / "throughput_story.png")
        scale = mesh_scale(edf, segs)
        if not scale.empty:
            scale.to_csv(out / "mesh_scale.csv", index=False)

        dial = dial_probe_table(edf)
        if not dial.empty:
            dial.to_csv(out / "dial_probe.csv", index=False)
            scores = dial_scores(dial)
            if not scores.empty:
                scores.to_csv(out / "dial_scores.csv", index=False)
            plot_dial_probe(dial, out / "dial_probe.png")

        plot_rssi(edf, out / "rssi_timeline.png")
        plot_link_stages(edf, out / "link_stages.png")
        plot_wire(edf, out / "wire_bytes.png")
        print(f"[{exp}] -> {out}/  "
              f"({len(edf)} records, {edf._device.nunique()} device(s), "
              f"{len(segs)} step(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main())
