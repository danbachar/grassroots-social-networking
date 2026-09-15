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
measures: a payload above one sealed packet (138 B) fragments, and each
fragment re-pays the full 106-byte overhead.

Usage:
    python3 analyze.py data/traces.db --out analysis
    python3 analyze.py exp_dry-1.jsonl other_device_exp_dry-1.jsonl --out analysis
    python3 analyze.py data/traces.db --exp dry-1 --out analysis

Dependencies: pandas, numpy, matplotlib (see analysis_requirements.txt).
"""
from __future__ import annotations

import argparse
import bisect
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
# A ring-radius marker: `r=<hops>` — the greatest ring distance a link was
# allowed to span in that trial, i.e. the connectivity the stage was run at.
# Parsed into its own segment variable rather than re-matched at every call
# site, which is the debt the clique's six copy-pasted `N=` matches became.
MARKER_RADIUS_RE = re.compile(r"\br\s*=\s*(\d+)")
# What ONE occurrence of each link stage counts. The app emits four of them
# per GATT leg and three per peer, so a converged dual-role pair produces TWO
# `connected` events and ONE `session`. A ratio between stages of different
# cardinality therefore has a ceiling of 50%, not 100% -- reading 42% as "half
# the links fail to become addressable" is the error this mapping exists to
# stop. Compare stages only within a cardinality, or normalise first.
LINK_STAGE_COUNTS = {
    "discovered": "peer",       # a verified ANNOUNCE from that peer
    "gattConnected": "leg",
    "identified": "leg",
    "connected": "leg",
    "session": "peer",          # one Noise session, however many legs carry it
    "usable": "peer",           # first end-to-end ACK from that peer
    "drop": "leg",
}
LINK_STAGES = list(LINK_STAGE_COUNTS)
# FragmentHandler.fragmentThreshold: payloads above this are split, and each
# fragment gets a RANDOM packetId — so relay records can no longer be joined
# to the messageId and hop counts for such messages are not trustworthy.
FRAGMENT_THRESHOLD_B = 138  # 247 - 3 - (60 hdr + 25 noise + 21 frame)
# Runner markers that annotate a boundary or an event but are not steps. Every
# OTHER marker opens a step segment — a throughput step ("saturate", "p=264B")
# has no position at all, and dropping it would make the whole experiment
# invisible in steps.csv.
CONTROL_MARKERS = {"links-reset", "sessions-reset", "custody-reset",
                   "link-settled", "saturate-start", "raw-start", "end",
                   "aborted",
                   # The dwell's own end, stamped before the reset that
                   # follows it. A boundary inside a step, not a step.
                   "run-end",
                   # Manual-join lifecycle stamps: the shared-anchor proof,
                   # the radio transitions, and the battery stop. Events on
                   # the timeline, not dwell windows — as segments they were
                   # splitting real steps and polluting steps.csv.
                   "placement", "bt-on", "bt-off", "battery-floor",
                   # In-dwell events: the send gate opening and the zombie
                   # flag. Timeline stamps like the radio transitions — as
                   # segments they shattered every step they landed inside.
                   "session-up", "radio-suspect",
                   # Ring sweep: the gate arming and the links-only sever,
                   # both stamped inside a step's reset slot. Boundaries
                   # within a step, not steps — unlisted they would shatter
                   # every ring trial into fragments.
                   "ring-gate", "links-severed"}
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


def sync_reach(df: pd.DataFrame) -> pd.DataFrame:
    """How much of its own seen-set each node managed to advertise per round.

    The sync exchange is asker-driven: a holder conveys only what the asker's
    filter says it lacks, inside the window that filter spans. One frame names
    a bounded number of ids, so a node seeing traffic faster than it can
    advertise falls behind its own history and is sent only what falls in the
    slice it did name. `pending` is the ground the cursor still had to cover
    when the round opened, `seenTotal` the whole seen-set; their ratio is the
    reach, and delivery outcomes alone cannot separate "the holder had
    nothing" from "the asker never asked".
    """
    if df.empty or "_type" not in df.columns:
        return pd.DataFrame()
    d = df[df._type == "sync"]
    if d.empty:
        return pd.DataFrame()
    d = d.copy()
    for c in ("frames", "pending", "seenTotal"):
        d[c] = pd.to_numeric(d.get(c), errors="coerce")
    d = d.dropna(subset=["pending", "seenTotal"])
    if d.empty:
        return pd.DataFrame()
    # A round advertises up to frames * GCS_MAX_ELEMENTS ids of the pending
    # ground; covered is capped at what was actually outstanding.
    d["advertised"] = (d.frames * GCS_MAX_ELEMENTS).clip(upper=d.pending)
    # Two different questions, and only the first says whether the exchange is
    # healthy. `covered` is what share of the ground outstanding at the round's
    # start the round actually named: 1.0 means the node kept up with its own
    # traffic, below that means it fell behind and the rest was never asked
    # for. `reach` is the share of the whole seen-set — small even for a
    # perfectly healthy node, since a caught-up node has little left to name.
    d["covered"] = (d.advertised / d.pending.where(d.pending > 0)).round(3)
    d["reach"] = (d.advertised / d.seenTotal.where(d.seenTotal > 0)).round(3)
    g = d.groupby(["_device", "transport"], as_index=False).agg(
        rounds=("frames", "size"), frames=("frames", "sum"),
        frames_median=("frames", "median"),
        pending_median=("pending", "median"),
        seen_median=("seenTotal", "median"),
        covered_median=("covered", "median"), covered_min=("covered", "min"),
        behind_rounds=("covered", lambda c: int((c < 1).sum())),
        reach_median=("reach", "median"))
    return g.sort_values(["_device", "transport"])


#: Ids one GCS filter frame names — (maxPayloadBytes * 8) // (p + 2) in
#: lib/src/mesh/gcs_filter.dart. Kept here so the reach table can be read
#: without the app source; a change there must be mirrored.
GCS_MAX_ELEMENTS = 106


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
            rec["_upload"] = upload_id
            rec["_device"] = device_id
            rec["_type"] = rtype
            rec["_t"] = t
            out.append(rec)
    conn.close()
    if not out and (exp or types):
        print(f"  no records matched (exp={exp}, types={types})",
              file=sys.stderr)
    return _purge_excluded(_newest_upload_only(pd.DataFrame(out)))


# Identities whose records are dropped from every analysis. The line test
# scans open (the pair are not friends, so there is no friend filter), which
# means ANY phone running the app is discovered, dialed, handshaked and even
# sent to the moment it is identified. The operator's personal iPhone did
# exactly that during line-200 d=20 t3: 12 s of session, 36 test messages
# addressed to it (the whole 2036-sent anomaly — arrival at d=20 is 2000/2000
# once they are removed), and 105 writeFailed drops against its dead path
# afterwards. The purge is analysis-side only; the raw db is never edited.
EXCLUDED_PEERS = ("3e3d14fd9",)


def _purge_excluded(df: pd.DataFrame) -> pd.DataFrame:
    """Drop every record tied to an excluded identity: any record naming it
    as `peer`/`fromPeer`, and any record on a path whose MAC that identity
    was ever identified on (both GATT legs share the MAC, and rssi/drop/link
    records on those paths carry no peer field of their own)."""
    if df.empty:
        return df
    masks = []
    for col in ("peer", "fromPeer"):
        if col in df.columns:
            masks.append(df[col].astype(str).str.startswith(EXCLUDED_PEERS))
    macs: set[str] = set()
    if masks and "path" in df.columns and "event" in df.columns:
        named = df[np.logical_or.reduce(masks)]
        ident = named[(named._type == "link") & (named.event == "identified")]
        for p in ident.path.dropna():
            if isinstance(p, str) and ":" in p:
                macs.add(p.split(":", 1)[1])
    if macs and "path" in df.columns:
        masks.append(df.path.apply(
            lambda p: isinstance(p, str) and any(p.endswith(m) for m in macs)))
    if not masks:
        return df
    drop = np.logical_or.reduce(masks)
    n = int(drop.sum())
    if n:
        print(f"  purged {n} records tied to excluded identities "
              f"{EXCLUDED_PEERS}", file=sys.stderr)
    return df[~drop]


def _newest_upload_only(df: pd.DataFrame) -> pd.DataFrame:
    """Keep one generation of every uploaded file.

    An upload sends the WHOLE file, so uploading the same file twice puts
    every record in the database twice under a second `upload_id`. Nothing
    downstream notices: delivery is keyed on messageId and survives, while
    every link-stage count silently doubles.

    The id is `exp_<name>.jsonl:<filelen>[:<chunk>]`, and a later upload of a
    longer file is a superset of the earlier one, so the largest length is the
    complete generation and the rest are prefixes of it. Dropping whole
    generations is what makes this safe: two identical records inside ONE file
    are a real pair of events -- two fragments refused on the same path in the
    same millisecond -- and deduplicating on their contents would delete one of
    them.
    """
    if df.empty or "_upload" not in df.columns:
        return df
    gen = df["_upload"].str.extract(r"^(?P<file>[^:]+):(?P<blen>\d+)")
    if gen["file"].isna().all():
        return df
    live = pd.Series(True, index=df.index)
    # Keyed on (file, DEVICE), not on the file name alone. Every phone in a
    # run writes the same `exp_<name>.jsonl`, and their files differ in
    # length, so grouping by name alone sees one run's two sides as two
    # generations of one file and reports a spurious "two distinct runs".
    gen = gen.assign(_dev=df["_device"] if "_device" in df.columns else "")
    for (fname, _dev), idx in gen.groupby(["file", "_dev"]).groups.items():
        sub = gen.loc[idx]
        if sub["blen"].nunique() < 2:
            continue
        # Two generations of one filename are either the same run uploaded
        # twice (the later file is a superset of the earlier -- distinct
        # records match the largest generation) or two DIFFERENT runs that
        # happened to reuse the name after the device's files were cleared
        # (distinct records match the total). Only the first is duplication;
        # collapsing the second would silently delete a whole run.
        rows = df.loc[idx]
        distinct = len(rows.drop_duplicates(
            subset=[c for c in ("_device", "_t") if c in rows.columns]
            + (["t"] if "t" in rows.columns else [])))
        biggest = sub["blen"].astype(float).max()
        big_rows = int((sub["blen"].astype(float) == biggest).sum())
        if distinct <= big_rows * 1.05:
            live.loc[idx] = sub["blen"].astype(float).eq(biggest)
            print(f"  re-ingested upload: dropped "
                  f"{int((~live.loc[idx]).sum())} duplicate record(s) from "
                  f"an earlier upload of {fname}", file=sys.stderr)
        else:
            print(f"  NOTE: {fname} holds {sub['blen'].nunique()} distinct "
                  f"runs under one name (files cleared between runs?) -- "
                  f"keeping all; separate them by their markers",
                  file=sys.stderr)
    return df[live].reset_index(drop=True)


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
    """One segment per step marker, in three nested windows: [{d, payloadB,
    direction, label, t0, t1, t0_dwell, t1_dwell, t0_drain, t1_drain, dev}].

    `t0`/`t1` are the RUN: the step marker to this trial's OWN `run-end`.
    Every downstream consumer (steps_table, pair_matrix, the path-loss and
    control-byte figures) filters records into `[t0, t1)` expecting "this
    trial's own activity" -- which `t1` did not previously deliver. It was
    the timestamp of the NEXT step marker instead, correct for every trial
    but the last at a position: that one's "next marker" is the following
    DISTANCE's first trial, which fires only once the operator has walked
    the mover there. Nothing marks the walk, so it was silently charged to
    the trial before it -- measured as a 150 s tail glued onto a 45 s trial,
    for every position, every run. `run-end` is stamped once per trial
    regardless of what happens after it, so anchoring there is a strict
    fix, not a fallback that only sometimes helps.

    `t0_dwell`/`t1_dwell` are the DWELL inside that run: from the radio
    reporting back up (`bt-on`) to the same `run-end`. The reset that opens
    every trial -- buffer clear, radio bounce, ~10 s dark -- happens INSIDE
    the run, before dwell starts; a rate that wants only the traffic-active
    window filters to this instead of `t0`/`t1`. `bt-on` fires once per
    device; the earlier of the two is used, so dwell is the union of both
    radios' active time, not its intersection.

    `t0_drain`/`t1_drain` are the settle window AFTER `run-end`, up to the
    NEXT trial's own step marker: a few tens of milliseconds when the
    runner chains straight into its own reset, the whole walk when the
    mover has to relocate first. This is exactly what `t1` used to measure
    under the wrong name; it is exposed rather than discarded because late
    ACKs can land here, and a caller that wants them can now find them
    without the walk contaminating the run they belong to.

    `run-end`/`bt-on` are matched to a segment by LABEL, through the
    stamping device's own most-recent step marker — never by "whichever
    segment is newest," i.e. never `segs[-1]`. The step marker itself is
    wall-clock scheduled and near-simultaneous on both devices (~50 ms
    apart, measured), but the per-device teardown that follows a trial is
    not: one side's `run-end` can land after the OTHER side has already
    opened the next trial (measured: device A opens `t2` at +45.000s,
    device B's `run-end` for `t1` doesn't arrive until +45.024s). Routing
    through `segs[-1]` in that case attributes a straggling `run-end` for
    the trial just finished to the trial that just started, closing it
    24 ms after it opened. Routing by the device's own current label is
    immune to which device happens to be running behind.

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
    # NOTE: every segment carries "d" -- NaN for a stationary step, never
    # None or absent. Filter with [_distance_segments], not an
    # is-not-None test, which NaN passes.
    label_to_idx: dict[str, int] = {}
    dev_label: dict[str, str] = {}
    for _, m in markers.iterrows():
        # expStart/expStop carry `event`, not `label` — lifecycle, not a step.
        # (A missing field is NaN, which is truthy: test for str, not falsiness.)
        raw = m.get("label")
        label = raw if isinstance(raw, str) else ""
        dev = str(m._device)
        # The runner stamps `end` when the last dwell finishes, BEFORE the
        # settle window. Closing the final segment there keeps per-second
        # rates honest — settle time carries late ACKs, not sends.
        if label in ("end", "aborted") and end_t is None:
            end_t = m._t
        # `run-end`/`bt-on` close windows on the segment THIS DEVICE'S OWN
        # step marker most recently opened. Both are already in
        # CONTROL_MARKERS, so they fall through to the `continue` below
        # exactly as before once handled here.
        if label in ("run-end", "bt-on"):
            idx = label_to_idx.get(dev_label.get(dev))
            if idx is not None:
                seg = segs[idx]
                if label == "run-end" and seg["t1"] is None:
                    seg["t1"] = m._t
                    seg["t1_dwell"] = m._t
                elif label == "bt-on" and seg["t0_dwell"] is None \
                        and seg["t1"] is None:
                    seg["t0_dwell"] = m._t
        if not label or label in CONTROL_MARKERS:
            continue
        # The same label from ANOTHER device is the same step: every phone
        # stamps each step at the shared wall-clock start, so cross-device
        # duplicates need no time tolerance — device identity decides. The
        # same label from the SAME device is the plan repeating a label, a
        # new step. (This replaces a 90 s window that would have merged any
        # same-device repeat closer than 90 s and split cross-device stamps
        # skewed wider — both fictions.) Either way this device now
        # considers itself at `label`, so its later run-end/bt-on route here.
        if segs and segs[-1]["label"] == label \
                and str(m._device) != segs[-1]["dev"]:
            dev_label[dev] = label
            continue
        if segs:
            segs[-1]["t0_drain"] = (segs[-1]["t1"]
                                    if segs[-1]["t1"] is not None
                                    else segs[-1]["t0"])
            segs[-1]["t1_drain"] = m._t
            # No `run-end` ever arrived for that trial (aborted mid-dwell):
            # fall back to the drain boundary, which is what every segment
            # used unconditionally before `run-end` was read at all.
            if segs[-1]["t1"] is None:
                segs[-1]["t1"] = m._t
                segs[-1]["t1_dwell"] = m._t
        pos = MARKER_POS_RE.search(label)
        payload = MARKER_PAYLOAD_RE.search(label)
        lanes = MARKER_LANES_RE.search(label)
        leg = MARKER_LEG_RE.search(label)
        radius = MARKER_RADIUS_RE.search(label)
        direction = (
            "approach"
            if "approach" in label.lower()
            else "retreat" if "retreat" in label.lower() else ""
        )
        segs.append({"d": float(pos.group(1)) if pos else float("nan"),
                     "payloadB": int(payload.group(1)) if payload else None,
                     "lanes": int(lanes.group(1)) if lanes else None,
                     "leg": leg.group(1) if leg else None,
                     # None (not NaN) when absent, so `is not None` filters
                     # correctly -- the trap `d` fell into, where every
                     # non-line run keyed its buckets on NaN.
                     "r": int(radius.group(1)) if radius else None,
                     "direction": direction, "dev": str(m._device),
                     "label": label, "t0": m._t, "t1": None,
                     "t0_dwell": None, "t1_dwell": None,
                     "t0_drain": None, "t1_drain": None})
        label_to_idx[label] = len(segs) - 1
        dev_label[dev] = label
    end = end_t if end_t is not None else df._t.dropna().max()
    if segs and segs[-1]["t1"] is None:
        segs[-1]["t1"] = end
        segs[-1]["t1_dwell"] = end
    if segs and segs[-1]["t1_drain"] is None:
        segs[-1]["t0_drain"] = segs[-1]["t1"]
        segs[-1]["t1_drain"] = end
    return segs


def _distance_segments(df: pd.DataFrame) -> list[dict]:
    """Segments walked to a `d=` position -- the only ones a per-distance
    grouping may consume.

    [marker_segments] sets `d` on EVERY segment: the walked position where
    the label carries one, `float("nan")` for a stationary step (the
    clique's `N=` labels, a ring run's `r=`). `nan is not None`, so an
    is-not-None filter admits every segment -- and worse, distinct NaN
    objects hash as distinct dict keys, so a stationary run's sightings
    scatter across one bogus key PER SEGMENT in any dict grouped by `d`.
    """
    return [s for s in marker_segments(df) if not math.isnan(s["d"])]


