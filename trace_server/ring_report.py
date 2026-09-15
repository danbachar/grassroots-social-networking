#!/usr/bin/env python3
"""Ring-radius run report: the checks the smoke runs turned out to need.

Deliberately separate from analyze.py. That one is the general trace analyser
and its output is a directory of tables; this answers the specific questions a
ring run exists to answer, and the ones that caught real defects on
2026-09-01 -- each of which was invisible in the aggregate tables and had to be
dug out by hand:

  * the gate      -- a forbidden pair must hold a link for 0.0 s inside r=1.
                     Only a trial that HAS a forbidden pair can test this, and
                     at N=4 half of them do not; those are reported as untested
                     rather than clean
  * conveyance    -- at r=1, distance-2 traffic must arrive RELAYED, and the
                     same pairs must go direct at r=2. That contrast IS the
                     experiment
  * lost messages -- separated into `sealed but never sent` (a write the stack
                     never answered, which used to destroy the packet outright)
                     and `sent but never arrived` (a conveyance shortfall).
                     They have nothing to do with each other and pooling them
                     hides both
  * the stall     -- conveyance decaying to zero after the dwell, and the
                     holder's own answer to the asker that went hungry. The
                     signal is `ownHeld` against `ownInWindow`: mail we hold
                     FOR the asker, and how much of it the ask reached. The
                     POOLED held/inWindow/withheld cannot say anything, because
                     a holder's buffer is mostly third-party transit and its
                     own delivered copies waiting on an ACK, and withholding
                     those is correct behaviour
  * pacing        -- send offsets within the announce quantum must be flat, or
                     the send schedule is aliased against the sync round

The ring is derived from the trace, never hard-coded: ring order IS the sorted
pubkey order, so the devices present in the run define it and this works
unchanged at N=4 and N=11. Four things can happen to it, and they are four
different faults, so they are reported apart: the fleet AGREES; a phone
CHANGED ring mid-run; phones DISAGREE with each other; a ring member NEVER
UPLOADED. Only the first is a clean run.

A DB routinely holds more than one run -- the collector suffixes the id, so a
repeat lands beside its predecessor -- while the segments come from ONE run's
analysis dir. Records are therefore scoped to that run's experiment, which is
what the analysis dir is named for.

    python3 ring_report.py <run.db> <analysis-dir-for-that-run>

RING_OVERRIDE=<comma-separated pubkeys> forces the ring when the trace carries
no usable stamp. Members are lowercased and cut to the 8-hex prefix the report
works in, so full pubkeys are fine; every device that uploaded must appear in
it, or the override is describing some other run and the report refuses to run.
"""
import json
import os
import re
import sqlite3
import sys
from collections import Counter, defaultdict

import pandas as pd

SHORT = 8


def short(h):
    return h[:SHORT] if h else h


def ring_distance(i, j, n):
    d = abs(i - j)
    return min(d, n - d)


def quantiles(xs):
    if not xs:
        return (float("nan"),) * 3
    s = sorted(xs)
    q = lambda p: s[min(int(len(s) * p), len(s) - 1)]
    return q(0.5), q(0.9), max(s)


