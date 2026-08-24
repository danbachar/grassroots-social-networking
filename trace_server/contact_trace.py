#!/usr/bin/env python3
"""Size `NoiseSessionManager.maxSessions` against a published contact trace.

Our own field traces have one peer and one pairing, which cannot size an LRU
cache. Published human-contact traces supply the missing input: the sequence
of distinct peers a device meets, at realistic densities and over realistic
spans. This reads one, converts it to the same encounter sequences that
`analyze.py session_cap()` builds from our sightings, and runs the identical
stack-distance and cost model over it — the two paths must not diverge, so
the shared functions are imported, not copied.

Every participant in the trace is treated as one device, so the result is a
DISTRIBUTION of optimal caps across the population, not a single number. The
cap to ship is a high percentile of that distribution: it has to work for the
most socially exposed node, not the median one.

Formats, auto-detected by column count:

  3 cols  `t i j`             SocioPatterns tij: i and j were in contact
                              during [t-20s, t]. Repeated rows for a
                              continuing contact.
  4 cols  `i j t_start t_end`  Contact intervals (CRAWDAD Haggle contacts.*).
  5 cols  `t CONN i j up|down` ONE-simulator connectivity trace.

Radio range is the one thing to check before trusting a result: RFID
face-to-face traces (SocioPatterns) sense at 1-1.5 m and require badges to
face each other, so they UNDERCOUNT encounters for a 10-30 m BLE radio.
Bluetooth inquiry traces (CRAWDAD Haggle, Reality Mining) sense at roughly
BLE's range and are the better external validity for this question.

Usage:
  python3 contact_trace.py contacts.dat --t-fail-us 210 --t-handshake-us 12000
  python3 contact_trace.py tij.dat --r-miss 0 --r-miss 25 --r-miss 50
"""
from __future__ import annotations

import argparse
import importlib.util
import statistics
import sys
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "analyze", Path(__file__).with_name("analyze.py"))
_az = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_az)

# Reused so the published-trace path and the field-trace path cannot drift.
hit_rate_curve = _az._hit_rate_curve
ENCOUNTER_GAP_S = _az.ENCOUNTER_GAP_S

CAPS = [4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048]


def load_contacts(path: Path) -> list[tuple[float, str, str]]:
    """Returns (t_seconds, node_a, node_b) sightings, one per contact moment.

    An interval-format row is expanded to its endpoints rather than to every
    second in between: the gap-sessionisation below only needs to know that
    the pair was in contact at those times, and expanding a 3-hour contact
    second by second would add millions of rows that change nothing.
    """
    out: list[tuple[float, str, str]] = []
    with path.open() as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            f = line.replace(",", " ").split()
            if len(f) == 3:                                  # t i j
                out.append((float(f[0]), f[1], f[2]))
            elif len(f) == 4:                                # i j t_start t_end
                a, b, t0, t1 = f[0], f[1], float(f[2]), float(f[3])
                out.append((t0, a, b))
                if t1 > t0:
                    out.append((t1, a, b))
            elif len(f) == 5 and f[1].upper() == "CONN":      # ONE simulator
                if f[4].lower() == "up":
                    out.append((float(f[0]), f[2], f[3]))
            else:
                raise SystemExit(
                    f"unrecognised line in {path} ({len(f)} columns): {line[:80]}")
    if not out:
        raise SystemExit(f"no contact rows parsed from {path}")
    out.sort(key=lambda r: r[0])
    return out


def encounter_sequences(contacts: list[tuple[float, str, str]],
                        gap_s: float) -> dict[str, list[str]]:
    """Per node, the ordered peers it encountered.

    A contact is symmetric, so each row feeds both directions. A sighting more
    than `gap_s` after the previous one from the same peer starts a new
    encounter — the same rule `analyze.py` applies to our own sightings, so a
    published trace and a field trace are sessionised identically.
    """
    last: dict[tuple[str, str], float] = {}
    seq: dict[str, list[str]] = {}
    for t, a, b in contacts:
        for me, peer in ((a, b), (b, a)):
            prev = last.get((me, peer))
            if prev is None or t - prev > gap_s:
                seq.setdefault(me, []).append(peer)
            last[(me, peer)] = t
    return seq