def steps_table(df: pd.DataFrame, segs: list[dict],
                latency: pd.DataFrame) -> pd.DataFrame:
    rssi = df[df._type == "rssi"]
    link = df[df._type == "link"]
    # `bt-on` is stamped at the transport-usability transition itself, which
    # is what the establishment ladder has to be measured from.
    mk = df[df._type == "marker"]
    bt_on = (mk[_col(mk, "label") == "bt-on"].sort_values("_t")
             if len(mk) else mk)
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
        # arm exists to produce, since a payload above one packet pays the
        # full 106-byte overhead again per fragment. Wire records are drained on a
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
            # The send-path verdict, named for what it is: a sent record with
            # aired:true had its DIRECT WRITE ACCEPTED by the transport at
            # dispatch; aired:false entered the run buffered — custody-only
            # until a sync exchange conveys it. "Aired" overpromised: a
            # buffered message usually reaches the air later as a conveyance,
            # which this column deliberately does not count (the trace field
            # keeps its wire name `aired` so old runs stay readable).
            if "aired" in seg_msgs.columns:
                aired_n = int(seg_msgs["aired"].fillna(False).astype(bool).sum())
            else:
                aired_n = sent_n
            row["msg_direct_accepted"] = aired_n
            row["msg_buffered"] = sent_n - aired_n
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
            # Offered basis: of what the app asked to send. The system-level
            # delivery verdict — a message the send path could only queue and
            # never air is a delivery failure like any other.
            row["arrival_rate"] = round(arrived_n / sent_n, 3)
            # Direct-write basis: of what the send path placed on the air
            # itself. Above 1.0 means conveyances delivered buffered sends —
            # store-carry-forward outrunning the direct path.
            row["arrival_rate_direct"] = (round(arrived_n / aired_n, 3)
                                          if aired_n else None)
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
            sub = in_seg_rssi[_col(in_seg_rssi, "src") == src]
            vals = _valid_rssi(
                sub, seg["t0"],
                settle=(src == "conn"))
            row[f"rssi_{src}_mean"] = round(vals.mean(), 1) if len(vals) else None
            row[f"rssi_{src}_std"] = round(vals.std(), 1) if len(vals) > 1 else None
        # Establishment LATENCY, not just whether the stage happened: seconds
        # to the first time each stage is reached, measured from the RADIO
        # COMING UP rather than from the step marker.
        #
        # The marker opens the segment BEFORE anything touches the radio, so
        # that the dials an establishment is made of fall inside the window
        # that measures it. Everything between the two — the link bounce's
        # dark window, the session purge, the transport rebuild — therefore
        # sits between the marker and the first stage, and measuring from the
        # marker charges every stage for it. On a plan with a 10 s dark
        # window that is a 10 s constant added to every distance, which is
        # larger than the effect a line sweep exists to find.
        #
        # `bt-on` is stamped at the transport-usability transition itself, so
        # the last one at or before a stage is the instant the radio became
        # able to do it. A segment with no bt-on (nothing bounced) falls back
        # to the marker, which is then the same instant anyway.
        in_seg_bton = (bt_on[(bt_on._t >= seg["t0"]) & (bt_on._t < seg["t1"])]
                       if len(bt_on) else bt_on)
        for stage in LINK_STAGES:
            if stage == "drop":
                continue
            hit = in_seg_link[_col(in_seg_link, "event") == stage]
            # Only stages reached once the radio is actually up. A segment
            # opens before anything touches the radio, so the reset itself
            # emits link events into the head of it -- a teardown as the old
            # link drops, a leftover connect from the radio about to go
            # down. Taking the segment's first occurrence lets one of those
            # stand for the trial, and since it precedes every `bt-on` there
            # is no anchor to measure it from: it falls back to the marker
            # and reports the whole dark window as the stage's latency.
            if len(in_seg_bton):
                hit = hit[hit._t >= in_seg_bton._t.min()]
            if not len(hit):
                row[f"t_{stage}_s"] = None
                continue
            at = hit._t.min()
            base = seg["t0"]
            if len(in_seg_bton):
                prior = in_seg_bton[in_seg_bton._t <= at]
                if len(prior):
                    base = max(base, prior._t.max())
            row[f"t_{stage}_s"] = round((at - base) / 1000.0, 2)
            # The marker-relative value stays available: it is the operator's
            # view of "how long after the window opened", which the ladder is
            # not.
            row[f"t_{stage}_from_marker_s"] = round(
                (at - seg["t0"]) / 1000.0, 2)
        for stage in LINK_STAGES:
            row[stage] = int((_col(in_seg_link, "event") == stage).sum())
        rows.append(row)
    return pd.DataFrame(rows)



# The connection-RSSI stream reads 8-11 dB high for this long after a BLE
# restart before converging; measured on a matched stationary pair, where the
# settled value was flat to 0.5 dB. Advertisement samples carry no such
# transient and are never excluded on time.
CONN_RSSI_SETTLE_MS = 15_000


def _valid_rssi(sub: pd.DataFrame, t0: float, *,
                settle: bool) -> pd.Series:
    """RSSI samples fit to aggregate, from one step's slice of one source.

    Two contaminations are removed, both measured rather than assumed:
    sentinel readings (0 / -1, emitted for the first discovery cycles after a
    restart while the peer record has no real sample yet — physically
    impossible as signal), and for the connection stream the post-restart
    settle window, during which every reading is high. Averaging either into
    a per-step mean invents several dB of step-to-step scatter on a link that
    is actually flat.
    """
    if sub.empty:
        return pd.Series(dtype=float)
    if settle and "_t" in sub.columns:
        sub = sub[sub._t >= t0 + CONN_RSSI_SETTLE_MS]
    vals = pd.to_numeric(_col(sub, "rssi"), errors="coerce").dropna()
    return vals[vals <= -10]


def adv_sightings_by_distance(df: pd.DataFrame,
                             min_per_distance: int = 20
                             ) -> dict[float, list[float]]:
    """Every advertisement RSSI sighting, grouped by the distance its step
    was walked to.

    Advertisement RSSI only. Connection RSSI is measured per leg and reads
    high for seconds after a bounce, so pooling it across legs mixes two
    quantities; the beacon is one radio measuring one transmitter.
    """
    if df.empty:
        return {}
    rssi = df[df._type == "rssi"]
    if rssi.empty:
        return {}
    adv = rssi[_col(rssi, "src") == "adv"]
    segs = _distance_segments(df)
    if adv.empty or not segs:
        return {}
    byd: dict[float, list[float]] = defaultdict(list)
    for seg in segs:
        v = pd.to_numeric(
            _col(adv[(adv._t >= seg["t0"]) & (adv._t < seg["t1"])], "rssi"),
            errors="coerce").dropna()
        if len(v):
            byd[float(seg["d"])].extend(v.tolist())
    return {d: v for d, v in byd.items() if len(v) >= min_per_distance}


def adv_pathloss_fit(byd: dict[float, list[float]]
                     ) -> tuple[float, float, float, int] | None:
    """`(A, n, R^2, residual_std, n_sightings)` of RSSI = A - 10 n
    log10(d), fitted over
    EVERY sighting rather than over one summary point per distance.

    The sightings are the measurement; a per-distance median or mean is a
    reduction of them. Fitting the reduction throws away the within-distance
    spread, which is most of what a radio channel does, and reports an
    agreement between ten points as though it were an agreement between tens
    of thousands -- a far tighter fit than the data supports. Distances are
    unequally sampled, so the fit is weighted by sighting count implicitly,
    which is the honest weighting: a distance the pair could barely hear
    contributes the few readings it actually produced.
    """
    # A run with no geometry reaches here with degenerate distances -- a
    # clique sweep has one `d` per step and it is NaN -- and log10 of that
    # feeds polyfit a column of NaN, which does not raise a clean error but
    # fails deep inside LAPACK and takes the whole invocation down with it.
    # Everything after this point in main() was then silently skipped, which
    # is how a clique run wrote its tables and no thesis figure.
    ds = sorted(d for d in byd
                if d is not None and np.isfinite(d) and d > 0 and byd[d])
    if len(ds) < 3:
        return None
    x = np.concatenate([np.full(len(byd[d]), np.log10(d)) for d in ds])
    y = np.concatenate([np.asarray(byd[d], dtype=float) for d in ds])
    ok = np.isfinite(x) & np.isfinite(y)
    x, y = x[ok], y[ok]
    if len(y) < 3 or len(np.unique(x)) < 3:
        return None
    slope, inter = np.polyfit(x, y, 1)
    r = float(np.corrcoef(x, y)[0, 1])
    resid = y - (inter + slope * x)
    return (float(inter), float(-slope / 10.0), r * r,
            float(resid.std()), len(y))


def pathloss_fit(byd: dict[float, list[float]]) -> str | None:
    """The log-distance fit as the text block `pathloss.txt` carries, over
    every advertisement sighting -- the same numbers the figure draws."""
    fit = adv_pathloss_fit(byd)
    if fit is None:
        return None
    a, n, r2, resid_std, n_sight = fit
    return (
        f"log-distance fit over {n_sight} advertisement sighting(s) "
        f"at {len(byd)} distance(s):\n"
        f"  RSSI(d) = {a:.1f} - 10 * {n:.2f} * log10(d)\n"
        f"  path-loss exponent n = {n:.2f}, RSSI@1m = {a:.1f} dBm, "
        f"R^2 = {r2:.2f}, residual std = {resid_std:.1f} dB\n"
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
            # Printed beside every stage so a per-leg count is never read
            # against a per-peer one without noticing.
            "counts": LINK_STAGE_COUNTS[stage],
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
    """Loss counts by site and reason, per device, and what the retry saved.

    One uniform record type covers every drop point (TTL death, rate-limit
    refusal, decrypt failure, malformed input, reassembly abandonment,
    transport send failures, handshake deaths...), so packet loss is countable
    without per-site parsing.

    A BLE send site needs reading with care. A pair holds two GATT legs, and a
    write refused on the first is retried on the other; only a refusal by BOTH
    loses the packet. So a row at a plain site counts REFUSALS, not losses:
    the genuine losses are the same reason at `<site>:otherLeg`, and the
    rescues appear as their own row, "(carried by the pair's other leg)".
    Reading the plain count as loss overstates it by whatever the retry saved
    (measured on a 7-phone desk run: 133 first-leg refusals at bleSend, 50
    carried by the other leg, 66 refused by both).
    """
    drops = df[df._type == "drop"]
    if drops.empty:
        return pd.DataFrame()
    out = (drops.groupby(["_device", "where", "reason"]).size()
           .reset_index(name="count"))
    # A retry record names the site AND the reason the first leg gave, so a
    # rescue can be matched to the refusal it cancels. Where it can, `lost` is
    # the refusals the other leg did not carry; where the record predates the
    # reason field it stays blank rather than guessing, because spreading a
    # site's rescues across its reasons invents an attribution the trace does
    # not hold (and, done arithmetically, produced negative losses).
    out["carried_by_retry"] = 0
    if "_type" in df.columns:
        r = df[df._type == "retry"]
        if not r.empty and "where" in r.columns:
            if "reason" in r.columns and r["reason"].notna().any():
                keyed = (r.dropna(subset=["reason"])
                         .groupby(["_device", "where", "reason"]).size()
                         .to_dict())
                out["carried_by_retry"] = [
                    keyed.get((d, w, rs), 0)
                    for d, w, rs in zip(out["_device"], out["where"],
                                        out["reason"])
                ]
            else:
                rows = (r.groupby(["_device", "where"]).size()
                        .reset_index(name="count"))
                rows["reason"] = "(carried by the other leg, reason not traced)"
                rows["carried_by_retry"] = 0
                out = pd.concat([out, rows], ignore_index=True)
    out["lost"] = out["count"] - out["carried_by_retry"]
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
    s_cols = ["messageId", "_device", "_t", "payloadSize"]
    for extra in ("aired", "peer"):
        if extra in sent.columns:
            s_cols.append(extra)
    s = sent[s_cols].rename(columns={"_t": "sentAt", "_device": "sender"})
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
    r = recv[["messageId", "_t", "_device"]].rename(
        columns={"_t": "receivedAt", "_device": "receiver"})
    joined = joined.merge(
        r.drop_duplicates("messageId"), on="messageId", how="left")
    # TWO different latencies, deliberately kept apart:
    #   latencyMs    — WIRE RTT: the sealed packet hitting the transport until
    #                  its ACK came back. Both stamps are trace records on the
    #                  sender, one clock, no queueing in between.
    #   appLatencyMs — the app's own view, from when the message was CREATED:
    #                  sealing and the transmit queue are inside it. No session
    #                  wait rides here — the runner skips a target whose
    #                  session is not up, so such a message is never created.
    # The gap between them is the send path's own cost.
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
        relays = win[(win._type == "relay") & (ev != "dup")]
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


# The control plane as the wire ledger names it. ANNOUNCE and the handshake
# travel in the clear; the buffer-reconciliation filter is sealed like any
# other content, so it is only separable on the SENDING side, which is why
# these are all tx keys. `secure:ack` is here because an end-to-end ACK is
# what makes a link usable, and its bytes are as much a cost of having a
# working link as the handshake's are.
_CONTROL_PLANE_TX = ["announce", "handshake", "secure:sync", "secure:ack"]


# `run-end` is the dwell's own end. The reset markers are the fallback for a
# recording made before the runner stamped it, where the first reset after a
# step marker is the closest thing to the same instant.
DWELL_END_MARKERS = ("run-end", "custody-reset", "links-reset",
                     "sessions-reset")
RESET_MARKERS = set(DWELL_END_MARKERS[1:])


def _dwell_from_resets(line: pd.DataFrame, df: pd.DataFrame) -> float:
    """The declared dwell: step marker -> the marker that ends its run.

    A step's segment runs to the next step marker, so it carries the reset that
    follows the dwell and is the wrong span to read the dwell from. NaN when
    the run carries no end marker at all, which is the caller's signal to fall
    back to the span.
    """
    if df is None or "_type" not in df.columns:
        return float("nan")
    mk = df[df["_type"] == "marker"]
    if mk.empty or "label" not in mk.columns:
        return float("nan")
    # Prefer the explicit run end; fall back to the reset that follows it.
    for label_set in (("run-end",), RESET_MARKERS):
        resets = mk[mk["label"].isin(label_set)]
        if not resets.empty:
            break
    if resets.empty:
        return float("nan")
    rt = pd.to_numeric(resets["_t"], errors="coerce").dropna().sort_values()
    dwells = []
    for _, seg in line.iterrows():
        t0 = pd.to_numeric(seg["t0"], errors="coerce")
        t1 = pd.to_numeric(seg["t1"], errors="coerce")
        if pd.isna(t0) or pd.isna(t1):
            continue
        inside = rt[(rt > t0) & (rt <= t1)]
        if not inside.empty:
            dwells.append((float(inside.iloc[0]) - float(t0)) / 1000.0)
    if not dwells:
        return float("nan")
    # Median, not min: one step whose reset was stamped early should not set
    # the dwell for the whole run.
    return round(float(np.median(dwells)), 1)


def _establish_bytes(line: pd.DataFrame, wire: pd.DataFrame,
                     df: pd.DataFrame) -> pd.DataFrame:
    """Control-plane bytes per trial, per distance.

    ANNOUNCE and handshake bytes are summed over BOTH devices inside each
    step's marker span and divided by the distance's trial count — the cost of
    one trial to the pair, which is what the establishment argument is about.

    `dwell_s` is the plan's declared dwell, measured as the step marker to the
    first reset marker inside its span. A step's span is NOT the dwell: it runs
    to the next step marker, so it carries the reset that follows the dwell,
    and every step is bracketed by one — including the last, whose trailing
    reset lands before `end`. Taking the shortest span instead would report the
    dwell plus a reset for every step in the run.
    """
    spans = (pd.to_numeric(line["t1"], errors="coerce")
             - pd.to_numeric(line["t0"], errors="coerce")) / 1000.0
    dwell_s = _dwell_from_resets(line, df)
    if dwell_s != dwell_s:  # no reset markers: the span IS the dwell
        dwell_s = (round(float(spans.min()), 1)
                   if spans.notna().any() else float("nan"))
    # Devices that ever advertised, which for a two-phone line sweep is both.
    n_adv = int(df["_device"].nunique()) if "_device" in df.columns else 0
    os_adv = dwell_s * n_adv * ADV_CHANNELS * ADV_PDU_B / ADV_INTERVAL_S

    rows = []
    for d, g in line.groupby("d"):
        totals = {k: 0.0 for k in _CONTROL_PLANE_TX}
        for _, s in g.iterrows():
            in_step = wire[(wire._t >= s["t0"]) & (wire._t < s["t1"])]
            for _, w in in_step.iterrows():
                tx = _dict(w.get("txBytes"))
                for key in totals:
                    totals[key] += float(tx.get(key, 0))
        n = len(g)
        row = {
            "d": float(d),
            "os_adv": os_adv,
            **{k.replace(":", "_"): totals[k] / n for k in _CONTROL_PLANE_TX},
            "dwell_s": dwell_s,
            "usable_n": int((pd.to_numeric(g.get("usable"), errors="coerce")
                             .fillna(0) > 0).sum()),
            "trials": n,
        }
        # What the pair spends on the air per trial to have a link at all,
        # which is the figure the establishment argument quotes.
        row["control_total"] = sum(totals[k] / n for k in _CONTROL_PLANE_TX)
        rows.append(row)
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
    _plot_lineexp(line, adv_sightings_by_distance(df),
                  out / "fieldday_lineexp.png")
    _plot_rssi_distance(df, out / "fieldday_rssi_distance.png")


def _plot_rssi_distance(df: pd.DataFrame, out: Path) -> None:
    """RSSI against distance, one box per position, over the RAW sightings.

    The per-step means the other figures use answer "how strong was this
    trial"; a path-loss claim needs the SPREAD, because the exponent is read
    off medians and the residual is what says whether the fit means
    anything. Boxes over every sighting show both, and they show the two
    things a mean hides: the long weak tail where a body crossed the path,
    and the floor the receiver stops reporting below.

    Advertisement RSSI only. Connection RSSI is measured per leg and reads
    high for seconds after a bounce, so pooling it across legs mixes two
    different quantities; the beacon is one radio measuring one transmitter.
    """
    if df.empty:
        return
    rssi = df[df._type == "rssi"]
    if rssi.empty:
        return
    adv = rssi[_col(rssi, "src") == "adv"]
    if adv.empty:
        return
    segs = _distance_segments(df)
    if not segs:
        return
    by_d: dict[float, list[float]] = {}
    for seg in segs:
        vals = adv[(adv._t >= seg["t0"]) & (adv._t < seg["t1"])]
        v = pd.to_numeric(_col(vals, "rssi"), errors="coerce").dropna()
        if len(v):
            by_d.setdefault(float(seg["d"]), []).extend(v.tolist())
    by_d = {d: v for d, v in by_d.items() if len(v) >= 20}
    if len(by_d) < 2:
        return
    ds = sorted(by_d)
    fig, ax = plt.subplots(figsize=(11.5, 6.4))
    _field_axes(fig, [ax])
    bp = ax.boxplot([by_d[d] for d in ds], positions=range(len(ds)),
                    widths=0.55, showfliers=False, patch_artist=True,
                    medianprops=dict(color=_INK, linewidth=1.8),
                    whiskerprops=dict(color=_INK_MUTED),
                    capprops=dict(color=_INK_MUTED),
                    boxprops=dict(edgecolor=_INK_MUTED, linewidth=1.0))
    for patch in bp["boxes"]:
        patch.set_facecolor(_C_SESSION)
        patch.set_alpha(0.45)
    inter, n_exp, r2, _, _ = adv_pathloss_fit(by_d)
    grid = np.linspace(0, len(ds) - 1, 200)
    dgrid = np.interp(grid, range(len(ds)), ds)
    ax.plot(grid, inter - 10 * n_exp * np.log10(dgrid), "--",
            color=_C_USABLE, linewidth=2.0, zorder=4,
            label=(f"log-distance fit: n = {n_exp:.2f}, "
                   f"$R^2$ = {r2:.2f}"))
    ax.set_xticks(range(len(ds)))
    ax.set_xticklabels([f"{int(d)}" for d in ds])
    ax.set_xlabel("Distance (m)", fontsize=12, color=_INK_2, labelpad=9)
    ax.set_ylabel("Advertisement RSSI (dBm)", fontsize=12, color=_INK_2,
                  labelpad=9)
    ax.set_title("Signal strength against distance", fontsize=15, color=_INK,
                 loc="left", pad=34)
    for i, d in enumerate(ds):
        ax.annotate(f"n={len(by_d[d])}", (i, ax.get_ylim()[1]),
                    textcoords="offset points", xytext=(0, -12),
                    ha="center", fontsize=9, color=_INK_MUTED)
    leg = ax.legend(loc="lower left", frameon=False, fontsize=11.5)
    for txt in leg.get_texts():
        txt.set_color(_INK_2)
    fig.subplots_adjust(left=0.085, right=0.98, top=0.88, bottom=0.13)
    fig.savefig(out, dpi=160, facecolor=_SURFACE)
    plt.close(fig)


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
    """What one establishment trial costs the pair on the air, in kB, split by
    what the bytes are for. The bar shrinking with distance is not a saving —
    it is trials that never got far enough to spend the bytes."""
    if b is None or b.empty:
        return
    fig, ax = plt.subplots(figsize=(11.5, 6.4))
    _field_axes(fig, [ax])
    width = (float(b["d"].diff().dropna().min()) * 0.55
             if len(b) > 1 else 0.8)
    layers = [
        ("announce", "ANNOUNCE", _C_SESSION),
        ("handshake", "Noise handshake", _C_USABLE),
        ("secure_sync", "Buffer sync filter", _C_DELIVERY),
        # A neutral, not a fourth hue: the ACK layer is a thin residual and
        # inventing a categorical colour for it would spend a slot the
        # validated palette has not cleared for adjacency here.
        ("secure_ack", "End-to-end ACK", _INK_MUTED),
    ]
    bottom = pd.Series(0.0, index=b.index)
    for col, label, colour in layers:
        if col not in b.columns:
            continue
        vals = b[col] / 1000.0
        if not (vals > 0).any():
            continue
        ax.bar(b["d"], vals, width=width, bottom=bottom, color=colour,
               label=label, zorder=3)
        bottom = bottom + vals
    ax.set_xlabel("Distance (m)", fontsize=12, color=_INK_2, labelpad=9)
    ax.set_ylabel("kB per trial (both devices)", fontsize=12, color=_INK_2,
                  labelpad=9)
    ax.set_xticks(b["d"].tolist())
    _usable_header(ax, b["d"].tolist(),
                   [int(u) for u in b["usable_n"]],
                   [int(n) for n in b["trials"]])
    ax.set_title("Control plane costs", fontsize=15, color=_INK,
                 loc="left", pad=34)
    leg = ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.12), ncol=4,
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


