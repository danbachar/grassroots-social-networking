#!/usr/bin/env python3
"""Checks for `analyze._dwell_from_resets` — the declared dwell of a sweep.

    python3 trace_server/test_dwell_from_resets.py

Plain asserts and a __main__, matching the other analysis checks.

A step's segment runs to the NEXT step marker, so it carries the reset that
follows the dwell. Reading the dwell off the span therefore reports dwell plus
reset, and `dwell_s` feeds the modelled advertising cost — a dwell 5 s long
overstates it by the same fraction.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent))
import analyze  # noqa: E402


def marker(t: int, label: str) -> dict:
    return {"_device": "a", "_t": t, "_type": "marker", "label": label}


def build(dwell_ms: int, reset_ms: int, steps: int):
    """A bracketed run: reset, marker, dwell, reset, marker, ... , reset, end."""
    rows, segs, t = [], [], 0
    for i in range(steps):
        rows += [marker(t, "custody-reset"), marker(t + 1, "links-reset")]
        t += reset_ms
        rows.append(marker(t, f"d=10 t{i + 1}"))
        segs.append({"t0": t, "d": 10.0})
        t += dwell_ms
    rows += [marker(t, "custody-reset"), marker(t + 1, "links-reset")]
    t += reset_ms
    rows.append(marker(t, "end"))
    # Segments close at the next step marker, and the last at `end`.
    for i, seg in enumerate(segs):
        seg["t1"] = segs[i + 1]["t0"] if i + 1 < len(segs) else t
    return pd.DataFrame(segs), pd.DataFrame(rows)


def check(name: str, got, want) -> bool:
    ok = got == want
    print(f"{'PASS' if ok else 'FAIL'}  {name}: got {got}, want {want}")
    return ok


def main() -> int:
    ok = True

    line, df = build(dwell_ms=30_000, reset_ms=5_000, steps=10)
    ok &= check("bracketed run reports the dwell, not dwell+reset",
                analyze._dwell_from_resets(line, df), 30.0)

    spans = ((line["t1"] - line["t0"]) / 1000.0)
    ok &= check("every span is inflated, so the min is NOT the dwell",
                round(float(spans.min()), 1), 35.0)

    # A run with no resets at all: the span is the dwell, and the helper says
    # so by returning NaN rather than a wrong number.
    line2, df2 = build(dwell_ms=30_000, reset_ms=0, steps=3)
    df2 = df2[~df2["label"].isin(analyze.RESET_MARKERS)]
    got = analyze._dwell_from_resets(line2, df2)
    ok &= check("no reset markers -> NaN, so the caller falls back",
                got != got, True)

    # One step whose reset landed early must not set the whole run's dwell.
    line3, df3 = build(dwell_ms=30_000, reset_ms=5_000, steps=10)
    early = df3["label"].eq("custody-reset") & df3["_t"].eq(35_000 + 30_000)
    df3.loc[early, "_t"] = 35_000 + 4_000
    ok &= check("a single early reset does not drag the median",
                analyze._dwell_from_resets(line3, df3), 30.0)

    print("OK" if ok else "FAILURES")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