def median(xs):
    s = sorted(xs)
    return s[len(s) // 2]


def exp_of(outdir):
    """The experiment name. analyze.py writes each run to <out>/<exp>, so the
    analysis dir this report is pointed at is named for exactly the run whose
    step segments it is about to read."""
    return os.path.basename(os.path.normpath(outdir))


def experiments_in(conn):
    """Every experiment with records in this DB, from the upload ids
    ("exp_<name>.jsonl:<len>[:<chunk>]")."""
    found = set()
    for (u,) in conn.execute("SELECT DISTINCT upload_id FROM records"):
        m = re.match(r"exp_(.+)\.jsonl", u or "")
        if m:
            found.add(m.group(1))
    return sorted(found)


def load(db, exp):
    """Records for ONE experiment.

    Unscoped, a DB holding a run and its repeat hands this report two fleets'
    markers at once -- which reads as phones disagreeing about the ring, voids
    a run that was fine, and doubles every count against segments that only
    cover one of them.
    """
    c = sqlite3.connect(db)
    like = f"exp_{exp}.jsonl%"
    rows = []
    for dev, ty, body in c.execute(
            "SELECT device_id, type, body FROM records "
            "WHERE upload_id LIKE ?", (like,)):
        r = json.loads(body)
        rows.append((short(dev), ty, r))
    uploads = list(c.execute(
        "SELECT upload_id, substr(device_id,1,8), COUNT(*) "
        "FROM records WHERE upload_id LIKE ? "
        "GROUP BY upload_id, device_id", (like,)))
    return rows, uploads, experiments_in(c)


def stamp_sequence(rows):
    """Per device, the rings it stamped on its markers, in order, collapsed to
    transitions. One entry is a device that held one ring all run; two or more
    is a device that changed ring mid-run -- a different fault from two devices
    that each held a ring but not the same one, and the reason this keeps the
    device attribution the old fleet-wide set threw away."""
    seq = defaultdict(list)
    for d, _, r in sorted((x for x in rows if x[1] == "marker"),
                          key=lambda x: x[2].get("t", 0)):
        ring = r.get("ring")
        if isinstance(ring, list) and ring:
            v = tuple(ring)
            if not seq[d] or seq[d][-1] != v:
                seq[d].append(v)
    return seq


def parse_override(raw, uploaders):
    """(ring, error) for RING_OVERRIDE. The hook exists for runs whose phones
    predate the marker stamp, where the alternative is a ring guessed from
    whoever uploaded -- but an override that does not describe THIS run is
    worse than the guess, because it looks authoritative. Full pubkeys are the
    obvious thing to paste, so cut them; then insist the ring accounts for
    every device in the trace, which is what an override for some other run
    fails."""
    members = [m.strip().lower()[:SHORT] for m in raw.split(",")]
    members = [m for m in members if m]
    bad = [m for m in members if not re.fullmatch(r"[0-9a-f]{%d}" % SHORT, m)]
    if bad:
        return None, f"members are not {SHORT}-hex prefixes: {', '.join(bad)}"
    dupes = [m for m, c in Counter(members).items() if c > 1]
    if dupes:
        return None, f"repeated members: {', '.join(dupes)}"
    if len(members) < 2:
        return None, "a ring needs at least two members"
    missing = sorted(uploaders - set(members))
    if missing:
        return None, (f"these devices uploaded to this run but are not in the "
                      f"override: {', '.join(missing)} — the override is not "
                      f"this run's ring")
    return sorted(members), None


def resolve_ring(rows, uploaders):
    """(ring, source, notes). Distinguishes the four things that happen to a
    ring, because they have four different fixes."""
    notes = []
    seq = stamp_sequence(rows)
    changed = {d: v for d, v in seq.items() if len(v) > 1}
    for d, v in sorted(changed.items()):
        notes.append(f"!! {d} CHANGED RING MID-RUN: "
                     + " then ".join(f"[{', '.join(x)}]" for x in v))
    finals = {d: v[-1] for d, v in seq.items()}
    variants = Counter(finals.values())

    if len(variants) == 1:
        ring = list(next(iter(variants)))
        src = "stamped on the markers"
        if changed:
            src += " (agreed at the end, but see the mid-run change above)"
        return ring, src, notes

    if variants:
        notes.append("!! PHONES DISAGREED ABOUT THE RING — the gate was "
                     "incoherent and this run is void:")
        for v, votes in sorted(variants.items(), key=lambda x: (-x[1], -len(x[0]))):
            who = ", ".join(sorted(d for d, f in finals.items() if f == v))
            notes.append(f"     {list(v)}  ({votes} phone(s): {who})")
        # NOT the sorted-first one. Python orders tuples prefix-first, so a
        # TRUNCATED ring -- the phone that launched one session short, which is
        # the exact failure the stamp exists to catch -- sorts ahead of the
        # correct longer ring and would be silently adopted, renumbering every
        # position. Take the ring the most phones enforced, and on a tie the
        # larger one: a ring that is a strict prefix of another is the
        # truncation, never the truth.
        ring = max(variants, key=lambda v: (variants[v], len(v)))
        notes.append(f"     -> reporting against the MODAL ring "
                     f"({variants[ring]} of {len(finals)} phones). Distances "
                     f"below are as the majority enforced them; the dissenting "
                     f"phones did not enforce them, so their rows are not "
                     f"evidence of anything.")
        return list(ring), "MODAL RING OF A DISAGREEING FLEET", notes

    raw = os.environ.get("RING_OVERRIDE")
    if raw:
        ring, err = parse_override(raw, uploaders)
        if err:
            notes.append(f"!! RING_OVERRIDE rejected: {err}")
            return None, "", notes
        return ring, "RING_OVERRIDE env var", notes

    return (sorted(uploaders),
            "!! GUESSED from uploading devices — no ring stamped. If any phone "
            "failed to upload, every distance below is WRONG",
            notes)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    db, outdir = sys.argv[1], sys.argv[2]
    exp = exp_of(outdir)
    rows, uploads, all_exps = load(db, exp)
    if not rows:
        print(f"NO RECORDS for experiment '{exp}' in {db}.")
        print(f"  the DB holds: {', '.join(all_exps) or '(nothing)'}")
        print("  the analysis dir must be the one analyze.py wrote for THIS "
              "run — its basename is the experiment name.")
        return 1
    steps = pd.read_csv(outdir + "/steps.csv")
    segs = [(str(r.label), int(r.t0), int(r.t1)) for r in steps.itertuples()]
    trials = [s for s in segs if s[0].startswith("r=")]
    if not trials:
        print("NO r= SEGMENTS -- this is not a ring run")
        return 1
    T0 = segs[0][1]
    rel = lambda t: (t - T0) / 1000

    def seg_of(t):
        for label, a, b in segs:
            if a <= t < b:
                return label
        return None

    # THE RING IS NOT "WHOEVER UPLOADED". Deriving it from the devices present
    # in the trace silently rewrites every ring distance when one phone fails
    # to upload -- and that is not hypothetical: it turned a 4-node run whose
    # 07e47335<->366dca50 pair was at distance 2 into a "3-node ring where
    # every pair is adjacent", which pooled 40 direct sub-0.2 s deliveries with
    # 7 relayed 43 s ones into a single meaningless row, reported correct gate
    # enforcement as a link fault, and made the gate check vacuous (at N=3 with
    # r in {1,2} no pair is ever forbidden, so it tested nothing).
    #
    # Prefer the ring each phone actually enforced, which the runner now stamps
    # on every marker. Fall back to an operator override, then -- loudly -- to
    # the uploading devices.
    uploaders = {d for d, _, _ in rows}
    ring, ring_src, notes = resolve_ring(rows, uploaders)
    for line in notes:
        print(line)
    if ring is None:
        return 1
    n = len(ring)
    idx = {h: i for i, h in enumerate(ring)}
    # A device may appear in the trace without being in the ring (a stray the
    # gate refused). It has no ring position, so it has no distance either.
    def rd(a, b):
        if a not in idx or b not in idx:
            return None
        return ring_distance(idx[a], idx[b], n)

    print(f"# {db}")
    print(f"experiment: {exp}")
    if len(all_exps) > 1:
        print(f"  (this DB also holds {', '.join(x for x in all_exps if x != exp)}"
              f"; their records are excluded)")
    print(f"ring (sorted pubkey order, N={n}): {' -> '.join(ring)} -> {ring[0]}")
    print(f"  ring source: {ring_src}")
    absent = sorted(set(ring) - uploaders)
    if absent:
        print(f"  !! IN THE RING BUT NEVER UPLOADED: {', '.join(absent)} — it "
              f"still occupies a ring position, so distances are unaffected, "
              f"but its side of every pair is missing from this report")
    stray = sorted(uploaders - set(ring))
    if stray:
        print(f"  !! UPLOADED BUT NOT IN THE RING: {', '.join(stray)} — no ring "
              f"position, so no distance; its traffic is excluded below")
    print(f"steps: {[s[0] for s in segs]}")
    print(f"recording ends t+{rel(max(r['t'] for _, _, r in rows)):.0f}s")

    # ---- completeness ------------------------------------------------------
    print("\n## uploads")
    for u, d, cnt in sorted(uploads, key=lambda x: (x[1], x[0])):
        print(f"  {d} {u.split(':',1)[-1]:>14s}  {cnt:6d} records")

    msgs = [(d, r) for d, ty, r in rows if ty == "message"]
    sealed = {r["messageId"]: (d, short(r["peer"]), r["t"], seg_of(r["t"]))
              for d, r in msgs if r["dir"] == "sealed"}
    sent = {r["messageId"] for _, r in msgs if r["dir"] == "sent"}
    recv = {}
    for d, r in msgs:
        if r["dir"] == "recv":
            recv.setdefault(r["messageId"],
                            (d, r["t"], r.get("relayHops") or 0,
                             r.get("deliveryMethod")))
    per_trial = Counter(g for _, _, _, g in sealed.values() if g)
    print(f"\n  sealed {len(sealed)}, sent {len(sent)}, received {len(recv)}")
    for label, _, _ in trials:
        print(f"    {label}: {per_trial[label]} sealed")

    # ---- the gate ----------------------------------------------------------
    # Link intervals per device, from that device's own link records. "Live at
    # any point in the segment" is the wrong test: the prune fires within
    # ~0.2 s of the step marker, so a forbidden pair legitimately exists for
    # the first fraction of a second. Duration inside the window is the test.
    live, ivs = defaultdict(dict), defaultdict(list)
    for d, ty, r in sorted((x for x in rows if x[1] == "link"),
                           key=lambda x: x[2]["t"]):
        ev, path = r.get("event"), r.get("path")
        if not path:
            continue
        if ev in ("connected", "identified"):
            cur = live[d].get(path)
            if cur is None:
                live[d][path] = [r["t"], short(r.get("peer"))]
            elif r.get("peer"):
                cur[1] = short(r.get("peer"))
        elif ev in ("drop", "ringPrune", "pruned", "duplicateLeg"):
            cur = live[d].pop(path, None)
            if cur:
                ivs[d].append((cur[0], r["t"],
                               cur[1] or short(r.get("peer"))))
    end = max(r["t"] for _, _, r in rows)
    for d, m in live.items():
        for _, (t0, p) in m.items():
            ivs[d].append((t0, end, p))

    def live_ms(dev, peer, a, b):
        got, cur = 0, a
        for s, e in sorted((max(t0, a), min(t1, b))
                           for t0, t1, q in ivs[dev] if q == peer
                           and t0 < b and t1 > a):
            if e > cur:
                got += e - max(s, cur)
                cur = e
        return got

    print("\n## gate — link-seconds per ordered pair inside each trial")
    # The greatest distance in an N-ring. A trial whose r reaches it forbids
    # nothing, so it cannot pass or fail the gate -- it simply does not test
    # it, and printing "clean" for those made half of every N=4 smoke run read
    # as evidence when it was silence.
    far = n // 2
    breaches, untested = 0, 0
    for label, a, b in trials:
        r = int(label.split("=")[1].split()[0])
        dur = b - a
        bad, down, forbidden = [], [], 0
        for u in ring:
            for v in ring:
                if u == v:
                    continue
                k, held = rd(u, v), live_ms(u, v, a, b)
                if k is None:
                    continue
                if k > r:
                    forbidden += 1
                    if held > 200:
                        bad.append(f"{u}->{v} d{k} live {held/1000:.1f}s")
                elif held < dur * 0.9:
                    down.append(f"{u}->{v} d{k} live {held/1000:.1f}s")
        breaches += len(bad)
        if not forbidden:
            untested += 1
            print(f"  {label}: GATE NOT TESTED — at N={n} the greatest ring "
                  f"distance is {far}, so r={r} forbids no pair. This trial "
                  f"says nothing about the gate either way")
        elif bad:
            print(f"  {label}: GATE BREACH: " + "; ".join(bad))
        else:
            worst = max(live_ms(u, v, a, b) for u in ring for v in ring
                        if u != v and rd(u, v) > r)
            print(f"  {label}: clean over {forbidden} forbidden ordered pairs "
                  f"— worst held {worst/1000:.3f}s (prune latency)")
        if down:
            print(f"      allowed but down: {'; '.join(down)}")
    if untested:
        print(f"  {untested} of {len(trials)} trials could not test the gate")
    print(f"  ringRadius dial refusals: "
          f"{sum(1 for _, ty, r in rows if ty == 'link' and r.get('event') == 'dialSkip' and r.get('reason') == 'ringRadius')}"
          f", ringPrune legs: "
          f"{sum(1 for _, ty, r in rows if ty == 'link' and r.get('event') == 'ringPrune')}")

    # ---- the experiment ----------------------------------------------------
    print("\n## delivery by ring distance  (THE result: d>r must be relayed)")
    hdr = (f"  {'trial':10s} {'d':>2s} {'sent':>5s} {'arr':>5s} {'arr%':>6s} "
           f"{'relayed':>8s} {'hops':>12s} {'p50':>8s} {'p90':>8s} {'max':>8s}")
    print("  ('sent' excludes sealed-but-never-sent; those are a wedged write, "
          "reported under losses)")
    print(hdr)
    for label, a, b in trials:
        tot, arr, relayed = Counter(), Counter(), Counter()
        lat, hops = defaultdict(list), defaultdict(Counter)
        for m, (s, g, ts, sg) in sealed.items():
            # BOTH ends must have a ring position. A sender outside the ring
            # has no distance to anything, and letting it through keyed a row
            # on None.
            if sg != label or s not in idx or g not in idx:
                continue
            # Denominator is what was actually SENT. A message that was sealed
            # and never sent is a wedged write, not a delivery failure, and
            # pooling the two turned a zero-loss trial into an 87.5% one.
            if m not in sent:
                continue
            k = rd(s, g)
            tot[k] += 1
            if m in recv:
                _, tr, h, _ = recv[m]
                arr[k] += 1
                lat[k].append((tr - ts) / 1000)
                hops[k][h] += 1
                if h > 0:
                    relayed[k] += 1
        for k in sorted(tot):
            p50, p90, mx = quantiles(lat[k])
            hs = ",".join(f"{h}:{c}" for h, c in sorted(hops[k].items()))
            print(f"  {label:10s} {k:2d} {tot[k]:5d} {arr[k]:5d} "
                  f"{arr[k]/tot[k]*100:5.1f}% {relayed[k]:8d} {hs:>12s} "
                  f"{p50:8.2f} {p90:8.2f} {mx:8.2f}")

    # ---- losses, split by mechanism ---------------------------------------
    hung = [(m, v) for m, v in sealed.items()
            if m not in sent and v[0] in idx and v[1] in idx]
    lost = [(m, v) for m, v in sealed.items()
            if m in sent and m not in recv and v[0] in idx and v[1] in idx]
    print(f"\n## losses")
    print(f"  sealed but NEVER sent: {len(hung)}   "
          f"<- a write the stack never answered; the packet used to be "
          f"destroyed outright. Any nonzero value here is a defect, not a "
          f"measurement.")
    if hung:
        byp = Counter(f"{v[0]}->{v[1]}" for _, v in hung)
        for pair, c in byp.most_common():
            first = min(v[2] for _, v in hung if f"{v[0]}->{v[1]}" == pair)
            print(f"      {pair}: {c}, first at t+{rel(first):.1f}s")
    print(f"  sent but never arrived: {len(lost)}  "
          f"<- conveyance shortfall")
    if lost:
        for pair, c in Counter(
                f"{v[0]}->{v[1]} d{rd(v[0], v[1])} ({v[3]})"
                for _, v in lost).most_common(12):
            print(f"      {pair}: {c}")

    # ---- the stall ---------------------------------------------------------
    print("\n## conveyance over time, and whether the buffers actually drain")
    conv = [(d, r) for d, ty, r in rows if ty == "custody"
            and r.get("event") == "convey"]
    for label, a, b in trials:
        nxt = min([x for _, x, _ in segs if x > b] + [end])
        bk = Counter()
        for _, r in conv:
            t = (r["t"] - a) / 1000
            if 0 <= t < (nxt - a) / 1000:
                bk[int(t // 20) * 20] += 1
        dwell = (b - a) / 1000
        print(f"  {label} (dwell {dwell:.0f}s, then drain to "
              f"t+{(nxt-a)/1000:.0f}s): "
              + " ".join(f"{k}s:{v}" for k, v in sorted(bk.items())))
    # DELIBERATELY NOT a "frozen buffer" check any more.
    #
    # An earlier version flagged a DTN buffer whose depth stopped moving
    # through the drain and called it a stall. It does not discriminate: on the
    # three ring runs on disk it fires on 36 of 44 device-trials (82%),
    # including every trial that delivered 100% of what it sent, so it says
    # nothing about a trial that a coin toss would not.
    #
    # The reason it fires that widely is worth keeping, because it is the shape
    # of the buffer: `dropFromDtnBuffer` is reached only from the ACK and
    # read-receipt paths in grassroots_network.dart, and a RELAY cannot decrypt
    # an ACK sealed to the original sender -- so a relayed third-party copy is
    # released by nothing but DtnStore.maxAge or byte eviction, and a plateau
    # is what correct relaying looks like. Depth does still fall: an ACK for
    # the node's OWN mail drops it, and the runner's per-step resetDtnBuffer
    # zeroes the store outright. Both are visible in every DB here, so "depth
    # only ever grows" is false and cannot be the argument.
    #
    # The honest signal is the holder-side `ownHeld`/`ownInWindow` pair below:
    # mail we hold FOR the asker that its ask never reached. Reported there.

    # ---- sync: asker reach and holder answers ------------------------------
    sync = [(d, r) for d, ty, r in rows if ty == "sync"]
    ask = [(d, r) for d, r in sync if r.get("event", "filter") == "filter"]
    ans = [(d, r) for d, r in sync if r.get("event") == "answer"]
    if ask:
        print(f"\n## sync — asker")
        print(f"  rounds {len(ask)}, median seenTotal "
              f"{median([r['seenTotal'] for _, r in ask])}, "
              f"max frames {max(r['frames'] for _, r in ask)}/10")
        # `pending` is not reported. It counted the seen ids a forward-walking
        # per-peer cursor had still to cover, so it measured cursor lag; the
        # newest-first prefix has no cursor and no backlog for one to fall
        # behind. The number is still in the trace and still means that for the
        # runs that predate the change, but it is not comparable across builds
        # and there is no reading of it that is true of both, so quoting one
        # figure for "reach" would be quoting two different quantities.
        print("  (pending is not reported: it measured per-peer cursor lag, "
              "which the newest-first prefix does not have. Not comparable "
              "across builds)")
    if not ans:
        print("\n## sync — holder: NO 'answer' records. This build predates "
              "the holder-side instrumentation.")
    elif not any("ownHeld" in r for _, r in ans):
        print(f"\n## sync — holder: {len(ans)} answers, but none carry the "
              f"own* fields. This build predates the split, and the pooled "
              f"held/inWindow/withheld counts it does carry cannot answer the "
              f"question: a holder's buffer is mostly third-party transit and "
              f"its own delivered copies awaiting an ACK, and withholding "
              f"those is correct. There is no stall figure for this run.")
    else:
        # Only mail addressed to the ASKER can tell us anything. `ownHeld > 0`
        # with `ownInWindow == 0` is the ask never reaching a packet we were
        # holding for the asker; `ownWithheld > 0` is the asker's own filter
        # claiming mail it never delivered. Those have opposite fixes, and the
        # pooled counts cannot separate them from correct relaying.
        own = [(d, r) for d, r in ans if r.get("ownHeld", 0) > 0]
        print(f"\n## sync — holder")
        print(f"  answers {len(ans)}, of which {len(own)} were asked by a peer "
              f"whose mail we were holding")
        if own:
            blind = [(d, r) for d, r in own if r.get("ownInWindow", 0) == 0]
            reach = [r["ownInWindow"] / r["ownHeld"] for _, r in own]
            print(f"  HELD ITS MAIL BUT THE ASK NEVER REACHED IT: "
                  f"{len(blind)} of {len(own)} ({len(blind)/len(own)*100:.1f}%)"
                  f"  <- the stall")
            print(f"  median share of the asker's own held mail the ask "
                  f"reached: {median(reach)*100:.1f}%")
            print(f"  its mail conveyed {sum(r.get('ownConveyed',0) for _, r in own)}, "
                  f"withheld by its own filter "
                  f"{sum(r.get('ownWithheld',0) for _, r in own)}")
            # Per pair, because that is what localised the fault last time: one
            # relay holding for one neighbour, invisible in the fleet total.
            per = defaultdict(list)
            for d, r in own:
                per[(d, short(r.get("peer")))].append(r)
            print(f"  {'holder':>8s} {'asker':>8s} {'rounds':>7s} "
                  f"{'ask missed it':>14s} {'conveyed':>9s} {'withheld':>9s}")
            rank = sorted(per.items(),
                          key=lambda kv: -sum(1 for r in kv[1]
                                              if r.get("ownInWindow", 0) == 0))
            for (d, p), rs in rank:
                miss = sum(1 for r in rs if r.get("ownInWindow", 0) == 0)
                print(f"  {d:>8s} {p:>8s} {len(rs):7d} "
                      f"{miss:8d} ({miss/len(rs)*100:3.0f}%) "
                      f"{sum(r.get('ownConveyed',0) for r in rs):9d} "
                      f"{sum(r.get('ownWithheld',0) for r in rs):9d}")
        # Kept unlabelled and last: the pooled counts are the whole buffer,
        # most of it third-party transit that is correctly withheld, so they
        # size the buffer and nothing else.
        print(f"  (pooled, for scale only — most of a buffer is other "
              f"people's mail: held median "
              f"{median([r.get('held', 0) for _, r in ans])}, conveyed "
              f"{sum(r.get('conveyed',0) for _, r in ans)}, withheld "
              f"{sum(r.get('withheld',0) for _, r in ans)})")

    # ---- pacing ------------------------------------------------------------
    print("\n## send pacing (offsets must be flat across the 10s announce "
          "quantum, or the schedule is aliased)")
    allo = []
    for label, a, b in trials:
        pairs = defaultdict(list)
        for m, (s, g, ts, sg) in sealed.items():
            if sg == label:
                pairs[(s, g)].append(ts - a)
        if not pairs:
            continue
        counts = [len(v) for v in pairs.values()]
        offs = [x % 10000 for v in pairs.values() for x in v]
        allo += offs
        print(f"  {label}: {len(pairs)} ordered pairs, per-pair sends "
              f"{min(counts)}-{max(counts)}")
    if allo:
        hist = Counter(x // 1000 for x in allo)
        print(f"  offset histogram (1s bins): "
              f"{[hist.get(i,0) for i in range(10)]}  (flat ~= "
              f"{len(allo)//10} each)")

    print("\n## drops")
    dr = Counter((r.get("reason"), r.get("where")) for d, ty, r in rows
                 if ty == "drop")
    for (reason, where), c in dr.most_common():
        print(f"  {str(reason):16s} {str(where):14s} {c}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