def _plot_lineexp(line: pd.DataFrame, sightings: dict[float, list[float]],
                  out: Path) -> None:
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
        fit = adv_pathloss_fit(sightings)
        if fit is not None:
            a, n, _, _, _ = fit
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


def pair_matrix(latency: pd.DataFrame, segs: list[dict]) -> pd.DataFrame:
    """Per-step, per-directed-pair delivery ledger for clique runs.

    One row per (step label, sender device, recipient): sent / aired /
    queued / arrived / acked counts plus wire-RTT percentiles, attributed
    by the SEND step (sentAt inside the segment), the same rule as
    steps_table. `arrived` is the recv-or-ACK union; `to` is the recipient
    pubkey prefix from the sent record, so the matrix needs no device
    mapping and covers any clique size."""
    if latency.empty or "peer" not in latency.columns:
        return pd.DataFrame()
    rows = []
    for seg in segs:
        m = latency[(latency.sentAt >= seg["t0"]) &
                    (latency.sentAt < seg["t1"])]
        if m.empty:
            continue
        peer8 = m["peer"].astype(str).str[:8]
        for (snd, dst), g in m.groupby([m.sender, peer8]):
            acked = g.latencyMs.notna()
            arrived = g.receivedAt.notna() | acked
            aired = (g["aired"].fillna(False).astype(bool)
                     if "aired" in g.columns
                     else pd.Series(True, index=g.index))
            lat = g.latencyMs.dropna()
            rows.append({
                "label": seg.get("label", ""),
                "sender": short(snd), "to": dst,
                "sent": len(g), "aired": int(aired.sum()),
                "queued": int((~aired).sum()),
                "arrived": int(arrived.sum()), "acked": int(acked.sum()),
                "ack_p50_ms": round(lat.median()) if len(lat) else None,
                "ack_p90_ms": round(lat.quantile(0.9)) if len(lat) else None,
            })
    return pd.DataFrame(rows)


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
                     "arrival_pct": 100.0 * float(arr),
                     "aired_n": r.get("msg_direct_accepted"),
                     "queued_n": r.get("msg_buffered")})
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
    if (markers.empty or "maxParallel" not in markers.columns
            or "popN" not in markers.columns):
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
        radio_up: dict = {}
        if cells is not None:
            dc = cells[cells._device == dev]
            for _, c in dc.iterrows():
                lbl = c.get("step")
                if isinstance(lbl, str):
                    recorded[lbl] = int(_num(c.get("established"), 0))
                    radio_up[lbl] = c.get("radioUp")
        for i, (_, mk) in enumerate(dm.iterrows()):
            m = mk.get("maxParallel")
            pop = mk.get("popN")
            # A cell needs BOTH variables on the same marker. `popN` with no
            # `maxParallel` is the converge step just below; `maxParallel`
            # with no `popN` is a step that caps dial parallelism for a
            # reason that has nothing to do with the grid — advertisementCapture
            # sets `maxParallelDials: 0` purely to suppress dialing while
            # measuring raw ADV capture, with no population to report.
            # Without this check that step's markers still carry
            # `maxParallel`, so this table would treat a plain suppression
            # run as a degenerate (pop_n=0) dial-grid cell.
            if (m is None or (isinstance(m, float) and math.isnan(m))
                    or pop is None
                    or (isinstance(pop, float) and math.isnan(pop))):
                continue
            t0 = mk._t
            t1 = marker_ts[i + 1] if i + 1 < len(marker_ts) else math.inf
            label = mk.get("label", "")
            cell = {
                "device": dev,
                "pop_n": int(pop),
                "m": int(m),
                "rep": int(_num(mk.get("rep"), 1)),
                "step": label if isinstance(label, str) else "",
                "recorded": recorded.get(label),
                # False => the transport was not up for this cell, so the cell is
                # not a measurement and must be dropped, never averaged as 0.
                "radio_up": radio_up.get(label),
            }
            in_win = (dl._t >= t0) & (dl._t < t1)
            # The establishment is the LINK coming up, not `ready`. Keying on
            # "connected" (= BlePathState.ready) additionally required a
            # verified ANNOUNCE to have identified the path, so a link that
            # demonstrably established was counted as a failed dial whenever
            # announce traffic was absent. The dial context (inFlight,
            # peripheralLinks, totalLinks) rides these records too.
            est = dl[in_win & (ev == "gattConnected") & (role == "central")]
            cell["established"] = len(est)
            if est.empty:
                rows.append({**cell, "conn_idx": 0, "ms_to_establish": None,
                             "in_flight": None, "peripheral_links": None,
                             "total_links": None, "ms_to_identified": None,
                             "ms_to_session": None, "ms_to_converged": None,
                             "mtu_establish": None, "mtu_identified": None})
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
                # Identity is its OWN stage: the link can come up and never be
                # identified (no ANNOUNCE), which is exactly the case that used
                # to erase the establishment entirely. Take the FIRST stamp per
                # path — onBlePeerIdentified fires on every verified announce,
                # so later ones are re-confirmations, not the transition.
                idh = dl[in_win & (path == target) & (ev == "identified")
                         & (dl._t >= t_usable)]
                ms_ident = None if idh.empty else float(idh._t.iloc[0] - t0)
                # The ATT MTU at each stage. A link that is still at the
                # 23-byte default when it comes up cannot carry an ANNOUNCE
                # (~182 B) or a Noise handshake (86/113 B), so it reports
                # ready and then refuses every write that would identify the
                # peer. Comparing the two columns dates the negotiation:
                # equal and low means it never happened, low then high means
                # it landed between the link and the identity.
                mtu_est = _num(e.get("mtu"), None)
                mtu_ident = (None if idh.empty
                             else _num(idh.iloc[0].get("mtu"), None))
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
                    "ms_to_identified": ms_ident,
                    "ms_to_session": ms_sess,
                    "ms_to_converged": ms_conv,
                    "mtu_establish": mtu_est,
                    "mtu_identified": mtu_ident,
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
    ap.add_argument("--thesis-figs", default=None, metavar="DIR",
                    help="also write the thesis line-sweep figures (PDF, "
                         "paper styling) into DIR")
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
        reach = sync_reach(edf)
        if not reach.empty:
            reach.to_csv(out / "sync_reach.csv", index=False)
            with (out / "summary.txt").open("a") as fh:
                fh.write("\nSync filter reach — share of its own seen-set a "
                         "node advertised per round\n" + "-" * 60 + "\n")
                fh.write(reach.to_string(index=False) + "\n")
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
            pairs = pair_matrix(latency, segs)
            if not pairs.empty:
                pairs.to_csv(out / "pair_matrix.csv", index=False)
            est = establishment_table(steps)
            if not est.empty:
                est.to_csv(out / "establishment.csv", index=False)
            ladder = ladder_table(steps)
            if not ladder.empty:
                ladder.to_csv(out / "ladder.csv", index=False)
            pw = power_ladder(edf, segs, device_roles(edf))
            if not pw.empty:
                pw.to_csv(out / "power_ladder.csv", index=False)
            fit = pathloss_fit(adv_sightings_by_distance(edf))
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
            if args.thesis_figs:
                pm_path = out / "pair_matrix.csv"
                pm = (pd.read_csv(pm_path) if pm_path.exists()
                      else pd.DataFrame())
                plot_thesis_line_figures(edf, steps, pm,
                                         Path(args.thesis_figs))
                plot_thesis_clique_figures(edf, steps, pm,
                                           Path(args.thesis_figs))
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



# ---------------------------------------------------------------- thesis figs
#
# The field-day PNGs above are for reading a run; these are the same
# measurements typeset for the thesis --- vector, serif-neutral, no dark
# surface, sized for a 0.9\linewidth figure. They are separate rather than
# restyled in place because a screen figure and a page figure want different
# things: the screen one carries device series and annotations, the page one
# carries one statement and its uncertainty.
_TH = {"font.size": 9, "axes.spines.top": False, "axes.spines.right": False,
       "figure.dpi": 200, "savefig.bbox": "tight"}
_TH_C1, _TH_C2, _TH_C3 = "#2f6b57", "#b0763a", "#7a3b5e"

# One margin set for every two-up panel (the establishment and stages
# pairs): identical margins + full-canvas save is what makes the two PDFs
# the same physical size, so LaTeX scales them equally. The left panel's
# y furniture lives inside the shared left margin; the right panel leaves
# that strip empty rather than being cropped narrower and upscaled.
_TH_PAIR_MARGINS = dict(left=.19, right=.97, bottom=.16, top=.96)


def _clique_sent_ids(msg: pd.DataFrame, seg: dict) -> set:
    """Message ids SENT inside one trial's window.

    THE windowing convention for every per-trial delivery statistic: window
    the SEND, never the receive. A message sent late in a trial can arrive
    legitimately after the window closes -- conveyed deliveries routinely
    take seconds to tens of seconds -- so filtering the `recv` side by the
    same window silently discards exactly the slowest (and most
    interesting) deliveries and undercounts arrival. Measured cost of
    getting this wrong: 68.9% vs 91.5% arrival at N=3, the error growing
    with how much conveyance a cell does.
    """
    a = seg["t0_dwell"] if seg["t0_dwell"] is not None else seg["t0"]
    bd = seg["t1_drain"] if seg.get("t1_drain") is not None else seg["t1"]
    return set(msg[(msg._t >= a) & (msg._t < bd)
                   & (msg.dir == "sent")].messageId.dropna())


def _clique_active_pairs(msg: pd.DataFrame, seg: dict) -> int:
    """Distinct ORDERED (sender, recipient) pairs that actually sent in one
    trial -- the contention the medium really saw, not the nominal N(N-1).

    The clique does not reset links between runs and does not separate link
    formation from sending, so a pair that never formed a link contributes
    nothing and a pair that joined late contributes less. Every ordered pair
    is active at N=2..5, but N=6 ranges 26-30 of 30 and N=7 ranges 36-42 of
    42 across trials, so nominal N overstates the offered load at the top of
    the sweep by up to 14%.
    """
    a = seg["t0_dwell"] if seg["t0_dwell"] is not None else seg["t0"]
    bd = seg["t1_drain"] if seg.get("t1_drain") is not None else seg["t1"]
    w = msg[(msg._t >= a) & (msg._t < bd) & (msg.dir == "sent")]
    return len(set(zip(w._device.astype(str).str[:8],
                       w.peer.astype(str).str[:8])))


def _th_delivery_vs_degree(df: pd.DataFrame, out: Path) -> None:
    """A node's own arrival rate against how many peers it was connected
    to: one row per NODE-TRIAL, x the trial's TIME-WEIGHTED mean count of
    distinct connected peers (links churn constantly, so a midpoint sample
    misrepresents a trial a node spent half-connected), y the share of
    that node's own sent messages that arrived anywhere (send-windowed).

    Links are replayed from EXPERIMENT start, never from the trial window:
    the clique does not reset links between trials, so a window-scoped
    replay misses every link that predates it and reports spurious zeros.
    Peer count, not GATT-leg count, is the degree -- dual-role puts ~2
    legs on every pair, so legs double-count the topology.

    Read the caption's caveat before quoting a trend: on the uncapped
    clique, degree and fleet size are ENTANGLED -- a node cannot hold 5
    peers at N=3, so the left bins are exclusively small-N node-trials and
    the right bins exclusively large-N ones. This figure cannot separate
    "more neighbours" from "more contention"; the ring-radius experiment
    exists to vary degree at fixed N and break exactly this entanglement.
    """
    segs = [s for s in marker_segments(df)
            if re.match(r"N=\d+", s.get("label") or "")]
    if not segs:
        return
    msg = df[df._type == "message"]
    lk = df[df._type == "link"].copy()
    if lk.empty:
        return
    lk["dev8"] = lk._device.astype(str).str[:8]
    lk = lk.sort_values("_t")
    p2p = {}
    for _, r in lk[lk.event == "identified"].iterrows():
        if isinstance(r.get("path"), str) and isinstance(r.get("peer"), str):
            p2p[(r.dev8, r["path"])] = r["peer"][:8]
    steps: dict[str, list] = defaultdict(list)
    live: dict[str, set] = defaultdict(set)
    for _, r in lk.iterrows():
        p = r.get("path")
        if not isinstance(p, str):
            continue
        d = r.dev8
        if r.event in ("connected", "gattConnected"):
            live[d].add(p)
        elif r.event in ("drop", "pruned"):
            live[d].discard(p)
        else:
            continue
        peers = {p2p.get((d, q)) for q in live[d]}
        peers.discard(None)
        steps[d].append((r._t, len(peers)))

    def mean_peers(dev: str, a: float, b: float) -> float:
        st = steps.get(dev)
        if not st:
            return 0.0
        ts = [x[0] for x in st]
        i = bisect.bisect_right(ts, a) - 1
        cur = st[i][1] if i >= 0 else 0
        t0, acc = a, 0.0
        for j in range(max(i + 1, 0), len(st)):
            tt, v = st[j]
            if tt >= b:
                break
            acc += cur * (tt - t0)
            t0, cur = tt, v
        acc += cur * (b - t0)
        return acc / (b - a)

    delivered_all = set(msg[msg.dir == "recv"].messageId.dropna())
    rows = []
    for seg in segs:
        a = seg["t0_dwell"] if seg["t0_dwell"] is not None else seg["t0"]
        bd = seg["t1_drain"] if seg.get("t1_drain") is not None else seg["t1"]
        sw = msg[(msg._t >= a) & (msg._t < bd) & (msg.dir == "sent")].copy()
        sw["dev8"] = sw._device.astype(str).str[:8]
        for dev, g in sw.groupby("dev8"):
            ids = set(g.messageId.dropna())
            if not ids:
                continue
            rows.append(dict(peers=mean_peers(dev, a, bd), sent=len(ids),
                             arrived=len(ids & delivered_all)))
    if not rows:
        return
    t = pd.DataFrame(rows)
    t["rate"] = 100 * t.arrived / t.sent
    t["pbin"] = t.peers.round().astype(int)
    ks = sorted(t.pbin.unique())
    if len(ks) < 3:
        return
    med = [float(t[t.pbin == k].rate.median()) for k in ks]
    q1 = [float(t[t.pbin == k].rate.quantile(.25)) for k in ks]
    q3 = [float(t[t.pbin == k].rate.quantile(.75)) for k in ks]
    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    ax.fill_between(ks, q1, q3, color=_TH_C1, alpha=.18, linewidth=0,
                    label="IQR over node-trials")
    ax.plot(ks, med, "-o", color=_TH_C1, ms=5, lw=1.8, label="median")
    for x, y, k in zip(ks, med, ks):
        ax.annotate(f"{int((t.pbin == k).sum())}", (x, y),
                    textcoords="offset points", xytext=(0, -13),
                    ha="center", fontsize=6.5, color="#666666")
    ax.set_xlabel("connected peers (trial mean)")
    ax.set_ylabel("node's sent messages arrived (%)")
    ax.set_xticks(ks)
    lo = min(q1)
    pad = max((100 - lo) * .08, 1.0)
    ax.set_ylim(lo - pad, 100 + pad)
    ax.grid(axis="y", alpha=.25)
    ax.legend(frameon=False, fontsize=8, loc="lower left")
    _th_save(fig, out / "clique_delivery_vs_degree.pdf")