def cap_table(seq: dict[str, list[str]], span_s: float, t_fail_us: float,
              t_handshake_us: float, r_miss: float) -> list[dict]:
    """Per-cap cost, averaged over nodes, plus the per-node optimum spread.

    cost(N) = r_miss x min(N, peers) x t_fail      walk the table per second
            + encounters/s x (1 - hit(N)) x t_hs   re-handshake what was evicted
    """
    rows = []
    per_node_best: dict[str, int] = {}
    curves = {node: hit_rate_curve(s, CAPS) for node, s in seq.items()}

    for node, s in seq.items():
        distinct = len(set(s))
        enc_rate = len(s) / span_s
        best_n, best_cost = CAPS[0], float("inf")
        for n in CAPS:
            cost = (r_miss * min(n, distinct) * t_fail_us
                    + enc_rate * (1 - curves[node][n]) * t_handshake_us)
            if cost < best_cost - 1e-9:
                best_n, best_cost = n, cost
        per_node_best[node] = best_n

    for n in CAPS:
        costs, hits = [], []
        for node, s in seq.items():
            distinct = len(set(s))
            enc_rate = len(s) / span_s
            hits.append(curves[node][n])
            costs.append(r_miss * min(n, distinct) * t_fail_us
                         + enc_rate * (1 - curves[node][n]) * t_handshake_us)
        rows.append({
            "cap": n,
            "mean_hit_rate": round(statistics.fmean(hits), 4),
            "p05_hit_rate": round(_pct(hits, 5), 4),
            "mean_us_per_s": round(statistics.fmean(costs), 1),
            "p95_us_per_s": round(_pct(costs, 95), 1),
            "mean_cpu_pct": round(statistics.fmean(costs) / 10_000.0, 4),
            "nodes_best_here": sum(1 for v in per_node_best.values() if v == n),
        })
    return rows


def _pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = (len(s) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (k - lo)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("trace", type=Path)
    ap.add_argument("--gap-s", type=float, default=ENCOUNTER_GAP_S,
                    help="silence that separates two encounters with one peer")
    ap.add_argument("--t-fail-us", type=float, default=_az.T_FAIL_US,
                    help="one failed AEAD open (CryptoBench, on the SLOWEST phone)")
    ap.add_argument("--t-handshake-us", type=float,
                    default=_az.T_HANDSHAKE_US + _az.T_HANDSHAKE_BLE_US,
                    help="one Noise XX re-handshake, CPU plus BLE round trips")
    ap.add_argument("--r-miss", type=float, action="append", default=None,
                    help="inbound sealed packets/s that open under NO session. "
                         "~0 while the envelope carries a recipient; the full "
                         "transit rate without it. Repeatable to sweep.")
    ap.add_argument("--out", type=Path, default=None, help="write CSV here")
    args = ap.parse_args()

    contacts = load_contacts(args.trace)
    span_s = max(contacts[-1][0] - contacts[0][0], 1.0)
    seq = encounter_sequences(contacts, args.gap_s)
    sizes = [len(set(s)) for s in seq.values()]

    print(f"{args.trace.name}: {len(contacts)} contact rows, "
          f"{len(seq)} nodes, span {span_s / 3600:.1f} h")
    print(f"  encounters/node: median {statistics.median(len(s) for s in seq.values()):.0f}, "
          f"max {max(len(s) for s in seq.values())}")
    print(f"  distinct peers/node: median {statistics.median(sizes):.0f}, "
          f"p95 {_pct(sizes, 95):.0f}, max {max(sizes)}")
    print(f"  t_fail={args.t_fail_us:.0f}us  t_handshake={args.t_handshake_us:.0f}us")

    all_rows = []
    for r_miss in (args.r_miss or [0.0, 25.0, 50.0]):
        rows = cap_table(seq, span_s, args.t_fail_us, args.t_handshake_us, r_miss)
        best = min(rows, key=lambda r: r["mean_us_per_s"])
        print(f"\n  R_miss = {r_miss:g} pkt/s "
              f"({'recipient in envelope' if r_miss == 0 else 'recipient removed'})")
        print(f"    {'cap':>6} {'hit':>7} {'p05 hit':>8} {'us/s':>10} "
              f"{'cpu%':>7} {'nodes best':>11}")
        for r in rows:
            mark = " <-" if r["cap"] == best["cap"] else ""
            print(f"    {r['cap']:>6} {r['mean_hit_rate']:>7.3f} "
                  f"{r['p05_hit_rate']:>8.3f} {r['mean_us_per_s']:>10.1f} "
                  f"{r['mean_cpu_pct']:>7.3f} {r['nodes_best_here']:>11}{mark}")
        for r in rows:
            all_rows.append({"r_miss": r_miss, **r})

    if args.out:
        import csv
        with args.out.open("w", newline="") as fh:
            w = csv.DictWriter(fh, fieldnames=list(all_rows[0].keys()))
            w.writeheader()
            w.writerows(all_rows)
        print(f"\nwrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
