#!/usr/bin/env python3
"""Checks for the dial-grid analysis in `analyze.py`.

    python3 trace_server/test_dial_probe.py

Plain asserts and a __main__, in the style of `test_rearm_guard.py`: the
analysis chain has no test runner and adding pytest for one module would be
more machinery than the code it guards. Run it after touching
`dial_probe_table`, `dial_scores` or `plot_dial_probe`.

The synthetic trace is the record shape the runner actually writes. The grid
is a CAP on the transport's ordinary greedy dialing, not a scripted burst, so
there is no burst record to join on: a step `marker` carrying popN /
maxParallel / rep OPENS the window, the ordinary central `connected` link
stamps inside it ARE the establishments (each carrying the in-flight dial
count and the live-link counters), and a `dialcell` record closes it with the
runner's own count.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze  # noqa: E402


def marker(dev: str, t: int, label: str, **extra) -> dict:
    return {"_device": dev, "_t": t, "_type": "marker", "_exp": "x",
            "event": "note", "label": label, **extra}


def cell(dev: str, t: int, label: str, pop_n: int, m: int, rep: int,
         established: int) -> dict:
    return {"_device": dev, "_t": t, "_type": "dialcell", "_exp": "x",
            "step": label, "popN": pop_n, "maxParallel": m, "rep": rep,
            "established": established, "dwellSec": 120}


def link(dev: str, t: int, event: str, path: str, peer: str | None = None,
         role: str | None = None, **extra) -> dict:
    return {"_device": dev, "_t": t, "_type": "link", "_exp": "x",
            "event": event, "path": path, "peer": peer, "role": role, **extra}


def establishment(dev: str, t: int, i: int, peer: str, in_flight: int,
                  peripheral_links: int, total_links: int) -> list[dict]:
    """One central leg landing, plus the session and the peer's reverse leg."""
    return [
        link(dev, t, "connected", f"central:T{i}", peer, "central",
             inFlight=in_flight, peripheralLinks=peripheral_links,
             totalLinks=total_links),
        link(dev, t + 200, "session", f"central:T{i}", peer, "central"),
        link(dev, t + 300, "connected", f"peripheral:P{i}", peer,
             "peripheral"),
        link(dev, t + 60_000, "drop", f"peripheral:P{i}", peer, "peripheral"),
    ]


DWELL = 120_000
GAP = 5_000


def synthetic() -> pd.DataFrame:
    """One device, two populations x three caps, two reps each.

    At pop_n=4 the count keeps rising with M (1, 2, 3 establishments), so the
    knee is the largest M. At pop_n=8 it stops at M=2 (1, 3, 3) — the knee is
    2, which is the whole verdict the grid exists to produce. The N=8 rows
    also carry a fat inbound-link load, so `max_total_links` reports a
    ceiling the N=4 rows never approach.
    """
    dev = "aabbccdd"
    rows: list[dict] = []
    t = 1_000_000
    counts = {(4, 1): 1, (4, 2): 2, (4, 3): 3,
              (8, 1): 1, (8, 2): 3, (8, 3): 3}
    for pop_n in (4, 8):
        for m in (1, 2, 3):
            for rep in (1, 2):
                label = f"N={pop_n} M={m} t{rep}"
                rows.append(marker(dev, t, label, popN=pop_n, maxParallel=m,
                                   rep=rep, order=1))
                n_est = counts[(pop_n, m)]
                # Inbound legs: everyone else dialed us. Nothing caps those,
                # and they share the controller's link budget with our own.
                peripheral = pop_n - 1
                for i in range(1, n_est + 1):
                    rows += establishment(
                        dev, t + 400 + 100 * i, i, f"peer{i}",
                        in_flight=n_est - i,
                        peripheral_links=peripheral,
                        total_links=peripheral + i)
                rows.append(cell(dev, t + DWELL, label, pop_n, m, rep, n_est))
                t += DWELL + GAP
    # A converge step: no cap, so it is not a cell and must not become one.
    rows.append(marker(dev, t, "N=8 converge", popN=8, order=1))
    rows += establishment(dev, t + 500, 9, "peer9", 0, 7, 8)
    rows.append(marker(dev, t + DWELL, "end"))
    return pd.DataFrame(rows)


def check(name: str, ok: bool, detail: str = "") -> bool:
    print(f"{'PASS' if ok else 'FAIL'}  {name}")
    if not ok and detail:
        print(f"      {detail}")
    return ok