def _th_delivery_by_active_pairs(df: pd.DataFrame, out: Path) -> None:
    """Arrival and acknowledgement against ACTIVE ordered pairs.

    The same measurement as `clique_delivery.pdf` on a corrected x-axis:
    contention is produced by the pairs that actually exchanged traffic, and
    binning by nominal N pools trials that offered materially different
    loads. At N=2..5 the two axes agree exactly (every pair is active); the
    axes separate only at N=6 and N=7, which is precisely where contention
    is the story -- so the nominal axis compresses the range it most needs
    to resolve.

    One point per DISTINCT active-pair count actually observed (12 of them
    across this sweep, against 6 nominal sizes), each pooling the trials
    that hit it, with those trials scattered so a bin resting on one trial
    is visible as such rather than reading like the pooled ones.
    """
    segs = [s for s in marker_segments(df)
            if re.match(r"N=\d+", s.get("label") or "")]
    if not segs:
        return
    msg = df[df._type == "message"]
    delivered_all = set(msg[msg.dir == "recv"].messageId.dropna())
    acked_all = set(msg[msg.dir == "ackRx"].messageId.dropna())
    rows = []
    for seg in segs:
        sent_ids = _clique_sent_ids(msg, seg)
        pairs = _clique_active_pairs(msg, seg)
        if not sent_ids or not pairs:
            continue
        n = int(re.match(r"N=(\d+)", seg["label"]).group(1))
        rows.append(dict(pairs=pairs, n=n, sent=len(sent_ids),
                         arrived=len(sent_ids & delivered_all),
                         acked=len(sent_ids & acked_all)))
    if not rows:
        return
    t = pd.DataFrame(rows)
    xs = sorted(t.pairs.unique())
    grp = t.groupby("pairs")
    # Ratio of sums: each trial weighs by the traffic it carried.
    arr = (100 * grp.arrived.sum() / grp.sent.sum()).reindex(xs)
    ack = (100 * grp.acked.sum() / grp.sent.sum()).reindex(xs)

    # IQR over the PER-TRIAL rates in each bin. The line is the ratio of
    # sums (traffic-weighted, the quantity claimed); the band is the spread
    # of the individual trials behind it, which is the honest width -- with
    # 12 bins over 60 trials several rest on one or two trials and have no
    # width at all, and that is worth seeing rather than smoothing.
    t = t.assign(arr_pct=100 * t.arrived / t.sent,
                 ack_pct=100 * t.acked / t.sent)
    q = t.groupby("pairs")[["arr_pct", "ack_pct"]].quantile([.25, .75]).unstack()
    fig, ax = plt.subplots(figsize=(6.6, 3.4))
    ax.fill_between(xs, q[("arr_pct", .25)].reindex(xs),
                    q[("arr_pct", .75)].reindex(xs),
                    color=_TH_C1, alpha=.18, linewidth=0)
    ax.fill_between(xs, q[("ack_pct", .25)].reindex(xs),
                    q[("ack_pct", .75)].reindex(xs),
                    color=_TH_C3, alpha=.15, linewidth=0)
    ax.plot(xs, arr.values, "-o", color=_TH_C1, ms=5, lw=1.8, label="arrived")
    ax.plot(xs, ack.values, "-s", color=_TH_C3, ms=4.5, lw=1.6,
            label="acknowledged")
    # Fit the y range to the data rather than anchoring at zero: nothing
    # here falls below ~35%, and a zero-anchored axis spends a third of the
    # panel on empty space and flattens the degradation the figure is for.
    lo = float(min(q[("arr_pct", .25)].min(), q[("ack_pct", .25)].min(),
                   arr.min(), ack.min()))
    hi = float(max(q[("arr_pct", .75)].max(), q[("ack_pct", .75)].max(),
                   arr.max(), ack.max()))
    pad = max((hi - lo) * .08, 1.0)
    # The N labels ride in the top pad, so it has to clear them.
    top = hi + pad * 2.2
    for n in sorted(t.n.unique()):
        g = t[t.n == n]
        ax.annotate(f"N={n}", (g.pairs.median(), hi + pad * .9),
                    ha="center", fontsize=6.5, color="#666666")
    # Sample size on the thin bins. A band of zero width means one trial,
    # not perfect agreement, and the two are indistinguishable by eye --
    # three positions here (26, 41, 42 pairs) rest on a single trial while
    # 28 and 30 are genuinely tight over 3 and 6 trials.
    counts = t.groupby("pairs").size()
    for x in xs:
        if counts[x] <= 2:
            ax.annotate(f"n={counts[x]}", (x, ack[x]),
                        textcoords="offset points", xytext=(0, -12),
                        ha="center", fontsize=6, color="#888888")
    ax.set_xlabel("active ordered pairs")
    ax.set_ylabel("share of offered messages (%)")
    ax.set_ylim(lo - pad, top)
    # The axis runs past 100 to leave room for the N labels, but a share
    # cannot exceed 100 -- so the ticks stop there rather than inviting the
    # reader to interpret a 110% gridline.
    ticks = [v for v in range(0, 101, 10) if v >= lo - pad]
    ax.set_yticks(ticks)
    ax.grid(axis="y", alpha=.25)
    ax.legend(frameon=False, fontsize=8, loc="lower left")
    _th_save(fig, out / "clique_delivery_by_pairs.pdf")


def _th_delivery_method_by_n(df: pd.DataFrame, out: Path) -> None:
    """Of messages that ARRIVED, direct vs conveyed share by clique size N.

    Every bar sums to exactly 100% by construction (delivered = direct +
    relayed, no third category) -- this is deliberately a DIFFERENT question
    from `clique_delivery.pdf`'s overall arrival rate, which already shows
    what fraction of OFFERED messages gets through at all. This figure asks
    only: of what got through, which path did it take.

    `deliveryMethod` (message_router.dart) is a direct relabelling of
    `relayHops` -- a TTL-decrement count that only a THIRD-PARTY relay
    advances (CLAUDE.md: "the decrement happens ONCE per arrival ... the
    sender never decrements"). So 'direct' (relayHops<=0) covers a message
    that never passed through an intermediate node, whether it arrived on
    the first live write or later via the ORIGINATOR's own buffer syncing
    straight to the recipient -- both are zero-hop. 'relayed' is genuine
    multi-hop conveyance through someone else's store-carry-forward.

    A clique is a complete graph by construction -- every node is a direct
    neighbour of every other -- so there is rarely a reason to relay at
    all: measured at 0-0.13% of DELIVERED messages across the whole sweep
    (0, 0, 9, 0, 7, 36 relayed messages at N=2..7). N=7 happens to be the
    highest, but N=5 sits at zero between two nonzero neighbours and the
    sequence is not monotonic -- with counts this small, that reads as rare
    near-random events, not a trend with N. No run in this dataset exercises
    substantial multi-hop delivery: the line sweep has only two devices with
    no third party to relay through, and the clique's completeness removes
    the need even at N=7.
    """
    segs = [s for s in marker_segments(df)
            if re.match(r"N=\d+", s.get("label") or "")]
    if not segs:
        return
    msg = df[df._type == "message"]
    recv_all = msg[msg.dir == "recv"].drop_duplicates("messageId")
    method_by_id = dict(zip(recv_all.messageId, recv_all.deliveryMethod))
    rows = []
    for seg in segs:
        n = int(re.match(r"N=(\d+)", seg["label"]).group(1))
        sent_ids = _clique_sent_ids(msg, seg)
        direct = relayed = 0
        for mid in sent_ids:
            m = method_by_id.get(mid)
            if m == "direct":
                direct += 1
            elif m == "relayed":
                relayed += 1
        if direct + relayed == 0:
            continue
        rows.append(dict(n=n, direct=direct, relayed=relayed))
    if not rows:
        return
    t = pd.DataFrame(rows)
    ns = sorted(t.n.unique())
    # Ratio of sums: each trial weighs by the traffic it actually delivered,
    # not by trial count, matching plot_thesis_clique_figures' convention.
    grp = t.groupby("n")
    delivered = grp.direct.sum() + grp.relayed.sum()
    direct_pct = (100 * grp.direct.sum() / delivered).reindex(ns)
    relayed_pct = (100 * grp.relayed.sum() / delivered).reindex(ns)
    relayed_n = grp.relayed.sum().reindex(ns)

    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    ax.bar(ns, direct_pct, .6, color=_TH_C1, label="direct")
    ax.bar(ns, relayed_pct, .6, bottom=direct_pct, color=_TH_C2,
           label="conveyed (relayed)")
    for x in ns:
        rn = int(relayed_n[x])
        if rn:
            ax.annotate(f"{rn} ({relayed_pct[x]:.2f}%)",
                        (x, direct_pct[x] + relayed_pct[x]),
                        textcoords="offset points", xytext=(0, 3),
                        ha="center", fontsize=6.5, color="#666666")
    ax.set_xlabel("clique size $N$")
    ax.set_ylabel("share of delivered messages (%)")
    ax.set_xticks(ns)
    ax.set_ylim(0, 105)
    ax.grid(axis="y", alpha=.25)
    ax.legend(frameon=False, fontsize=8, loc="lower left")
    _th_save(fig, out / "clique_delivery_method.pdf")


def _th_delivery_mechanism_by_n(df: pd.DataFrame, out: Path) -> None:
    """Of delivered messages: did the immediate write alone ever suffice, or
    did the DTN buffer's sync-conveyance mechanism have to fire at least
    once along the way, by clique size N.

    NOT the same split as [_th_delivery_method_by_n] (deliveryMethod /
    relayHops), which is a MESH-TOPOLOGY fact (did a third party carry it)
    and reads as ~100% direct regardless of N -- a same-pair resend from the
    ORIGINATOR's own buffer is also zero-hop by that measure, so it hides
    exactly the mechanism this figure isolates.

    A message-latency threshold (fast=direct, slow=buffer) was tried first
    and rejected: unlike the line sweep's clean bimodal split (an empty gap
    at 1.0-1.5 s), clique latencies form a smooth continuum from tens of ms
    to ~26 minutes under contention, so no threshold is defensible.

    Instead this uses a directly-recorded event: `custody` type `convey`
    (message_router.dart) fires whenever ANY held copy -- the ORIGINATOR's
    own buffered packet or a bystander's carried one, the code path is
    shared -- is offered to a peer in response to that peer's sync filter.
    A delivered message with at least one `convey` for its packetId
    definitely had the buffer mechanism invoked at some point in its
    history; one with none could only have arrived via the immediate write,
    since nothing else ever moved it. This slightly OVER-counts "buffer"
    relative to "which attempt the arriving copy actually was" (a convey
    can run in parallel with a still-pending direct attempt), so the true
    buffer-necessity share is a mild upper bound here, not an exact one.

    CAVEAT, load-bearing: `custody` (store/convey) is by far the highest-
    volume record type in this dataset (456k + 30k vs ~230k message
    records combined) and its completeness is NOT uniform -- one N=3 block
    shows `convey` falling from the 100s per trial to literally 0 by its
    last three trials while `sent` stays exactly flat (600 every trial) and
    `recv` declines only gradually, ruling out a genuine mesh-behaviour
    cause. This looks like the highest-volume record type being the first
    casualty of some trace-capacity limit, not a "buffer stopped being
    used" fact. So the per-N pooled bar is a plausible UNDERESTIMATE, and
    because N is confounded with chronological position in this sweep (N=2
    ran first, N=7 last), a real upward trend with contention could be
    partly masked by worsening dropout at the same time. Individual trial
    values are scattered on top of each bar for exactly this reason --
    the N=3 spread (0% on 3 trials, 10-53% on the other 7) is that dropout
    happening mid-block, not organic trial-to-trial noise, and a reader
    should be able to see that shape rather than trust one smoothed number.
    """
    segs = [s for s in marker_segments(df)
            if re.match(r"N=\d+", s.get("label") or "")]
    if not segs:
        return
    msg = df[df._type == "message"]
    cust = df[df._type == "custody"]
    conv = cust[cust.event == "convey"] if "event" in cust.columns else cust
    # Both lookups are trace-wide, matching [_clique_sent_ids]: a delivery
    # and the conveyance that produced it can land well after the sending
    # trial's window closed.
    delivered_all = set(msg[msg.dir == "recv"].messageId.dropna())
    conveyed_all = set(conv.packetId.dropna())
    rows = []
    for seg in segs:
        n = int(re.match(r"N=(\d+)", seg["label"]).group(1))
        sent_ids = _clique_sent_ids(msg, seg)
        delivered = sent_ids & delivered_all
        if not delivered:
            continue
        via_buffer = len(delivered & conveyed_all)
        rows.append(dict(n=n, trial=seg["label"], delivered=len(delivered),
                         via_buffer=via_buffer,
                         pct=100 * via_buffer / len(delivered)))
    if not rows:
        return
    t = pd.DataFrame(rows)
    ns = sorted(t.n.unique())
    grp = t.groupby("n")
    buffer_pct = (100 * grp.via_buffer.sum() / grp.delivered.sum()).reindex(ns)
    direct_pct = 100 - buffer_pct
    buffer_n = grp.via_buffer.sum().reindex(ns)

    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    ax.bar(ns, direct_pct, .6, color=_TH_C1,
           label="direct write only (buffer never invoked)")
    ax.bar(ns, buffer_pct, .6, bottom=direct_pct, color=_TH_C2,
           label="DTN buffer conveyed at least once")
    # Individual trials, jittered, over the boundary between the two bands:
    # this is where the split actually happened for that trial, and it is
    # what exposes a dropout-driven cluster (identical trials sitting
    # exactly on the axis) as distinct from ordinary spread.
    rng = np.random.default_rng(3)
    dot_top = 100.0
    for n in ns:
        g = t[t.n == n]
        jitter = rng.uniform(-.12, .12, len(g))
        y = direct_pct[n] + g.pct.values
        dot_top = max(dot_top, float(y.max()))
        ax.scatter(n + jitter, y, s=14, color="#333333", alpha=.6,
                  zorder=5, linewidths=0)
    # Labels ride ABOVE the tallest dot in their own column, not at a fixed
    # y=100: the per-trial dots scatter well past 100 (a trial's own split
    # can exceed the pooled bar's), and a fixed anchor sits under them.
    for x in ns:
        bn = int(buffer_n[x])
        if bn:
            g = t[t.n == x]
            top = max(100.0, float((direct_pct[x] + g.pct.values).max()))
            ax.annotate(f"{bn} ({buffer_pct[x]:.1f}%)", (x, top),
                        textcoords="offset points", xytext=(0, 5),
                        ha="center", fontsize=6.5, color="#666666")
    ax.set_xlabel("clique size $N$")
    ax.set_ylabel("share of delivered messages (%)")
    ax.set_xticks(ns)
    # Headroom above BOTH the highest jittered dot (a trial can exceed 100%
    # of the pooled bar's split point) and the count/pct annotation sitting
    # just above y=100 -- a fixed limit clipped N=7's own trials earlier.
    ax.set_ylim(0, dot_top + 12)
    ax.grid(axis="y", alpha=.25)
    ax.legend(frameon=False, fontsize=7.5, loc="lower left")
    _th_save(fig, out / "clique_delivery_mechanism.pdf")


def _th_conveyance_touch_by_n(df: pd.DataFrame, out: Path) -> None:
    """Of ALL sent messages -- delivered or not -- share ever picked up by a
    bystander's custody (`relay`, non-dup events, `hop>=1`) vs never touched
    (pure direct attempt throughout), by clique size N.

    Different question from [_th_delivery_method_by_n]: that figure asks,
    of what ARRIVED, which path it took. This one asks how often the
    conveyance mechanism gets INVOKED at all, independent of whether the
    attempt ever completed -- most invocations do not (of 4298 touched
    messages pooled across the sweep, 37 were ever delivered: a 0.9% success
    rate once invoked, on top of only 4.0% of sends being touched at all).
    """
    segs = [s for s in marker_segments(df)
            if re.match(r"N=\d+", s.get("label") or "")]
    if not segs:
        return
    msg = df[df._type == "message"]
    rel = df[df._type == "relay"]
    rel = rel[rel.event != "dup"] if "event" in rel.columns else rel
    # Trace-wide, per [_clique_sent_ids]: a bystander can take a packet into
    # custody after the sending trial's window has closed.
    touched_all = set(rel.packetId.dropna())
    rows = []
    for seg in segs:
        n = int(re.match(r"N=(\d+)", seg["label"]).group(1))
        sent_ids = _clique_sent_ids(msg, seg)
        if not sent_ids:
            continue
        rows.append(dict(n=n, sent=len(sent_ids),
                         touched=len(sent_ids & touched_all)))
    if not rows:
        return
    t = pd.DataFrame(rows)
    ns = sorted(t.n.unique())
    grp = t.groupby("n")
    touched_pct = (100 * grp.touched.sum() / grp.sent.sum()).reindex(ns)
    direct_pct = 100 - touched_pct
    touched_n = grp.touched.sum().reindex(ns)

    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    ax.bar(ns, direct_pct, .6, color=_TH_C1, label="never touched (pure direct)")
    ax.bar(ns, touched_pct, .6, bottom=direct_pct, color=_TH_C2,
           label="touched by conveyance")
    for x in ns:
        ax.annotate(f"{int(touched_n[x])}", (x, 100),
                    textcoords="offset points", xytext=(0, 3),
                    ha="center", fontsize=6.5, color="#666666")
    ax.set_xlabel("clique size $N$")
    ax.set_ylabel("share of sent messages (%)")
    ax.set_xticks(ns)
    ax.set_ylim(0, 108)
    ax.grid(axis="y", alpha=.25)
    ax.legend(frameon=False, fontsize=8, loc="lower left")
    _th_save(fig, out / "clique_conveyance_touch.pdf")


