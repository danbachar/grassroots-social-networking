#!/usr/bin/env python3
"""Session-establishment time vs mesh size, from a mesh-scale run itself.

No dedicated probe: the dilating clique IS the experiment. In the frontier
design, phone k cycles Bluetooth off/on through its own block — [repeat]
COLD joins against k-1 standing peers under full message load — then anneals
into the mesh. Every join yields one establishment sample per standing peer
at that N, and (with the hand-measured geometry saved under the same
experiment id) at a known pair distance. Older single-join recordings are
read too: a phone without `off n=` markers falls back to its one join.

Two anchors, because they answer different questions:

    join(peer) = t(session with peer) - t(bt-on)
    pair(peer) = t(session with peer) - t(first ANNOUNCE from peer)

`join` is the operational cost of entering a mesh of size N: it serializes
across peers, and that serialization IS the phenomenon, so the vs-N table
uses it. `pair` isolates one link's establishment from the queueing behind
it, which is the distance-attributable number — the vs-distance table uses
it, because bucketing serialized deltas by distance would confound distance
with arrival order.

    python3 establishment_time.py data/traces.db --exp mesh-30m
    python3 establishment_time.py data/traces.db --exp mesh-15m --exp mesh-30m

Several --exp values (one per spacing) produce the distance x N grid of
median establishment times. Sessions that never form inside the join block
are reported as missing pairs, not dropped: a peer the joiner cannot reach
is the finding, not noise.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sqlite3
import statistics
import sys

STEP_RE = re.compile(r"^n=(\d+)(?: t(\d+))?$")


def analyse_exp(conn, exp: str):
    like = f"exp_{exp}.jsonl%"
    rows = conn.execute(
        "SELECT device_id, type, t, body FROM records "
        "WHERE upload_id LIKE ? AND type IN ('marker', 'link') ORDER BY t",
        (like,),
    ).fetchall()
    if not rows:
        print(f"no records for experiment {exp!r}\n")
        return None

    # geometry (hand-measured pair distances), stored under the same id
    dist: dict[str, float] = {}
    g = conn.execute("SELECT pairs FROM geometry WHERE exp = ?", (exp,)).fetchone()
    if g:
        dist = {k: float(v) for k, v in json.loads(g[0]).items()}

    # A device armed more than once abandoned an arm (an abort, or a tap that
    # caught an earlier wall-clock boundary). Which arm counted is READ from
    # the terminators the runner already stamps: split the device's records at
    # its `placement` markers and keep the last block containing an `end`, or
    # the last block if none does. Keeping a BLOCK, not a floor, is what stops
    # a stray re-arm at the tail from deleting a run that completed.
    arms: dict[str, list[int]] = {}
    ends: dict[str, list[int]] = {}
    for dev, ty, t, b in rows:
        if ty != "marker":
            continue
        label = json.loads(b).get("label")
        if label == "placement":
            arms.setdefault(dev, []).append(t)
        elif label == "end":
            ends.setdefault(dev, []).append(t)
    windows: dict[str, tuple[int, float]] = {}
    for dev, ts in arms.items():
        if len(ts) < 2:
            continue
        ts = sorted(ts)
        chosen = len(ts) - 1
        for i, lo in enumerate(ts):
            hi = ts[i + 1] if i + 1 < len(ts) else math.inf
            if any(lo <= e < hi for e in ends.get(dev, [])):
                chosen = i
        windows[dev] = (ts[chosen],
                        ts[chosen + 1] if chosen + 1 < len(ts) else math.inf)
    if windows:
        before = len(rows)
        rows = [r for r in rows
                if r[0] not in windows
                or windows[r[0]][0] <= r[2] < windows[r[0]][1]]
        for dev, (lo, _) in windows.items():
            print(f"!! {dev[:8]} armed {len(arms[dev])}x; records outside the "
                  f"arm that counted are ignored (the abandoned arm stays in "
                  f"the trace)")
        print(f"!! {before - len(rows)} record(s) ignored in total")

    # device -> order, and pubkey -> order (device_id IS the pubkey hex)
    order: dict[str, int] = {}
    marks: dict[str, list] = {}
    sessions: dict[str, list] = {}
    discovered: dict[str, list] = {}
    for dev, ty, t, b in rows:
        j = json.loads(b)
        if ty == "marker":
            if isinstance(j.get("order"), int):
                order[dev] = j["order"]
            marks.setdefault(dev, []).append((t, j.get("label") or j.get("event") or ""))
        elif j.get("event") == "session" and j.get("peer"):
            sessions.setdefault(dev, []).append((t, j["peer"]))
        elif j.get("event") == "discovered" and j.get("peer"):
            discovered.setdefault(dev, []).append((t, j["peer"]))

    by_n: dict[int, list[float]] = {}
    by_d: dict[float, list[float]] = {}
    print(f"=== {exp} ===")
    dupes = {o for o in order.values() if list(order.values()).count(o) > 1}
    if dupes:
        print(f"!! {len(dupes)} join order(s) claimed by more than one device: "
              + ", ".join(f"#{o}" for o in sorted(dupes))
              + " — BOTH tables below are affected. The geometry rows "
                "collide, so a distance naming one of these numbers is "
                "attributed to whichever row owns it; and the join order IS "
                "the mesh size (N = the joiner's own order), so the duplicated "
                "number files its samples under the wrong N and reports the "
                "wrong count of peers that never formed.")
    print(f"{'join':>5} {'N':>3} {'peer':>5} {'dist':>7} {'join\u0394':>8} {'pair\u0394':>8}")
    def emit_join(dev, o, w0, blk_end, ms, tag=""):
        # bt-on is stamped by the transport-state transition itself (the
        # runner subscribes to the change, it does not poll), so the stamp is
        # exact: the transport cannot form a session before it reports
        # active. Anchor on the LAST bt-on preceding the first session in the
        # window — the radio-up the establishment actually followed. A clean
        # rep has exactly one bt-on, making this the only candidate; extra
        # transitions (operator fumbled the toggle, or Bluetooth came up
        # during placement) are REPORTED, never silently absorbed into the
        # deltas.
        ons = [t for t, l in ms if l == "bt-on" and w0 <= t < blk_end]
        if not ons:
            # A window with no radio-up measures nothing — and silence here
            # once hid an operator miss: a skipped TURN OFF left the links
            # warm, sessions re-formed seconds after the reset, and the rep
            # looked like it simply didn't exist. Say what happened.
            print(f"{'#' + str(o):>5} {o:>3} {tag:>5} no radio cycle in this "
                  f"window (TURN OFF/ON missed) — rep measures nothing")
            return
        n_after = o
        sess = [(t, p) for t, p in sessions.get(dev, []) if w0 <= t < blk_end]
        first_sess = min((t for t, _ in sess), default=None)
        pre = [t for t in ons if first_sess is None or t <= first_sess]
        bt_on = pre[-1] if pre else ons[-1]
        if len(ons) > 1:
            print(f"{'#' + str(o):>5} {n_after:>3} radio came up {len(ons)}x "
                  f"in this window — operator error, rep is suspect")
        formed = {}
        for t, peer in sess:
            if bt_on <= t < blk_end and peer not in formed:
                formed[peer] = t
        first_disc = {}
        for t, peer in discovered.get(dev, []):
            if bt_on <= t < blk_end and peer not in first_disc:
                first_disc[peer] = t
        standing = n_after - 1
        for peer, ts in sorted(formed.items(), key=lambda kv: kv[1]):
            join_d = (ts - bt_on) / 1000
            pair_d = ((ts - first_disc[peer]) / 1000
                      if peer in first_disc else None)
            po = order.get(peer)
            key = f"{min(o, po)}-{max(o, po)}" if po else None
            d = dist.get(key) if key else None
            print(f"{'#' + str(o):>5} {n_after:>3} "
                  f"{('#' + str(po)) if po else peer[:5]:>5} "
                  f"{(f'{d:.1f}m' if d is not None else '—'):>7} "
                  f"{join_d:>7.1f}s "
                  f"{(f'{pair_d:.1f}s' if pair_d is not None else '—'):>8}")
            by_n.setdefault(n_after, []).append(join_d)
            if d is not None and pair_d is not None:
                by_d.setdefault(round(d, 1), []).append(pair_d)
        if len(formed) < standing:
            print(f"{'#' + str(o):>5} {n_after:>3} {'—':>5} {'—':>7} "
                  f"{standing - len(formed)} of {standing} peers NEVER formed")

    for dev, o in sorted(order.items(), key=lambda kv: kv[1]):
        ms = marks.get(dev, [])
        # Rep windows. Frontier recordings: one window per `off n=<o>` marker,
        # running to the next off marker or the first later-block marker.
        # Single-join recordings (no off markers): one window at the first
        # n=<o> marker, as before.
        windows = []
        offs = [i for i, (_, l) in enumerate(ms) if l.startswith(f"off n={o} ")]
        if offs:
            for oi in offs:
                w0 = ms[oi][0]
                w1 = next((ms[j][0] for j in range(oi + 1, len(ms))
                           if ms[j][1].startswith(f"off n={o} ")
                           or ((m := STEP_RE.match(ms[j][1]))
                               and int(m.group(1)) != o)),
                          ms[-1][0] + 10 ** 9)
                windows.append((w0, w1, ms[oi][1].split()[-1]))
        else:
            # Joined-at-start vs joined-during-run is structural, not a time
            # window: the runner stamps the initial radio state at arm, so a
            # FOUNDING phone's first radio stamp is bt-on (it was up all
            # along — no join to time) and a JOINER's is bt-off (the waiting
            # screen enforces KEEP BLUETOOTH OFF). For a joiner the window is
            # the whole recording up to the next block — its first bt-on ever
            # IS the join, wherever it lands, with no lookback constant.
            # Radio activity earlier than the schedule is operator error and
            # emit_join reports it.
            first_radio = next((l for _, l in ms if l in ("bt-on", "bt-off")),
                               None)
            first = next((t for t, l in ms
                          if (m := STEP_RE.match(l)) and int(m.group(1)) == o),
                         None)
            if first is not None and first_radio == "bt-off":
                w1 = next((t for t, l in ms
                           if (m := STEP_RE.match(l)) and int(m.group(1)) > o),
                          (ms[-1][0] if ms else first) + 10 ** 9)
                windows.append((0, w1, "join"))
        for w0, w1, tag in windows:
            emit_join(dev, o, w0, w1, ms, tag)

    def stats_table(title, buckets, label):
        print(f"\n{title}")
        print(f"{label:>7} {'pairs':>6} {'median':>8} {'p90':>8} {'max':>8}")
        for k in sorted(buckets):
            v = sorted(buckets[k])
            p90 = v[max(0, math.ceil(len(v) * 0.9) - 1)]
            print(f"{k:>7} {len(v):>6} {statistics.median(v):>7.1f}s "
                  f"{p90:>7.1f}s {v[-1]:>7.1f}s")

    if by_n:
        stats_table("join cost vs mesh size (bt-on -> session, serialized)",
                    by_n, "N")
    if by_d:
        stats_table(
            "pair establishment vs distance (discovered -> session)",
            by_d, "dist(m)")
    print()
    return {n: statistics.median(v) for n, v in by_n.items()}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("db")
    ap.add_argument("--exp", required=True, action="append",
                    help="experiment id; repeat for several spacings")
    a = ap.parse_args()
    conn = sqlite3.connect(a.db)
    combined = {}
    for exp in a.exp:
        curve = analyse_exp(conn, exp)
        if curve:
            combined[exp] = curve
    if len(combined) > 1:
        ns = sorted({n for c in combined.values() for n in c})
        print("median establishment time by experiment and mesh size")
        print(f"{'experiment':<20} " + " ".join(f"{'N=' + str(n):>8}" for n in ns))
        for exp, c in combined.items():
            print(f"{exp:<20} " + " ".join(
                f"{c[n]:>7.1f}s" if n in c else f"{'—':>8}" for n in ns))
    return 0


if __name__ == "__main__":
    sys.exit(main())
