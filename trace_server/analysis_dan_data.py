"""Dan's cut, part 1 of 2: read traces.db once and pickle everything the
plotting script (analysis_dan_plots.py) needs, so re-plotting never
re-touches the database.

Imports analyze.py rather than duplicating its data-processing logic (the
SQL load, re-arm handling, the per-step/per-trial tables) -- that logic is
substantial and already tested there, and importing it means a fix to
analyze.py is picked up here for free instead of the two files drifting
apart.

Usage:
    python3 analysis_dan_data.py data/traces.db --exp line-200 --out line200.pkl
"""
from __future__ import annotations

import argparse
import pickle
import sys
from pathlib import Path

import pandas as pd

import analyze


def _plain(byd: dict) -> dict:
    """analyze._th_ladder returns a defaultdict whose factory is a lambda --
    pickle refuses that ("can't pickle local object"), so flatten it to
    plain dicts of lists before it's written out.
    """
    return {d: dict(stages) for d, stages in byd.items()}


def build(db: Path, exp: str | None) -> dict[str, dict]:
    """Everything downstream of the raw trace, keyed by experiment name.

    Each experiment's entry carries the raw per-device frame (`edf` --
    needed by the three figures that re-derive their own segments from it)
    alongside the tables built from it once here (`steps`, `pairs`, `line`)
    and the three ladder reductions (`byd`, `clean`, `comp`) at every
    variant the figures use.
    """
    df = analyze.load_db(db, exp=exp)
    if df.empty:
        sys.exit(f"no records found (exp={exp})")

    out: dict[str, dict] = {}
    for e, edf in df.groupby("_exp"):
        if exp and e != exp:
            continue
        edf = analyze._drop_pre_arm(edf)

        latency = analyze.latency_table(edf)
        segs = analyze.marker_segments(edf)
        steps = analyze.steps_table(edf, segs, latency) if segs else pd.DataFrame()
        pairs = analyze.pair_matrix(latency, segs) if segs else pd.DataFrame()
        line = analyze._line_steps(steps) if not steps.empty else pd.DataFrame()

        out[e] = dict(
            edf=edf,
            steps=steps,
            pairs=pairs,
            line=line,
            byd=_plain(analyze._th_ladder(edf)),
            clean=_plain(analyze._th_ladder(edf, drop_gatt133=True)),
            comp=_plain(analyze._th_ladder(edf, complete_only=True)),
        )
        print(f"[{e}] processed: {len(edf)} records, "
              f"{edf._device.nunique()} device(s), {len(segs)} step(s)")
    if not out:
        sys.exit(f"experiment {exp!r} not found in {db}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("db", type=Path, help="traces.db (SQLite only)")
    ap.add_argument("--exp", default=None,
                    help="experiment name, e.g. line-200 (filtered in SQL)")
    ap.add_argument("--out", type=Path, default=Path("analysis_dan.pkl"),
                    help="pickle path to write (default: ./analysis_dan.pkl)")
    args = ap.parse_args()

    if not args.db.exists():
        print(f"no such file: {args.db}", file=sys.stderr)
        return 1

    data = build(args.db, args.exp)
    args.out.write_bytes(pickle.dumps(data))
    print(f"wrote {args.out} ({args.out.stat().st_size / 1024:.0f} KiB, "
          f"{len(data)} experiment(s): {', '.join(data)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