def _th_write_fails_by_n(df: pd.DataFrame, out: Path) -> None:
    """writeFailed drops by clique size N: total count (bars) and rate per
    message sent (line, right axis) -- the raw count trivially rises with N
    because offered load itself rises as N(N-1); the rate is what actually
    says whether writes get HARDER at higher N or just more numerous.
    """
    segs = [s for s in marker_segments(df)
            if re.match(r"N=\d+", s.get("label") or "")]
    if not segs:
        return
    msg = df[df._type == "message"]
    drop = df[df._type == "drop"]
    rows = []
    for seg in segs:
        n = int(re.match(r"N=(\d+)", seg["label"]).group(1))
        a = seg["t0_dwell"] if seg["t0_dwell"] is not None else seg["t0"]
        bd = seg["t1_drain"] if seg.get("t1_drain") is not None else seg["t1"]
        sent = int(((msg._t >= a) & (msg._t < bd) & (msg.dir == "sent")).sum())
        wf = int(((drop._t >= a) & (drop._t < bd)
                  & (drop.reason == "writeFailed")).sum())
        rows.append(dict(n=n, sent=sent, writeFailed=wf))
    t = pd.DataFrame(rows)
    ns = sorted(t.n.unique())
    grp = t.groupby("n")
    wf_total = grp.writeFailed.sum().reindex(ns)
    wf_rate = (100 * grp.writeFailed.sum() / grp.sent.sum()).reindex(ns)

    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    ax.bar(ns, wf_total, .6, color=_TH_C1, label="writeFailed (count)")
    ax.set_xlabel("clique size $N$")
    ax.set_ylabel("writeFailed drops (count)")
    ax.set_xticks(ns)
    ax.grid(axis="y", alpha=.25)
    ax2 = ax.twinx()
    ax2.plot(ns, wf_rate, "-o", color=_TH_C3, ms=5, lw=1.8,
             label="writeFailed per message sent (right)")
    ax2.set_ylabel("writeFailed per message sent (%)", color="#7a3b5e")
    ax2.tick_params(colors="#7a3b5e")
    ax2.spines["right"].set_visible(True)
    h1, l1 = ax.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax.legend(h1 + h2, l1 + l2, frameon=False, fontsize=7.5, loc="upper left")
    _th_save(fig, out / "clique_write_fails.pdf")


def plot_thesis_clique_figures(df: pd.DataFrame, steps: pd.DataFrame,
                               pairs: pd.DataFrame, out: Path) -> None:
    """The diluting clique's figures: delivery and acknowledgement against
    clique size (aggregate offered load on a second axis), and the
    direct-vs-conveyed delivery split.

    Skipped unless the run carries `N=` steps at two or more clique sizes,
    so a line sweep never emits it.
    """
    if steps.empty or "label" not in steps.columns:
        return
    st = steps.copy()
    st["N"] = st["label"].str.extract(r"N=(\d+)").astype(float)
    st = st.dropna(subset=["N"])
    if st["N"].nunique() < 2:
        return
    pm = pairs.copy() if pairs is not None and not pairs.empty else None
    if pm is not None and "label" in pm.columns:
        pm["N"] = pm["label"].str.extract(r"N=(\d+)").astype(float)
        pm = pm.dropna(subset=["N"])
    out.mkdir(parents=True, exist_ok=True)
    ns = sorted(st["N"].unique())
    # Ratio of sums, not the mean of per-trial rates: the quantity claimed is
    # the share of OFFERED messages that arrive, so each trial weighs by the
    # traffic it carried. The two agree to 0.2 points here (trial sizes are
    # nearly uniform within an N), but they answer different questions and
    # only this one answers the chapter's.
    arr = [st[st["N"] == n]["msg_arrived"].sum()
           / max(st[st["N"] == n]["msg_sent"].sum(), 1) * 100 for n in ns]
    # Error bars come from the spread BETWEEN trials, never from a binomial
    # over messages. Messages inside one trial are not independent -- a stall
    # loses hundreds at once -- so the experimental unit is the trial. The
    # message-level interval is 5-15x too narrow (design effect 23-226).
    err = []
    for n in ns:
        g = st[st["N"] == n]
        rates = (g["msg_arrived"] / g["msg_sent"].replace(0, np.nan)).dropna()
        err.append(100 * rates.std(ddof=1) / np.sqrt(len(rates))
                   if len(rates) > 1 else 0.0)
    ack = ([pm[pm["N"] == n]["acked"].sum()
            / max(pm[pm["N"] == n]["arrived"].sum(), 1) * 100 for n in ns]
           if pm is not None else None)
    with plt.rc_context(_TH):
        fig, ax = plt.subplots(figsize=(6.2, 3.4))
        ax.errorbar(ns, arr, yerr=err, fmt="-o", color=_TH_C1, ms=5, lw=1.8,
                    capsize=3, elinewidth=1.1, label="arrived")
        if ack:
            ax.plot(ns, ack, "-s", color=_TH_C3, ms=4.5, lw=1.6,
                    label="acknowledged (of arrived)")
        ax.set_xlabel("clique size $N$")
        ax.set_ylabel("share of messages (%)")
        ax.set_xticks([int(n) for n in ns])
        ax.set_ylim(0, 105)
        ax.grid(axis="y", alpha=.25)
        # The offered load is the independent variable the sweep actually
        # moves: per-pair load is held at the line sweep's, so aggregate
        # grows as N(N-1).
        ax2 = ax.twinx()
        load = [n * (n - 1) * 100 / 30.0 for n in ns]
        ax2.plot(ns, load, ":", color="#999999", lw=1.4,
                 label="offered load (right)")
        ax2.set_ylabel("aggregate offered load (msg/s)", color="#777777")
        ax2.tick_params(colors="#777777")
        ax2.spines["right"].set_visible(True)
        h1, l1 = ax.get_legend_handles_labels()
        h2, l2 = ax2.get_legend_handles_labels()
        ax.legend(h1 + h2, l1 + l2, frameon=False, fontsize=7.5,
                  loc="lower left")
        _th_save(fig, out / "clique_delivery.pdf")
        _th_delivery_method_by_n(df, out)
        _th_delivery_by_active_pairs(df, out)
        _th_delivery_vs_degree(df, out)
        _th_delivery_mechanism_by_n(df, out)
        _th_conveyance_touch_by_n(df, out)
        _th_write_fails_by_n(df, out)


def plot_thesis_line_figures(df: pd.DataFrame, steps: pd.DataFrame,
                             pairs: pd.DataFrame, out: Path) -> None:
    """Write the line-sweep figures the evaluation chapter cites, plus two
    appendix variants of the ladder.

    Skipped unless the run carries `d=` markers on at least two positions,
    so a clique or a smoke never emits them.
    """
    line = _line_steps(steps)
    if line.empty or line["d"].nunique() < 2:
        return
    out.mkdir(parents=True, exist_ok=True)
    with plt.rc_context(_TH):
        byd = _th_ladder(df)
        # The distance and RSSI establishment panels are set side by side,
        # so both take the union of their two band ranges.
        est_ylim = _est_shared_ylim(byd, df)
        # Population per distance INCLUDING failed establishments, so the
        # panel can disclose an incomplete position as k/n.
        est_totals = collections.Counter(d for _e, _r, d in _th_trial_rssi(df))
        _th_establishment(byd, out / "line200_establishment.pdf",
                          ylim=est_ylim, totals=est_totals)
        stages_ylim = _stages_shared_ylim(byd, df)
        _th_stages(byd, out / "line200_stages.pdf", ylim=stages_ylim,
                   compact=True)
        _th_stages_vs_rssi(df, out / "line200_stages_vs_rssi.pdf",
                           ylim=stages_ylim)
        _th_path_loss(df, out / "line200_path_loss.pdf")
        _th_control_bytes(df, out / "line200_control_bytes.pdf")
        _th_stage_bytes_pair(df, out)
        _th_delivery_vs_rssi(line, out / "line200_delivery_vs_rssi.pdf")
        _th_latency_vs_rssi(line, out / "line200_latency_vs_rssi.pdf")
        _th_establishment_vs_rssi(df, out / "line200_establishment_vs_rssi.pdf",
                                  ylim=est_ylim)
        # Appendix pair: the same two figures over trials in which no dial
        # was refused, so the ladder is the cost of a link that forms.
        clean = _th_ladder(df, drop_gatt133=True)
        _th_establishment(clean, out / "line200_establishment_clean.pdf")
        _th_stages(clean, out / "line200_stages_clean.pdf")
        comp = _th_ladder(df, complete_only=True)
        _th_stages(comp, out / "line200_stages_complete.pdf")


def _th_save(fig, out: Path, tight: bool = True) -> None:
    """`tight=False` keeps the full canvas instead of cropping to content.

    The paired panels need it: a tight crop keeps the left panel's y
    furniture inside its box and crops the stripped right panel narrower,
    and LaTeX then upscales the narrower PDF to the same \\linewidth --
    the right panel renders visibly LARGER. Fixed canvas + identical
    margins on both is what makes 0.49\\linewidth each come out equal.
    """
    if tight:
        fig.savefig(out)
    else:
        with plt.rc_context({"savefig.bbox": None}):
            fig.savefig(out)
    plt.close(fig)


def _th_establishment(byd: dict, out: Path, ylim: tuple | None = None,
                      totals: dict | None = None) -> None:
    """Cold session establishment per trial, with the per-distance median
    and IQR. Points rather than a mean because the spread is the point.

    Drawn from the same per-device ladder the text quotes, NOT from the
    per-step table: the two pool differently (one row per device-trial
    against one row per step) and quoting one beside a figure of the other
    puts two medians for the same quantity on facing pages.

    `totals` maps distance -> device-trial POPULATION: a position whose
    trials include failed establishments is annotated established/total
    (e.g. 18/20), so a failure thins no bin silently.
    """
    # Sized to sit two-up beside [_th_establishment_vs_rssi] in a
    # \begin{figure} with two \subcaptionbox, so the pair must share a
    # shape and a y-label.
    fig, ax = plt.subplots(figsize=(3.5, 3.0))
    ds = sorted(d for d in byd if byd[d].get("session"))
    med = [float(np.median(byd[d]["session"])) for d in ds]
    q1 = [float(np.percentile(byd[d]["session"], 25)) for d in ds]
    q3 = [float(np.percentile(byd[d]["session"], 75)) for d in ds]
    if totals:
        for d, m in zip(ds, med):
            k = len(byd[d]["session"])
            n = int(totals.get(d, k))
            if n > k:
                ax.annotate(f"{k}/{n}", (d, m), textcoords="offset points",
                            xytext=(0, 9), ha="center", fontsize=6.5,
                            color="#666666")
    ax.fill_between(ds, q1, q3, color=_TH_C1, alpha=.22, zorder=2,
                    edgecolor=_TH_C1, linewidth=.9, label="IQR")
    ax.plot(ds, med, "-o", color=_TH_C1, lw=1.8, ms=4, zorder=4,
            label="median")
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("time to session establishment (s)")
    # Every other position, phased so the stride LANDS on the sweep's last
    # one rather than having it appended: the extreme is what the text
    # quotes, and bolting it onto an even stride leaves a short final gap.
    ax.set_xticks(ds[1::2] if len(ds) % 2 == 0 else ds[::2])
    # Bound to the IQR band, not to the per-trial extremes: the scatter is
    # gone and a zero-anchored axis spent most of the panel on space no
    # band reaches. A small floor keeps the fastest band off the spine.
    # `ylim` overrides it so this can share a scale with the RSSI panel.
    if ylim is None:
        lo, hi = min(q1), max(q3)
        pad = max((hi - lo) * .12, .2)
        ylim = (max(0.0, lo - pad), hi + pad)
    ax.set_ylim(*ylim)
    ax.grid(axis="y", alpha=.25)
    ax.legend(frameon=False, fontsize=8)
    fig.subplots_adjust(**_TH_PAIR_MARGINS)
    _th_save(fig, out, tight=False)


_TH_RUNGS = ("advert", "gattConnected", "identified", "session",
             "settled", "usable")


def _th_ladder(df: pd.DataFrame,
               drop_gatt133: bool = False,
               complete_only: bool = False
               ) -> dict[float, dict[str, list[float]]]:
    """Per-distance stage times, each anchored at the trial's own `bt-on`.

    The advertisement stage is taken from the raw `rssi` sightings, NOT the
    `discovered` link event: that event is stamped once a path exists, so it
    can never precede the link and would invert the ladder.
    """
    per: dict[str, list] = defaultdict(list)
    for _, r in df.iterrows():
        t, typ = r.get("_t"), r.get("_type")
        if pd.isna(t):
            continue
        dev = str(r.get("_device", ""))[:8]
        lab = r.get("label") if isinstance(r.get("label"), str) else None
        ev = r.get("event") if isinstance(r.get("event"), str) else None
        if typ == "marker" and lab and lab.startswith("d="):
            per[dev].append((t, "STEP", lab))
        elif typ == "marker" and lab == "bt-on":
            per[dev].append((t, "BTON", None))
        elif typ == "marker" and lab == "run-end":
            per[dev].append((t, "RUNEND", None))
        elif typ == "marker" and lab == "link-settled":
            per[dev].append((t, "settled", None))
        elif typ == "rssi" and r.get("src") == "adv":
            per[dev].append((t, "advert", None))
        elif typ == "link" and ev in ("gattConnected", "identified",
                                      "session", "usable"):
            per[dev].append((t, ev, None))
        elif (typ == "link" and ev == "dialFailed"
              and "133" in str(r.get("error"))):
            # Android's generic GATT_ERROR on a dial. Not a stage -- a marker
            # that this trial's link formation was rejected at least once.
            per[dev].append((t, "GATT133", None))
    byd: dict[float, dict[str, list[float]]] = defaultdict(
        lambda: defaultdict(list))
    for dev, ev in per.items():
        ev.sort(key=lambda x: x[0])
        step = None
        bton = None
        runend = None
        refused = False
        # (stage, time, anchor) — the anchor is frozen when the stage fires,
        # NOT at the end of the step. The operator's stack reset for the walk
        # lands inside the LAST trial at a position, after that trial's
        # stages; anchoring on the step's final bt-on measured 18 of 198
        # trials against a radio that came up after the session they were
        # timing, and every one of them was a t10.
        first: dict[str, tuple[float, float | None]] = {}

        def flush(step_lab, got, end, bad=False):
            """Keep only stages reached inside the trial's own send window.

            A stage the pair climbs after `run-end` --- during the drain, or
            while the operator walks --- did not serve the trial that is
            being timed. In practice this discards almost nothing (2 of 171
            advertisement sightings on the 200 m sweep, and none of any
            other stage), which is itself the useful check: establishment
            finishes well inside the dwell at every distance the pair can
            reach at all.
            """
            if not step_lab or not got:
                return
            # A trial whose dial was refused is a link-formation failure, not
            # a measurement of how long forming a link takes. The appendix
            # figures drop them so the ladder shows the cost of a link that
            # forms, with the failure RATE reported separately.
            if bad and drop_gatt133:
                return
            # Complete cases only: every rung present for this device-trial.
            # The six curves then describe ONE set of trials, which is what
            # makes the vertical distance between two of them readable as a
            # leg. Without it the advertisement rung is missing on 25 trials
            # -- devices the peer dialled before their own scanner found it --
            # so each curve summarises a slightly different population.
            if complete_only and not all(k in got for k in _TH_RUNGS):
                return
            d = float(re.match(r"d=(\d+)", step_lab).group(1))
            for kk, (vv, anchor) in got.items():
                if anchor is None or vv < anchor:
                    continue
                if end is not None and vv > end:
                    continue
                byd[d][kk].append((vv - anchor) / 1000.0)

        for t, k, lab in ev:
            if k == "STEP":
                flush(step, first, runend, refused)
                step, first, bton, runend = lab, {}, None, None
                refused = False
            elif k == "GATT133":
                if step and bton is not None:
                    refused = True
            elif k == "BTON":
                bton = t
            elif k == "RUNEND":
                runend = t
            elif step and k not in first:
                # A stage stamped between the step marker and the step's own
                # `bt-on` belongs to the radio the reset is about to take
                # down, not to the trial being timed. Skip it rather than
                # recording it: `k not in first` means whatever lands here
                # first claims the stage for the whole trial, so an event
                # from the dying radio takes a stage that no later, real one
                # can then fill, and the trial drops out of that stage
                # entirely. It cost 16 of 200 GATT-link stages and 6
                # advertisement stages, all of them trials that went on to
                # form a session normally.
                if bton is None:
                    continue
                first[k] = (t, bton)
        flush(step, first, runend, refused)
    return byd


# Which rungs carry an IQR band. All six overlap into one indistinct mass --
# the five packet rungs run within a second of each other for most of the
# sweep -- so the band is drawn only on the two that bracket the ladder: the
# radio rung at the bottom and the first acknowledged payload at the top.
# Their widths are the comparison the figure is for; the rungs between them
# are bracketed by definition.
_TH_STAGE_BANDS = ("advert", "usable")


