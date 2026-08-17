#!/usr/bin/env python3
"""Checks for the dial-grid analysis in `analyze.py`.

    python3 trace_server/test_dial_probe.py

Plain asserts and a __main__, in the style of `test_rearm_guard.py`: the
analysis chain has no test runner and adding pytest for one module would be
more machinery than the code it guards. Run it after touching
`dial_probe_table`, `dial_scores` or `plot_dial_probe`.

The synthetic trace is the record shape the runner actually writes:
a `dialburst` carrying BOTH variables (`popN` = radios up, `m` = dials fired
at once) plus the DUT-local `link` stamps the join reads. The first version
of this probe logged only the burst size under the name `n`, which made a
burst of 4 into a two-phone room indistinguishable from one into an
eight-phone room — hence the assertions below that the grouping is per
(device, pop_n) and that one figure comes out per population.
"""
from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze  # noqa: E402


def burst(dev: str, t: int, dut: int, pop_n: int, m: int, rep: int,
          targets: list[str]) -> dict:
    return {"_device": dev, "_t": t, "_type": "dialburst", "_exp": "x",
            "dut": dut, "popN": pop_n, "m": m, "rep": rep,
            "label": f"N={pop_n} DUT={dut} M={m} t{rep}", "targets": targets}


def link(dev: str, t: int, event: str, path: str, peer: str | None = None):
    return {"_device": dev, "_t": t, "_type": "link", "_exp": "x",
            "event": event, "path": path, "peer": peer}


def ladder(dev: str, t0: int, path: str, peer: str, usable_ms: int,
           session_ms: int | None = None) -> list[dict]:
    """One target's formation stamps: raw GATT up, usable, and a session."""
    rows = [link(dev, t0 + usable_ms // 2, "gattConnected", path, peer),
            link(dev, t0 + usable_ms, "connected", path, peer)]
    if session_ms is not None:
        rows.append(link(dev, t0 + session_ms, "session", path, peer))
    return rows


def synthetic() -> pd.DataFrame:
    """Two populations x two burst sizes x two reps on one DUT device.

    At pop_n=4 every dial lands (P* = 2). At pop_n=8 the M=2 bursts each lose
    one dial past the deadline, so P* falls to 1 — the whole reason the score
    is keyed on the population and not on the device alone.
    """
    dev = "aabbccdd"
    rows: list[dict] = []
    t = 1_000_000
    for pop_n in (4, 8):
        for m in (1, 2):
            for rep in (1, 2):
                targets = [f"central:T{i}" for i in range(1, m + 1)]
                rows.append(burst(dev, t, 1, pop_n, m, rep, targets))
                for i, target in enumerate(targets, start=1):
                    peer = f"peer{i}"
                    late = pop_n == 8 and m == 2 and i == 2
                    usable = 25_000 if late else 400 + 100 * i
                    rows += ladder(dev, t, target, peer, usable,
                                   session_ms=None if late else usable + 200)
                    # The peer's reverse leg, live from just after usable:
                    # dual-leg convergence needs both legs to the identity.
                    if not late:
                        rows.append(
                            link(dev, t + usable + 50, "discovered",
                                 f"peripheral:P{i}", peer))
                        rows.append(
                            link(dev, t + usable + 50, "connected",
                                 f"peripheral:P{i}", peer))
                        rows.append(
                            link(dev, t + 30_000, "drop",
                                 f"peripheral:P{i}", peer))
                # Next burst opens the following join window.
                t += 40_000
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
        "table carries BOTH variables and no ambiguous `n`",
        {"pop_n", "m"} <= set(dial.columns) and "n" not in dial.columns,
        f"columns={sorted(dial.columns)}"))
    results.append(check(
        "one row per dialed target",
        len(dial) == 2 * (1 + 1 + 2 + 2),  # per population: 1+1+2+2 targets
        f"rows={len(dial)}"))
    results.append(check(
        "populations survive the join",
        sorted(dial.pop_n.unique().tolist()) == [4, 8],
        f"pop_n={sorted(dial.pop_n.unique().tolist())}"))
    results.append(check(
        "a dial past the 20 s deadline is not ok",
        int((~dial.ok).sum()) == 2,
        f"failed={int((~dial.ok).sum())}"))
    conv = dial[dial.ok].ms_to_converged.dropna()
    results.append(check(
        "dual-leg convergence is stamped for landed dials",
        len(conv) == len(dial[dial.ok]),
        f"converged={len(conv)} of {len(dial[dial.ok])}"))

    scores = analyze.dial_scores(dial)
    results.append(check(
        "one score row per (device, pop_n)",
        len(scores) == 2 and sorted(scores.pop_n.tolist()) == [4, 8],
        f"rows={len(scores)}"))
    by_pop = {int(r.pop_n): r for r in scores.itertuples()}
    results.append(check(
        "P* is per population: 2 at N=4, 1 at N=8",
        by_pop[4].p_star == 2 and by_pop[8].p_star == 1,
        f"p_star: N=4 -> {by_pop[4].p_star}, N=8 -> {by_pop[8].p_star}"))
    results.append(check(
        "the per-M success fraction is reported per population",
        by_pop[8].ok_frac_m1 == 1.0 and by_pop[8].ok_frac_m2 == 0.5,
        f"N=8: m1={by_pop[8].ok_frac_m1}, m2={by_pop[8].ok_frac_m2}"))
    results.append(check(
        "medians at P* come from that population's rows",
        by_pop[4].median_ms_usable_at_pstar is not None
        and by_pop[4].median_ms_converged_at_pstar is not None,
        f"{by_pop[4]}"))

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