def main() -> int:
    df = synthetic()
    dial = analyze.dial_probe_table(df)
    results = []

    results.append(check(
        "the table is keyed on the cell and carries BOTH variables",
        {"device", "pop_n", "m", "rep"} <= set(dial.columns)
        and "n" not in dial.columns,
        f"columns={sorted(dial.columns)}"))
    # Two reps of each of the six cells: 2 * (1+2+3 + 1+3+3).
    results.append(check(
        "one row per establishment, 26 across the two populations",
        len(dial) == 26,
        f"rows={len(dial)}"))
    results.append(check(
        "an uncapped converge step is not a cell",
        not (dial.step == "N=8 converge").any(),
        f"steps={sorted(dial.step.unique())}"))
    results.append(check(
        "populations survive the window join",
        sorted(dial.pop_n.unique().tolist()) == [4, 8],
        f"pop_n={sorted(dial.pop_n.unique().tolist())}"))
    results.append(check(
        "the derived count agrees with the runner's own dialcell count",
        bool((dial.established == dial.recorded).all()),
        f"{dial[['step', 'established', 'recorded']].to_dict('records')}"))
    results.append(check(
        "the link-budget counters reach the table",
        {"in_flight", "peripheral_links", "total_links"} <= set(dial.columns)
        and int(dial[dial.pop_n == 8].total_links.max()) == 10
        and int(dial[dial.pop_n == 4].total_links.max()) == 6,
        f"N=8 max={dial[dial.pop_n == 8].total_links.max()}, "
        f"N=4 max={dial[dial.pop_n == 4].total_links.max()}"))
    ladder = dial[dial.established > 0]
    results.append(check(
        "every establishment carries the full formation ladder",
        int(ladder.ms_to_establish.notna().sum()) == len(ladder)
        and int(ladder.ms_to_session.notna().sum()) == len(ladder)
        and int(ladder.ms_to_converged.notna().sum()) == len(ladder),
        f"usable={int(ladder.ms_to_establish.notna().sum())}, "
        f"session={int(ladder.ms_to_session.notna().sum())}, "
        f"converged={int(ladder.ms_to_converged.notna().sum())} "
        f"of {len(ladder)}"))

    scores = analyze.dial_scores(dial)
    results.append(check(
        "one score row per (device, pop_n)",
        len(scores) == 2 and sorted(scores.pop_n.tolist()) == [4, 8],
        f"rows={len(scores)}"))
    by_pop = {int(r.pop_n): r for r in scores.itertuples()}
    results.append(check(
        "establishments per window are reported at every M",
        by_pop[8].est_m1 == 1 and by_pop[8].est_m2 == 3
        and by_pop[8].est_m3 == 3,
        f"N=8: m1={by_pop[8].est_m1}, m2={by_pop[8].est_m2}, "
        f"m3={by_pop[8].est_m3}"))
    results.append(check(
        "the knee is the M where the count STOPS rising: 3 at N=4, 2 at N=8",
        by_pop[4].knee_m == 3 and by_pop[8].knee_m == 2,
        f"knee: N=4 -> {by_pop[4].knee_m}, N=8 -> {by_pop[8].knee_m}"))
    results.append(check(
        "the knee's medians come from that population's rows",
        by_pop[8].median_ms_establish_at_knee is not None
        and by_pop[8].median_ms_converged_at_knee is not None,
        f"{by_pop[8]}"))
    results.append(check(
        "max_total_links exposes the device's link-budget ceiling per pop",
        by_pop[8].max_total_links == 10 and by_pop[4].max_total_links == 6
        and by_pop[8].max_peripheral_links == 7,
        f"N=8 total={by_pop[8].max_total_links}, "
        f"peripheral={by_pop[8].max_peripheral_links}, "
        f"N=4 total={by_pop[4].max_total_links}"))

    out = Path(tempfile.mkdtemp(prefix="dialprobe-"))
    try:
        written = analyze.plot_dial_probe(dial, out / "dial_probe.png")
        names = sorted(p.name for p in written)
        results.append(check(
            "a figure per population, plus the headline at the largest",
            names == ["dial_probe.png", "dial_probe_N4.png",
                      "dial_probe_N8.png"],
            f"written={names}"))
        results.append(check(
            "every figure is actually on disk and non-empty",
            all(p.exists() and p.stat().st_size > 0 for p in written)))
    finally:
        shutil.rmtree(out, ignore_errors=True)

    print(f"\n{sum(results)}/{len(results)} checks passed")
    return 0 if all(results) else 1


if __name__ == "__main__":
    sys.exit(main())