def _th_stages(byd: dict, out: Path, ylim: tuple | None = None,
               compact: bool = False) -> None:
    """The six-stage ladder, per-distance medians.

    `compact` sizes the panel to sit two-up beside [_th_stages_vs_rssi]
    (the establishment pair's geometry) and carries the pair's only
    legend, single-column so it fits the narrow panel's empty upper-left.
    """
    if len(byd) < 2:
        return
    ds = sorted(byd)
    # Marker SHAPE carries the stage, not colour alone. Six curves that cross
    # each other are unreadable in greyscale, and to a colour-blind reader,
    # if hue is the only key --- and this figure is read by tracing ONE stage
    # across the sweep. The advertisement keeps a hollow marker as well as a
    # dashed line: it is the only stage measured off the radio rather than
    # off a packet, and that distinction is the paragraph's whole point.
    stages = [("advert", "advertisement", "--", _TH_C2, "o", "none"),
             ("gattConnected", "GATT link", "-", _TH_C1, "s", None),
             ("identified", "identified", "-", _TH_C3, "^", None),
             ("session", "Noise session", "-", "#444444", "D", None),
             ("settled", "settled", "-", "#7f8c8d", "v", None),
             ("usable", "usable (first ACK)", "-", "#c0392b", "X", None)]
    fig, ax = plt.subplots(figsize=(3.5, 3.0) if compact else (6.2, 3.8))
    for key, lab, ls, col, marker, mfc in stages:
        ys = [float(np.median(byd[d][key])) if byd[d].get(key) else np.nan
              for d in ds]
        if all(np.isnan(y) for y in ys):
            continue
        # The band is the trial-to-trial spread, drawn under every curve so a
        # rung's median is never read as a tight number. Six bands overlap, so
        # they are faint and unedged: they are there to be compared in width
        # against each other, not to be read off the axis.
        q1 = [float(np.percentile(byd[d][key], 25)) if byd[d].get(key)
              else np.nan for d in ds]
        q3 = [float(np.percentile(byd[d][key], 75)) if byd[d].get(key)
              else np.nan for d in ds]
        if key in _TH_STAGE_BANDS:
            ax.fill_between(ds, q1, q3, color=col, alpha=.13, linewidth=0,
                            zorder=1)
        ax.plot(ds, ys, linestyle=ls, marker=marker, ms=6.5, lw=1.3,
                color=col, markerfacecolor=(col if mfc is None else mfc),
                markeredgecolor=col, markeredgewidth=1.3, label=lab,
                zorder=3)
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("median time to stage (s)")
    # Compact: every other position, phased to land on the sweep's last
    # one, as on the establishment panel -- ten labels do not fit 3.5 in.
    ax.set_xticks((ds[1::2] if len(ds) % 2 == 0 else ds[::2])
                  if compact else ds)
    if ylim is not None:
        ax.set_ylim(*ylim)
    ax.grid(axis="y", alpha=.25)
    if compact:
        ax.legend(frameon=False, fontsize=6.5, ncol=1, handlelength=2.2,
                  borderaxespad=0.2, loc="upper left")
    else:
        ax.legend(frameon=False, fontsize=8, ncol=2, handlelength=3.0,
                  columnspacing=1.4, borderaxespad=0.2)
    if compact:
        fig.subplots_adjust(**_TH_PAIR_MARGINS)
    _th_save(fig, out, tight=not compact)


def _stages_rssi_bins(df: pd.DataFrame, width: int = 3):
    """(bin centres, per-bin lists of stage dicts) for the RSSI stages
    view, or None. Split out of [_th_stages_vs_rssi] so the shared y-range
    with the distance stages panel can be computed without drawing.
    """
    return _th_stages_vs_rssi(df, None, width=width)


def _stages_shared_ylim(byd: dict, df: pd.DataFrame) -> tuple | None:
    """The y-limits both stages panels should use: the union of what each
    panel's own topmost band (the `usable` rung's q3) needs. The RSSI
    panel draws no y ticks, so an unshared scale there would be invisible
    as well as wrong.
    """
    tops = []
    for d in byd:
        v = byd[d].get("usable")
        if v:
            tops.append(float(np.percentile(v, 75)))
    rb = _stages_rssi_bins(df)
    if rb is not None:
        ks, bins = rb
        for k in ks:
            v = [s["usable"] for s in bins[k] if "usable" in s]
            if v:
                tops.append(float(np.percentile(v, 75)))
    if not tops:
        return None
    return (0.0, max(tops) * 1.05)


def _th_stages_vs_rssi(df: pd.DataFrame, out: Path | None, width: int = 3,
                       ylim: tuple | None = None):
    """The six-stage ladder against the trial's pooled link budget.
    With `out=None`, returns the (bin centres, binned stage dicts) instead
    of drawing -- the [_stages_rssi_bins] path.

    The same rungs as [_th_stages], re-binned the way
    [_th_establishment_vs_rssi] bins its one rung: the pair's POOLED
    advertisement RSSI (both ends' sightings -- a device the peer dialled
    before its own scanner fired has no sightings of its own, and those are
    the fast trials), centred bins of `width` dB, thin bins folded into
    their neighbour. Pooling fixes only the x -- a device with no sightings
    still has no ADVERTISEMENT rung, exactly as on the distance version.

    The walk below mirrors [_th_ladder]'s rules and must change with them:
    the advertisement rung comes from raw `rssi` sightings (never the
    `discovered` link event), `settled` from the `link-settled` marker,
    each rung's anchor is frozen at the `bt-on` in force when the rung
    fires, a rung stamped before the step's own `bt-on` is skipped, and a
    rung climbed after `run-end` did not serve the trial being timed.
    """
    per: dict[str, list] = defaultdict(list)
    for _, r in df.iterrows():
        t, typ = r.get("_t"), r.get("_type")
        if pd.isna(t):
            continue
        dev = str(r.get("_device", ""))[:8]
        lab = r.get("label") if isinstance(r.get("label"), str) else None
        ev = r.get("event") if isinstance(r.get("event"), str) else None
        if typ == "marker" and lab and lab.startswith("d="):
            per[dev].append((t, "STEP", lab, None))
        elif typ == "marker" and lab == "bt-on":
            per[dev].append((t, "BTON", None, None))
        elif typ == "marker" and lab == "run-end":
            per[dev].append((t, "RUNEND", None, None))
        elif typ == "marker" and lab == "link-settled":
            per[dev].append((t, "settled", None, None))
        elif typ == "rssi" and r.get("src") == "adv":
            per[dev].append((t, "advert", None, r.get("rssi")))
        elif typ == "link" and ev in ("gattConnected", "identified",
                                      "session", "usable"):
            per[dev].append((t, ev, None, None))
    recs: list[dict] = []
    for dev, evs in per.items():
        evs.sort(key=lambda x: x[0])
        step = bton = runend = None
        ordn = -1
        first: dict[str, tuple[float, float]] = {}
        advs: list[float] = []

        def flush():
            if not step or not first:
                return
            stages = {}
            for kk, (vv, anchor) in first.items():
                if vv < anchor:
                    continue
                if runend is not None and vv > runend:
                    continue
                stages[kk] = (vv - anchor) / 1000.0
            if stages:
                recs.append(dict(ordn=ordn, lab=step, stages=stages,
                                 advs=list(advs)))

        for t, k, lab, v in evs:
            if k == "STEP":
                flush()
                step, bton, runend, ordn = lab, None, None, ordn + 1
                first, advs = {}, []
            elif k == "BTON":
                bton = t
            elif k == "RUNEND":
                runend = t
            elif step and bton is not None:
                if k == "advert" and v is not None and (
                        runend is None or t <= runend):
                    advs.append(float(v))
                if k not in first:
                    first[k] = (t, bton)
        flush()
    if not recs:
        return
    pooled: dict[tuple, list[float]] = defaultdict(list)
    for rec in recs:
        pooled[(rec["ordn"], rec["lab"])].extend(rec["advs"])
    bins: dict[int, list[dict]] = defaultdict(list)
    for rec in recs:
        pool = pooled[(rec["ordn"], rec["lab"])]
        if not pool:
            continue
        key = width * int(np.floor(float(np.median(pool)) / width + 0.5))
        bins[key].append(rec["stages"])
    while True:
        thin = [k for k in sorted(bins) if len(bins[k]) < 4]
        if not thin or len(bins) <= 1:
            break
        k = thin[0]
        neigh = [j for j in bins if j != k]
        tgt = min(neigh, key=lambda j: abs(j - k))
        bins[tgt].extend(bins.pop(k))
    ks = sorted(bins)
    if len(ks) < 3:
        return None
    if out is None:
        return (ks, bins)
    stages = [("advert", "advertisement", "--", _TH_C2, "o", "none"),
              ("gattConnected", "GATT link", "-", _TH_C1, "s", None),
              ("identified", "identified", "-", _TH_C3, "^", None),
              ("session", "Noise session", "-", "#444444", "D", None),
              ("settled", "settled", "-", "#7f8c8d", "v", None),
              ("usable", "usable (first ACK)", "-", "#c0392b", "X", None)]
    # The establishment pair's geometry: this is the pair's right panel.
    fig, ax = plt.subplots(figsize=(3.5, 3.0))
    for key, lab, ls, col, marker, mfc in stages:
        series = [[s[key] for s in bins[k] if key in s] for k in ks]
        ys = [float(np.median(v)) if v else np.nan for v in series]
        if all(np.isnan(y) for y in ys):
            continue
        if key in _TH_STAGE_BANDS:
            q1 = [float(np.percentile(v, 25)) if v else np.nan
                  for v in series]
            q3 = [float(np.percentile(v, 75)) if v else np.nan
                  for v in series]
            ax.fill_between(ks, q1, q3, color=col, alpha=.13, linewidth=0,
                            zorder=1)
        ax.plot(ks, ys, linestyle=ls, marker=marker, ms=6.5, lw=1.3,
                color=col, markerfacecolor=(col if mfc is None else mfc),
                markeredgecolor=col, markeredgewidth=1.3, label=lab,
                zorder=3)
    ax.set_xlabel("advertisement RSSI (dBm)")
    if ylim is not None:
        ax.set_ylim(*ylim)
    # No y furniture and no legend: this panel sits to the RIGHT of the
    # distance stages figure on a shared scale, which carries both. The
    # tick positions stay so the gridlines align across the pair.
    ax.tick_params(left=False, labelleft=False)
    ax.grid(axis="y", alpha=.25)
    ax.invert_xaxis()  # strong signal left, weak right
    fig.subplots_adjust(**_TH_PAIR_MARGINS)
    _th_save(fig, out, tight=False)


def _th_path_loss(df: pd.DataFrame, out: Path) -> None:
    """Advertisement RSSI per distance over the RAW sightings, boxed, with
    the log-distance fit on the per-distance medians."""
    rssi = df[df._type == "rssi"]
    if rssi.empty:
        return
    adv = rssi[_col(rssi, "src") == "adv"]
    segs = _distance_segments(df)
    if adv.empty or not segs:
        return
    byd: dict[float, list[float]] = defaultdict(list)
    for seg in segs:
        v = pd.to_numeric(
            _col(adv[(adv._t >= seg["t0"]) & (adv._t < seg["t1"])], "rssi"),
            errors="coerce").dropna()
        if len(v):
            byd[float(seg["d"])].extend(v.tolist())
    byd = {d: v for d, v in byd.items() if len(v) >= 20}
    if len(byd) < 2:
        return
    ds = sorted(byd)
    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    bp = ax.boxplot([byd[d] for d in ds], positions=range(len(ds)),
                    widths=.55, showfliers=False, patch_artist=True,
                    medianprops=dict(color="#222222", linewidth=1.6),
                    whiskerprops=dict(color="#888888"),
                    capprops=dict(color="#888888"),
                    boxprops=dict(edgecolor="#888888", linewidth=.9))
    for patch in bp["boxes"]:
        patch.set_facecolor(_TH_C1)
        patch.set_alpha(.35)
    # Sample count above each box: `showfliers=False` means a box drawn from
    # thousands of sightings looks identical to one drawn from twenty, and
    # the twenty-sighting floor at line 4260 already lets a thin distance
    # through -- the label is what tells a reader which case they're looking
    # at. Anchored to the whisker cap (not max(byd[d])), since that is the
    # actual top of what got drawn; an outlier past it would place the
    # number over empty space.
    for i, d in enumerate(ds):
        top = bp["caps"][2 * i + 1].get_ydata()[0]
        ax.annotate(f"{len(byd[d])}", (i, top), textcoords="offset points",
                    xytext=(0, 4), ha="center", va="bottom",
                    fontsize=6.5, color="#666666")
    inter, n_exp, r2, _, _ = adv_pathloss_fit(byd)
    grid = np.linspace(0, len(ds) - 1, 200)
    dgrid = np.interp(grid, range(len(ds)), ds)
    ax.plot(grid, inter - 10 * n_exp * np.log10(dgrid),
            "--", color=_TH_C2, lw=1.6,
            label=f"fit: $n={n_exp:.2f}$, $R^2={r2:.2f}$")
    ax.set_xticks(range(len(ds)))
    ax.set_xticklabels([f"{int(d)}" for d in ds])
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("advertisement RSSI (dBm)")
    ax.grid(axis="y", alpha=.25)
    ax.legend(frameon=False, fontsize=8, loc="lower left")
    _th_save(fig, out)


def _th_control_bytes(df: pd.DataFrame, out: Path) -> None:
    """Standing control plane per trial per device, stacked by packet class,
    with the data plane on a right axis."""
    wire = df[df._type == "wire"]
    segs = _distance_segments(df)
    if wire.empty or not segs:
        return
    agg: dict[float, collections.Counter] = defaultdict(collections.Counter)
    trials: collections.Counter = collections.Counter()
    for seg in segs:
        d = float(seg["d"])
        trials[d] += 1
        for _, w in wire[(wire._t >= seg["t0"])
                         & (wire._t < seg["t1"])].iterrows():
            for k, v in _dict(w.get("txBytes")).items():
                agg[d][str(k)] += int(v)
    ds = sorted(agg)
    if len(ds) < 2:
        return
    fig, ax = plt.subplots(figsize=(6.2, 4.0))
    layers = [("announce", "ANNOUNCE", _TH_C2),
              ("secure:sync", "sync filter", _TH_C1),
              ("handshake", "Noise handshake", _TH_C3)]
    bottom = np.zeros(len(ds))
    for key, lab, col in layers:
        vals = np.array([agg[d][key] / (trials[d] * 2) / 1000 for d in ds])
        if not (vals > 0).any():
            continue
        ax.bar(range(len(ds)), vals, .62, bottom=bottom, color=col, label=lab)
        bottom = bottom + vals
    # Headroom above the tallest bar for the legend, which otherwise sits
    # directly on top of whichever bar peaks closest to the axis limit.
    ax.set_ylim(0, max(bottom.max(), 1) * 1.35)
    ax2 = ax.twinx()
    dv = np.array([(agg[d]["secure"] + agg[d]["secure:ack"])
                   / (trials[d] * 2) / 1000 for d in ds])
    ax2.plot(range(len(ds)), dv, "-o", color="#999999", ms=4, lw=1.4,
             label="data plane (right)")
    ax2.set_ylabel("data plane (kB)", color="#777777")
    ax2.set_ylim(0, max(dv.max(), 1) * 1.25)
    ax2.spines["right"].set_visible(True)
    ax2.tick_params(colors="#777777")
    ax.set_xticks(range(len(ds)))
    ax.set_xticklabels([f"{int(d)}" for d in ds])
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("control plane (kB / trial / device)")
    ax.grid(axis="y", alpha=.25)
    h1, l1 = ax.get_legend_handles_labels()
    h2, l2 = ax2.get_legend_handles_labels()
    ax.legend(h1 + h2, l1 + l2, frameon=False, fontsize=7.5, ncol=2,
              loc="upper left")
    _th_save(fig, out)


# The advertising cadence, measured rather than assumed. Android asks for
# ADVERTISE_MODE_LOW_LATENCY (nominally 100 ms); what a Nexus 5X actually puts
# on the air is a 130-140 ms modal gap between advertising EVENTS.
#
# Measured by `adv-capture-1`, an arm built to isolate exactly this: one phone
# advertising, one scanning, dialing capped at zero so no GATT link, session or
# traffic ever competes for the radio. Ten one-minute runs, each bouncing the
# stack first, agree to within 0.7 sightings/s. The gap distribution is
# unambiguous -- 74.6% of gaps at one interval, 12.5% at exactly two, 2.0% at
# three, the geometric decay of independent misses against a fixed cadence.
# That scanner captured 83% of the transmitter, against ~51% for a dual-role
# phone at the same desk distance (`line-smoke-1`), which is the cost of a
# radio that is also maintaining links.
#
# Events are recovered from raw sightings by collapsing sightings closer
# together than _ADV_BURST_MS: 1.96 raw sightings arrive per event, so not
# collapsing overstates the rate about twofold. The duplicate is a second
# REPORT of one reception under active scanning -- the ADV_IND and its
# scan-response -- and NOT the same event heard on several channels: a scanner
# dwells on one primary channel per scan interval and cannot receive one
# event's transmissions on two of them. The burst-size distribution says so
# outright (1: 92, 2: 2056, 4: 1 -- not a single burst of three), and two
# line-smoke-1 trials duplicate not at all, which channel physics could not
# produce. The threshold is not delicate: capture moves 83.7% -> 82.4% between
# 20 ms and 50 ms, and the gap histogram's valley over (20, 100] holds 5.6% of
# gaps.
#
# The interval is a controller setting and so does not vary with range -- what
# range changes is how much of it a scanner captures. That is what makes it
# sound to carry this constant into the field distances.
_ADV_EVENT_MS = 135.0
_ADV_BURST_MS = 20.0
# One advertising event on the air. This is an ASSUMPTION with bounds, not a
# measurement -- nothing in the trace weighs a PDU.
#
# The floor is the broadcast alone: this app advertises a 128-bit service UUID
# with the device name off (the plugin sets includeDeviceName false), so
# AdvData is flags(3) + UUID TLV(18) = 21 B and the legacy PDU is preamble(1) +
# access address(4) + header(2) + AdvA(6) + 21 + CRC(3) = 37 B, i.e. 111 B
# across three channels. The ceiling adds the SCAN_REQ/SCAN_RSP exchange that
# active scanning provokes (+22 +16 B per captured event per scanner), which
# the burst-of-two above proves is happening: ~149 B. 132 B sits between them.
#
# NOT the convention WireLedger uses: that counts Grassroots-envelope bytes
# only, with no PHY framing, so the advertisement band and the ledger bands are
# measured differently and the advertisement share is inflated relative to a
# like-for-like count. The conclusion that advertisements dominate survives it
# (their share is 90.7-96.2% across the sweep), but the share itself is
# convention-dependent and should be quoted as such.
_ADV_ON_AIR_B = 132
# ANNOUNCE is a fixed 182 B on every one of the 756 ledger buckets that carry
# one -- zero variance -- so a count is a byte figure.
_ANNOUNCE_B = 182
# One sync FRAME on the air, calibrated by regressing wire-bucket
# `secure:sync` bytes against the frames the per-round `sync` records place
# in the same bucket (720 buckets carrying both; ratio-of-sums, r=0.707).
# Needed because frames are the one class with per-event timestamps but no
# per-event size: a frame is a GCS filter whose size tracks how many ids it
# names, hence the spread (per-bucket 118-229 B, median 183). The
# bytes-weighted average is the right constant for pricing frame counts.
_SYNC_FRAME_B = 161


_STAGE_RUNGS = ("adv", "ann", "hs", "settle", "ack")
_STAGE_LAYERS = [("adv", "advertisements → GATT", _TH_C1),
                 ("ann", "ANNOUNCE → identity", _TH_C2),
                 ("hs", "handshake → session", _TH_C3),
                 ("settle", "sync → settled", "#9aa0a6"),
                 ("ack", "data → first e2e ACK", "#5b7fa6")]


def _stage_cost_rows(df: pd.DataFrame) -> pd.DataFrame:
    """Per-DEVICE-TRIAL rung numerators/denominators plus the trial's own
    measured link budget, for the cost-per-success figures.

    One row per device-trial. Columns: `d`, `trial` (the step label, the
    resampling unit -- the pair's two rows are one radio event, their
    time-to-GATT correlates at r=0.99, so bootstraps must resample TRIALS),
    `rssi` (the trial's median advertisement RSSI, shared by both rows: the
    two scanners measure the same channel, and the window is capped at the
    EARLIER of the two devices' GATT connect times -- past that point
    advertisements keep arriving and pooling them would fold the outcome
    into the variable meant to explain it; a trial where neither device
    connects keeps its whole window, which is already all pre-connection),
    `<rung>_num`/`<rung>_ok` per rung, and the trial-level data-plane fields
    `dp_bytes`/`dp_acked`/`dp_sent` (carried on the trial's first row only,
    zero on the second, so a group sum never double-counts them).

    Rung mechanisms (each interval charged only its own class -- the
    stop-counting rule: advertisements continue after GATT but no longer
    buy establishment):

      adv     ADV -> GATT: elapsed x 7.41 Hz x 132 B, a failed trial
              contributing its whole dwell
      ann     GATT -> identified: ANNOUNCEs received x 182 B (none are
              lost -- TX=RX at every distance; ANNOUNCE rides the link)
      hs      identified -> session: the ledger's handshake bytes over the
              whole trial, glare included (both sides initiate in 99/99
              trials -- 4 packets per pair for a 3-message handshake)
      settle  session -> settled: sync frames x 161 B until `link-settled`
      ack     settled -> first end-to-end ACK: sends + ACKs at the trial's
              own average ledger sizes, plus sync frames
    """
    segs = _distance_segments(df)
    lk = df[df._type == "link"].copy()
    if not segs or lk.empty:
        return pd.DataFrame()
    lk["dev8"] = lk._device.astype(str).str[:8]
    mk = df[df._type == "marker"].copy()
    mk["dev8"] = mk._device.astype(str).str[:8]
    msg = df[df._type == "message"].copy()
    msg["dev8"] = msg._device.astype(str).str[:8]
    sy = df[df._type == "sync"].copy()
    if not sy.empty:
        sy["dev8"] = sy._device.astype(str).str[:8]
    wire = df[df._type == "wire"].copy()
    wire["dev8"] = wire._device.astype(str).str[:8]
    rs = df[(df._type == "rssi") & (df.get("src") == "adv")]
    adv_per_s = 1000.0 / _ADV_EVENT_MS

    rows: list[dict] = []
    for seg in segs:
        a = seg["t0_dwell"] if seg["t0_dwell"] is not None else seg["t0"]
        b = seg["t1"]
        if a is None or b is None:
            continue
        bd = seg["t1_drain"] if seg.get("t1_drain") is not None else b
        # Price RSSI only up to the earliest GATT connect in the trial: a
        # link that forms keeps hearing advertisements (161/198 successful
        # device-trials have post-GATT sightings, median 108 of them), and
        # folding those into the median used to explain WHY establishment
        # succeeded would be circular. A trial where neither device ever
        # connects has no such boundary, so it keeps the whole [a, b) --
        # already entirely pre-connection by definition.
        gatt_times = []
        for dev in lk.dev8.unique():
            s = lk[(lk.dev8 == dev) & (lk._t >= a) & (lk._t < b)
                   & (lk.event == "gattConnected")]._t
            if len(s):
                gatt_times.append(float(s.min()))
        rssi_end = min(gatt_times) if gatt_times else b
        trial_rssi = float(rs[(rs._t >= a) & (rs._t < rssi_end)].rssi.median())
        dp_b = 0
        for _, x in wire[(wire._t >= a) & (wire._t < bd)].iterrows():
            tb = _dict(x.get("txBytes"))
            dp_b += (int(tb.get("secure", 0)) + int(tb.get("secure:ack", 0))
                     + int(tb.get("secure:sync", 0)))
        m_all = msg[(msg._t >= a) & (msg._t < bd)]
        dp_a = int((m_all.dir == "ackRx").sum())
        dp_s = int((m_all.dir == "sent").sum())

        first_row = True
        for dev in sorted(lk.dev8.unique()):
            g = lk[(lk.dev8 == dev) & (lk._t >= a) & (lk._t < b)]

            def _first(ev: str) -> float:
                s = g[g.event == ev]._t
                return float(s.min()) if len(s) else float("nan")

            t_gatt, t_id = _first("gattConnected"), _first("identified")
            t_ses = _first("session")
            st = mk[(mk.dev8 == dev) & (mk.label == "link-settled")
                    & (mk._t >= a) & (mk._t < b)]._t
            t_set = float(st.min()) if len(st) else float("nan")
            ak = msg[(msg.dev8 == dev) & (msg.dir == "ackRx")
                     & (msg._t >= a) & (msg._t < bd)]._t
            t_ack = float(ak.min()) if len(ak) else float("nan")

            r = dict.fromkeys(
                [f"{k}_num" for k in _STAGE_RUNGS]
                + [f"{k}_ok" for k in _STAGE_RUNGS], 0.0)
            r.update(d=float(seg["d"]), trial=seg["label"],
                     rssi=trial_rssi,
                     dp_bytes=dp_b if first_row else 0,
                     dp_acked=dp_a if first_row else 0,
                     dp_sent=dp_s if first_row else 0)
            first_row = False

            end = t_gatt if not math.isnan(t_gatt) else b
            r["adv_num"] = (end - a) / 1000 * adv_per_s * _ADV_ON_AIR_B
            r["adv_ok"] = 0 if math.isnan(t_gatt) else 1

            if not math.isnan(t_id):
                n_ann = max(int(((g.event == "identified")
                                 & (g._t <= t_id)).sum()), 1)
                r["ann_num"] = n_ann * _ANNOUNCE_B
                r["ann_ok"] = 1

            hsb = 0
            for _, x in wire[(wire.dev8 == dev) & (wire._t >= a)
                             & (wire._t < b)].iterrows():
                hsb += int(_dict(x.get("txBytes")).get("handshake", 0))
            r["hs_num"] = hsb
            r["hs_ok"] = 0 if math.isnan(t_ses) else 1

            if not math.isnan(t_ses) and not sy.empty:
                hi = t_set if not math.isnan(t_set) else b
                fr = sy[(sy.dev8 == dev) & (sy._t >= t_ses)
                        & (sy._t < hi)].frames.sum()
                r["settle_num"] = float(fr) * _SYNC_FRAME_B
            r["settle_ok"] = 0 if math.isnan(t_set) else 1

            if not math.isnan(t_set):
                lo, hi = t_set, (t_ack if not math.isnan(t_ack) else bd)
                mm = msg[(msg.dev8 == dev) & (msg._t >= lo) & (msg._t < hi)]
                n_sent = int((mm.dir == "sent").sum())
                n_ack_tx = int((mm.dir == "ackTx").sum())
                fr = 0.0
                if not sy.empty:
                    fr = float(sy[(sy.dev8 == dev) & (sy._t >= lo)
                                  & (sy._t < hi)].frames.sum())
                sb = sp = ab_ = ap = 0
                for _, x in wire[(wire.dev8 == dev) & (wire._t >= a)
                                 & (wire._t < bd)].iterrows():
                    tb = _dict(x.get("txBytes"))
                    tp = _dict(x.get("txPackets"))
                    sb += int(tb.get("secure", 0))
                    sp += int(tp.get("secure", 0))
                    ab_ += int(tb.get("secure:ack", 0))
                    ap += int(tp.get("secure:ack", 0))
                sec_b = sb / sp if sp else 0.0
                ack_b = ab_ / ap if ap else 0.0
                r["ack_num"] = (n_sent * sec_b + n_ack_tx * ack_b
                                + fr * _SYNC_FRAME_B)
            r["ack_ok"] = 0 if math.isnan(t_ack) else 1
            rows.append(r)
    return pd.DataFrame(rows)


def _stage_bytes_stats(t: pd.DataFrame, key: str,
                       n_boot: int = 3000) -> dict | None:
    """Per-group cost statistics for the bytes-on-air figures.

    Each rung is `sum(num) / sum(ok)` within the group -- all bytes aired,
    failures included, divided by successes: the cost of a GUARANTEED
    outcome. The whisker on each stacked bar is a bootstrap 95% CI on the
    TOTAL, resampling TRIALS (the pair's two rows move together -- their
    establishment correlates at r=0.99, so resampling device-trials would
    understate the interval by ~sqrt(2)). `bpa`/`dp_*` price the data
    plane the same way: all data/ACK/sync bytes divided by messages
    acknowledged end to end, same trial-level bootstrap. Split from the
    drawing so the distance and RSSI variants can share y-scales, which
    needs both sides' statistics before either panel is drawn.
    """
    groups = sorted(t[key].dropna().unique())
    if len(groups) < 2:
        return None
    rng = np.random.default_rng(7)

    def _totals(sub: pd.DataFrame) -> tuple[list[float], float, float]:
        vals = [sub[f"{k}_num"].sum() / max(sub[f"{k}_ok"].sum(), 1)
                for k in _STAGE_RUNGS]
        dpa = sub.dp_bytes.sum() / max(sub.dp_acked.sum(), 1)
        return vals, sum(vals), dpa

    bars, totals, bpa = [], [], []
    ci_lo, ci_hi, dp_lo, dp_hi, oks, ns = [], [], [], [], [], []
    for gv in groups:
        sub = t[t[key] == gv]
        vals, tot, dpa = _totals(sub)
        bars.append(vals)
        totals.append(tot)
        bpa.append(dpa)
        oks.append(int(sub.adv_ok.sum()))
        ns.append(len(sub))
        tr = sub.trial.unique()
        bt, bdp = [], []
        for _ in range(n_boot):
            pick = tr[rng.integers(0, len(tr), len(tr))]
            s = pd.concat([sub[sub.trial == p] for p in pick])
            if s.adv_ok.sum() == 0:
                continue
            _, tt, dd_ = _totals(s)
            bt.append(tt)
            bdp.append(dd_)
        ci_lo.append(np.percentile(bt, 2.5))
        ci_hi.append(np.percentile(bt, 97.5))
        dp_lo.append(np.percentile(bdp, 2.5))
        dp_hi.append(np.percentile(bdp, 97.5))
    return dict(groups=groups, bars=bars, totals=totals, bpa=bpa,
                ci_lo=ci_lo, ci_hi=ci_hi, dp_lo=dp_lo, dp_hi=dp_hi,
                oks=oks, ns=ns)


def _draw_stage_bytes_bar(st: dict, labels: list[str], xlabel: str,
                          out: Path, ylim: tuple, right: bool) -> None:
    """One stacked-bar panel of the pair. `right` strips the y furniture
    and the legend (the distance panel carries both) and flips the x so
    strong signal sits left, matching every other RSSI axis.

    Bars sit at EQUAL spacing with one tick each, whether or not the
    groups are equidistant in their own unit: the RSSI bins have a hole
    where a thin bin folded away, and placing bars at their true dBm
    positions left a bar-wide gap that read as a measurement rather than
    as bookkeeping.
    """
    x = np.arange(len(st["groups"]))
    fig, ax = plt.subplots(figsize=(3.5, 3.0))
    bottom = np.zeros(len(x))
    for i, (kk, lab, col) in enumerate(_STAGE_LAYERS):
        v = np.array([b[i] / 1000 for b in st["bars"]])
        ax.bar(x, v, .66, bottom=bottom, color=col, label=lab)
        bottom = bottom + v
    totals = np.array(st["totals"])
    ax.errorbar(x, totals / 1000,
                yerr=[(totals - np.array(st["ci_lo"])) / 1000,
                      (np.array(st["ci_hi"]) - totals) / 1000],
                fmt="none", ecolor="#444444", elinewidth=1.0, capsize=2.5)
    for i in range(len(x)):
        if st["oks"][i] < st["ns"][i]:
            ax.annotate(f'{st["oks"][i]}/{st["ns"][i]}',
                        (x[i], st["ci_hi"][i] / 1000),
                        textcoords="offset points", xytext=(0, 3),
                        ha="center", fontsize=6.5, color="#666666")
    ax.set_ylim(*ylim)
    ax.set_xticks(x)
    ax.set_xticklabels(labels)
    ax.set_xlabel(xlabel)
    if right:
        ax.tick_params(left=False, labelleft=False)
        ax.invert_xaxis()
    else:
        ax.set_ylabel("bytes on air per success (kB)")
        ax.legend(frameon=False, fontsize=6.6, ncol=1, loc="upper left")
    ax.grid(axis="y", alpha=.25)
    fig.subplots_adjust(**_TH_PAIR_MARGINS)
    _th_save(fig, out, tight=False)


def _draw_stage_bytes_perack(st: dict, labels: list[str], xlabel: str,
                             out: Path, ylim: tuple, right: bool) -> None:
    """One data-plane panel of the per-ACKed-message pair. Axis handling
    as in [_draw_stage_bytes_bar]."""
    x = np.arange(len(st["groups"]))
    fig, ax = plt.subplots(figsize=(3.5, 3.0))
    bpa = np.array(st["bpa"])
    ax.errorbar(x, bpa,
                yerr=[bpa - np.array(st["dp_lo"]),
                      np.array(st["dp_hi"]) - bpa],
                fmt="-o", color=_TH_C1, lw=1.6, ms=4, ecolor="#888888",
                elinewidth=1.0, capsize=2.5)
    # Every other tick when they crowd, phased to keep the sweep's LAST
    # group labelled; the RSSI side's seven fit whole.
    stride = 2 if len(x) > 8 else 1
    start = (len(x) - 1) % stride
    ax.set_xticks(x[start::stride])
    ax.set_xticklabels([labels[i] for i in range(start, len(x), stride)])
    ax.set_xlabel(xlabel)
    ax.set_ylim(*ylim)
    if right:
        ax.tick_params(left=False, labelleft=False)
        ax.invert_xaxis()
    else:
        ax.set_ylabel("bytes per ACKed message")
    ax.grid(axis="y", alpha=.25)
    fig.subplots_adjust(**_TH_PAIR_MARGINS)
    _th_save(fig, out, tight=False)


def _th_stage_bytes_pair(df: pd.DataFrame, out: Path) -> None:
    """The bytes-on-air figures: distance and RSSI variants of the stacked
    control-plane bars and of the data-plane cost line, each pair on one
    shared y-scale with the distance panel carrying the y furniture.

    Distance is the experiment's procedure axis but a noisy proxy for the
    link budget that actually drives cost (180 m measured 2 dB stronger
    than 140/160 on the day and its bar dips accordingly), and at n=10
    trials per distance the per-bar CI spans +/-15-35%, so adjacent bars
    are not individually ordered. Binning by the trial's own median
    advertisement RSSI (3 dB) pools the ~99 independent trials across the
    whole sweep, and site effects that stutter the distance version land
    in their correct bin. RSSI bars are labelled by the bin's lower edge;
    the caption states the width. Dial attempts (5 -> 13 across the
    sweep) have no byte record at all -- link-layer, below the envelope.
    """
    t = _stage_cost_rows(df)
    if t.empty:
        return
    ds = sorted(t.d.unique())
    st_d = _stage_bytes_stats(t, "d")
    tr = t[t.rssi.notna()].copy()
    tr["bin"] = (tr.rssi // 3) * 3
    # A bin needs enough trials to bootstrap; fold a thin edge bin into
    # its neighbour rather than drawing a bar whose CI is fiction.
    counts = tr.groupby("bin").trial.nunique()
    thin = counts[counts < 4].index
    for b in thin:
        neigh = counts.drop(index=b)
        if neigh.empty:
            continue
        target = neigh.index[np.argmin(np.abs(neigh.index - b))]
        tr.loc[tr.bin == b, "bin"] = target
        counts = tr.groupby("bin").trial.nunique()
    st_r = _stage_bytes_stats(tr, "bin")
    if st_d is None or st_r is None:
        return
    # Headroom is for the success-count annotation just above the tallest
    # whisker, nothing more -- a larger factor is dead panel.
    bar_ylim = (0.0, max(max(st_d["ci_hi"]), max(st_r["ci_hi"])) / 1000 * 1.1)
    # The data-plane cost lives at ~370-650 B: zero-anchoring parks the
    # whole line in the top half of the panel. Fit to the whisker range.
    pa_lo = min(min(st_d["dp_lo"]), min(st_r["dp_lo"]))
    pa_hi = max(max(st_d["dp_hi"]), max(st_r["dp_hi"]))
    pad = (pa_hi - pa_lo) * .08
    pa_ylim = (pa_lo - pad, pa_hi + pad)
    lab_d = [f"{int(dd)}" for dd in ds]
    # Bin lower edges with a typographic minus, so the labels match the
    # continuous RSSI axes elsewhere instead of reading as bare positives.
    lab_r = [f"−{abs(int(b))}" for b in sorted(tr.bin.unique())]
    _draw_stage_bytes_bar(st_d, lab_d, "distance (m)",
                          out / "line200_stage_bytes.pdf",
                          bar_ylim, right=False)
    _draw_stage_bytes_bar(st_r, lab_r, "advertisement RSSI (dBm)",
                          out / "line200_stage_bytes_rssi.pdf",
                          bar_ylim, right=True)
    _draw_stage_bytes_perack(st_d, lab_d, "distance (m)",
                             out / "line200_stage_bytes_perack.pdf",
                             pa_ylim, right=False)
    _draw_stage_bytes_perack(st_r, lab_r, "advertisement RSSI (dBm)",
                             out / "line200_stage_bytes_rssi_perack.pdf",
                             pa_ylim, right=True)


def _th_trial_rssi(df: pd.DataFrame) -> list[tuple[float, float, float]]:
    """(establishment seconds, trial median advertisement RSSI, distance).

    One row per DEVICE-TRIAL. The RSSI is the median over the advertisement
    sightings of BOTH ends of the pair in that trial, not the one phone's
    own -- the two sample the same channel at the same marks (own vs pooled
    r=0.982, median difference 0.0 dB), so the pooled median is the pair's
    link budget, and it is defined for the device-trials the one-sided
    median cannot cover: a device the peer dials before its own scanner
    fires logs NO sightings, and those trials are the FAST establishments
    (median 4.17 s against 5.72 s for the rest). Binning by own-sightings
    silently dropped exactly them -- 25 of 198 -- biasing every bin slow.
    Pooling matches [_stage_cost_rows], which prices the same trials.
    Anchoring follows [_th_ladder] exactly: the trial's own `bt-on`,
    bounded at `run-end`.
    """
    per: dict[str, list] = defaultdict(list)
    for _, r in df.iterrows():
        t, typ = r.get("_t"), r.get("_type")
        if pd.isna(t):
            continue
        dev = str(r.get("_device", ""))[:8]
        lab = r.get("label") if isinstance(r.get("label"), str) else None
        ev = r.get("event") if isinstance(r.get("event"), str) else None
        if typ == "marker" and lab and lab.startswith("d="):
            per[dev].append((t, "STEP", lab, None))
        elif typ == "marker" and lab == "bt-on":
            per[dev].append((t, "BTON", None, None))
        elif typ == "marker" and lab == "run-end":
            per[dev].append((t, "RUNEND", None, None))
        elif typ == "link" and ev == "session":
            per[dev].append((t, "session", None, None))
        elif typ == "rssi" and r.get("src") == "adv":
            per[dev].append((t, "adv", None, r.get("rssi")))
    # First pass: one record per device-trial carrying its OWN sightings.
    # No median yet -- pooling needs every end's list for a trial together.
    recs: list[dict] = []
    for dev, ev in per.items():
        ev.sort(key=lambda x: x[0])
        step = bton = runend = sess = sess_bton = None
        ordn = -1
        advs: list[float] = []

        def flush():
            if not step:
                return
            # A device-trial that never made a session is kept, with
            # est=None: it has no time to plot, but it HAS a measured link
            # budget, and dropping it silently thinned exactly the bins
            # that produced failures. The figure discloses it as k/n.
            ok = sess is not None and sess_bton is not None
            recs.append(dict(ordn=ordn, lab=step,
                             est=((sess - sess_bton) / 1000.0) if ok
                             else None,
                             advs=list(advs)))

        for t, k, lab, v in ev:
            if k == "STEP":
                flush()
                step, bton, runend, sess, sess_bton = lab, None, None, None, None
                ordn += 1
                advs = []
            elif k == "BTON":
                bton = t
            elif k == "RUNEND":
                runend = t
            elif k == "session" and sess is None and bton is not None:
                # FREEZE the anchor at the bt-on in force when the session
                # fired, exactly as [_th_ladder] does. Reading `bton` at
                # flush time instead takes whatever bt-on came LAST, and the
                # operator's stack reset for the walk fires one after
                # `run-end` -- so the session then looks earlier than its own
                # anchor and the trial is discarded. It cost 18 of 198
                # trials, every one a `t10`, silently shrinking the
                # population of every figure fed from here.
                sess = t
                sess_bton = bton
            elif (k == "adv" and bton is not None and v is not None
                  and (runend is None or t <= runend)):
                advs.append(float(v))
        flush()
    # Pool by trial: both devices walk the same schedule, so a trial is the
    # k-th step on each -- keyed with the label so a skipped marker on one
    # device degrades to that device pooling alone rather than pairing two
    # different marks.
    pooled: dict[tuple, list[float]] = defaultdict(list)
    for rec in recs:
        pooled[(rec["ordn"], rec["lab"])].extend(rec["advs"])
    out_rows: list[tuple[float, float, float]] = []
    for rec in recs:
        pool = pooled[(rec["ordn"], rec["lab"])]
        if not pool:
            continue
        d = float(re.match(r"d=(\d+)", rec["lab"]).group(1))
        out_rows.append((rec["est"], float(np.median(pool)), d))
    return out_rows


def _est_rssi_bins(df: pd.DataFrame, width: int = 3):
    """(bin centres, per-bin establishment times) for the RSSI view, or
    None. A bin's key is its centre, directly usable as the plot x.

    Fixed-width bins, NOT equal-count deciles: the pooled per-trial RSSI
    medians quantize to 0.5 dB and tie in blocks of 20-30 trials at one
    value, so cutting sorted runs of ten produces merged mega-bins where
    the ties sit and ragged spacing everywhere else. With tie-heavy
    quantized data, holding the dB window fixed and disclosing each bin's
    population is the readable arrangement; holding the population fixed
    is not achievable in the first place.

    The known cost of width is dilution of the extreme: the slow 140 m
    trials spread over several bins and pool with faster same-budget
    trials, so this band's top sits BELOW the distance panel's. That is
    regrouping arithmetic, not the panels disagreeing -- a group quantile
    is high only where slow trials concentrate, and they concentrate by
    position (the refused stale-address dials), not by link budget.

    A trial lands on the NEAREST multiple of the width (half-values
    toward zero: -74.5 -> -74), so the key is the bin's centre, never a
    floor edge -- floor files -74.5 under -75.

    Split out so the y-range can be computed WITHOUT drawing: the distance
    and RSSI establishment panels are set side by side and must share a
    scale, which the caller can only arrange by knowing both ranges first.
    """
    rows = _th_trial_rssi(df)
    if len(rows) < 30:
        return None
    bins: dict[int, list[float]] = defaultdict(list)
    tot: dict[int, int] = defaultdict(int)
    for est, rssi, _d in rows:
        k = width * int(np.floor(rssi / width + 0.5))
        tot[k] += 1
        # A failed device-trial (est None) has no time to plot, but it
        # COUNTS: it belongs to this bin's population and the figure
        # discloses it as k/n rather than letting the bin quietly shrink.
        if est is not None:
            bins[k].append(est)
    # No trial is dropped. A bin under 4 trials is FOLDED into its nearest
    # neighbour, as [_th_stage_bytes_pair] does: a 2-trial bin mid-curve
    # put a 13 s median spike between two 16-trial neighbours at 6 s --
    # the line swings through it and invents a resonance two samples wide.
    while True:
        thin = [k for k in sorted(tot) if tot[k] < 4]
        if not thin or len(tot) <= 1:
            break
        k = thin[0]
        neigh = [j for j in tot if j != k]
        tgt = min(neigh, key=lambda j: abs(j - k))
        bins[tgt].extend(bins.pop(k, []))
        tot[tgt] += tot.pop(k)
    ks = [k for k in sorted(tot) if bins.get(k)]
    return (ks, bins, tot) if len(ks) >= 3 else None


def _est_band_range(series: list[list[float]]) -> tuple[float, float]:
    """IQR-band extent over several groups -- the bound both establishment
    panels are scaled to, so neither is scaled to its own extremes."""
    q1 = min(float(np.percentile(v, 25)) for v in series if len(v))
    q3 = max(float(np.percentile(v, 75)) for v in series if len(v))
    return q1, q3


def _est_shared_ylim(byd: dict, df: pd.DataFrame) -> tuple[float, float] | None:
    """The y-limits both establishment figures should use: the union of
    what each panel's own IQR band needs, padded once."""
    dist = [byd[d]["session"] for d in byd if byd[d].get("session")]
    rb = _est_rssi_bins(df)
    if not dist or rb is None:
        return None
    ks, bins, _tot = rb
    lo1, hi1 = _est_band_range(dist)
    lo2, hi2 = _est_band_range([bins[k] for k in ks])
    lo, hi = min(lo1, lo2), max(hi1, hi2)
    pad = max((hi - lo) * .12, .2)
    # Extra top room: the RSSI panel writes its per-bin counts above the
    # median, and a shared limit has to clear them on both panels.
    return max(0.0, lo - pad), hi + pad * 2.0


def _th_establishment_vs_rssi(df: pd.DataFrame, out: Path,
                              ylim: tuple | None = None,
                              width: int = 3) -> None:
    """Cold establishment against the trial's own measured link budget.

    The per-distance view cannot separate a threshold from the walk that
    produced it, because a mark's ten trials span only 2-4 dB. Binning by
    the trial's own RSSI pools marks that shared a link budget -- 140, 160,
    180 and 200 m all land in the same bin -- which is what lets the
    threshold be stated in dBm rather than in metres.

    Pass `ylim` (from [_est_shared_ylim]) when setting this beside
    [_th_establishment]: two panels of the same quantity at different
    scales invite exactly the misreading the pairing exists to prevent.
    """
    rb = _est_rssi_bins(df, width=width)
    if rb is None:
        return
    ks, bins, tot = rb
    # Matches [_th_establishment]'s shape: the two are meant to be set
    # two-up as subfigures of one figure.
    fig, ax = plt.subplots(figsize=(3.5, 3.0))
    cen = [float(k) for k in ks]  # an equal-count bin's key IS its centre
    med = [float(np.median(bins[k])) for k in ks]
    q1 = [float(np.percentile(bins[k], 25)) for k in ks]
    q3 = [float(np.percentile(bins[k], 75)) for k in ks]
    ax.fill_between(cen, q1, q3, color=_TH_C1, alpha=.20, zorder=3,
                    edgecolor=_TH_C1, linewidth=.9, label="IQR")
    ax.plot(cen, med, "-o", color=_TH_C1, lw=1.8, ms=5, zorder=4,
            label="median")
    # Sample size per bin. A bin holding device-trials that never made a
    # session shows established/population (e.g. 34/36) -- the failures
    # have no time to plot but they belong to the bin and must not thin it
    # silently. `n=` marks the thin ones, set BELOW the line so a narrow
    # band there reads as a small sample rather than as agreement.
    for x, y, k in zip(cen, med, ks):
        c = len(bins[k])
        thin = c < 5
        lab = (f"{c}/{tot[k]}" if tot[k] > c
               else (f"n={c}" if thin else f"{c}"))
        ax.annotate(lab, (x, y), textcoords="offset points",
                    xytext=(0, -13) if thin else (0, 9),
                    ha="center", fontsize=6.5, color="#666666")
    ax.set_xlabel(f"advertisement RSSI (dBm)")
    # Bound to the band as on the distance panel; the extra top room is for
    # the per-bin sample-count annotations riding above the median.
    if ylim is None:
        lo, hi = min(q1), max(q3)
        pad = max((hi - lo) * .12, .2)
        ylim = (max(0.0, lo - pad), hi + pad * 2.0)
    ax.set_ylim(*ylim)
    # No y furniture and no legend: this is the RIGHT panel of the
    # establishment pair, on a shared scale -- the distance panel carries
    # both. Tick positions stay so the gridlines align across the pair.
    ax.tick_params(left=False, labelleft=False)
    ax.grid(axis="y", alpha=.25)
    # Strong signal (less negative, e.g. -69) on the LEFT, weak (-90) on the
    # RIGHT -- continuous axis, so a numeric invert is the whole fix; no
    # data/sort logic above needs to change.
    ax.invert_xaxis()
    fig.subplots_adjust(**_TH_PAIR_MARGINS)
    _th_save(fig, out, tight=False)


def _th_latency_vs_rssi(line: pd.DataFrame, out: Path) -> None:
    """What a weak link costs the messages it does NOT drop.

    The delivery figure answers whether a message arrives; this one answers
    how long it took when it did, over the same 3 dB bins so the two read as
    a pair. Both the median and the p90 are drawn: the median is what the
    link does, the p90 is where the stalls live, and at this load they part
    company by two orders of magnitude. Log axis for that reason.

    One point per STEP, not per message: a step's messages share a link and
    a queue, so pooling them would count one stall a hundred times and put a
    binomial-tight interval around it.
    """
    if "rssi_conn_mean" not in line.columns or "rtt_median_ms" not in line.columns:
        return
    bins: dict[int, list[list[float]]] = defaultdict(lambda: [[], []])
    for _, r in line.iterrows():
        v, m = r.get("rssi_conn_mean"), r.get("rtt_median_ms")
        if pd.isna(v) or pd.isna(m):
            continue
        k = int(v // 3) * 3
        bins[k][0].append(float(m))
        p90 = r.get("rtt_p90_ms")
        if not pd.isna(p90):
            bins[k][1].append(float(p90))
    ks = sorted(k for k in bins if bins[k][0])
    if len(ks) < 3:
        return
    fig, ax = plt.subplots(figsize=(6.2, 3.4))
    cen = [k + 1.5 for k in ks]
    med = [float(np.median(bins[k][0])) for k in ks]
    q1 = [float(np.percentile(bins[k][0], 25)) for k in ks]
    q3 = [float(np.percentile(bins[k][0], 75)) for k in ks]
    ax.fill_between(cen, q1, q3, color=_TH_C1, alpha=.18, linewidth=0,
                    label="IQR of per-step medians")
    ax.plot(cen, med, "-o", color=_TH_C1, ms=5, lw=1.7, label="median RTT")
    p90 = [float(np.median(bins[k][1])) if bins[k][1] else np.nan for k in ks]
    ax.plot(cen, p90, "--s", color=_TH_C3, ms=4.5, lw=1.4, label="p90 RTT")
    for x, y, k in zip(cen, med, ks):
        ax.annotate(f"{len(bins[k][0])}", (x, y), textcoords="offset points",
                    xytext=(0, -12), ha="center", fontsize=6.5, color="#666666")
    ax.set_yscale("log")
    ax.set_xlabel("connection RSSI (dBm)")
    ax.set_ylabel("send $\\to$ ACK (ms)")
    ax.grid(alpha=.25, which="both")
    ax.legend(frameon=False, fontsize=8)
    ax.invert_xaxis()  # strong signal left, weak right
    _th_save(fig, out)


def _th_delivery_vs_rssi(line: pd.DataFrame, out: Path) -> None:
    """Top: connection RSSI per distance. Bottom: arrival per 3 dB bin with
    Wilson intervals --- the threshold, not a gradient."""
    if "rssi_conn_mean" not in line.columns:
        return
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(6.2, 4.4),
                                 gridspec_kw={"height_ratios": [1, 1.25]})
    g = line.groupby("d")["rssi_conn_mean"]
    a1.fill_between(g.median().index, g.quantile(.25), g.quantile(.75),
                    color=_TH_C1, alpha=.15)
    a1.plot(g.median().index, g.median().values, "-o", color=_TH_C1,
            ms=4, lw=1.5)
    a1.set_ylabel("conn. RSSI (dBm)")
    a1.set_xlabel("distance (m)")
    a1.set_xticks(sorted(line["d"].unique()))
    a1.grid(alpha=.25)
    bins: dict[int, list[float]] = defaultdict(lambda: [0.0, 0.0])
    for _, r in line.iterrows():
        v = r.get("rssi_conn_mean")
        if pd.isna(v) or pd.isna(r.get("msg_sent")):
            continue
        k = int(v // 3) * 3
        bins[k][0] += float(r["msg_sent"])
        bins[k][1] += float(r.get("msg_arrived") or 0)
    ks = sorted(bins)
    if not ks:
        plt.close(fig)
        return
    cen = [k + 1.5 for k in ks]
    # Arrivals are counted in the window they LAND in, so a delivery that
    # straddles a drain can be credited to a neighbouring bin and push a
    # bin's arrived past its sent. Cap the ratio at 1: the excess is window
    # bookkeeping, not >100% delivery, and a p above 1 puts a negative upper
    # error on the Wilson interval below.
    rate = [min(1.0, bins[k][1] / bins[k][0]) * 100 for k in ks]
    lo, hi = [], []
    for k in ks:
        n, z = bins[k][0], 1.96
        p = min(1.0, bins[k][1] / bins[k][0])
        den = 1 + z * z / n
        c = (p + z * z / (2 * n)) / den
        h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
        lo.append(max(0.0, p - max(0.0, c - h)) * 100)
        hi.append(max(0.0, min(1.0, c + h) - p) * 100)
    a2.errorbar(cen, rate, yerr=[lo, hi], fmt="o-", color=_TH_C1, ms=5,
                lw=1.5, capsize=3)
    for x, y, k in zip(cen, rate, ks):
        a2.annotate(f"{int(bins[k][0])}", (x, y), textcoords="offset points",
                    xytext=(0, 9), ha="center", fontsize=6.5, color="#666666")
    a2.set_xlabel("connection RSSI (dBm)")
    a2.set_ylabel("arrived (%)")
    a2.grid(alpha=.25)
    a2.invert_xaxis()  # strong signal left, weak right -- a1's axis is
                       # distance, not RSSI, and is untouched
    fig.tight_layout()
    _th_save(fig, out)

if __name__ == "__main__":
    sys.exit(main())
