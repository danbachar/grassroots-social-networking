"""Dan's cut, part 2 of 2: load the pickle analysis_dan_data.py wrote and
draw the thesis figures. Nothing here touches the database, so re-running
after commenting a line out is seconds, not tens of seconds.

Comment out any ONE line in the marked block below to skip exactly that
figure on this run -- each line is independent (they only share the
pre-built tables loaded from the pickle, never each other's output).

Usage:
    python3 analysis_dan_plots.py line200.pkl --out ../../thesis/figures/eval
"""
from __future__ import annotations

import argparse
import pickle
import sys
from pathlib import Path

import analyze


def plot_one(exp: str, d: dict, out: Path) -> None:
    edf, steps, pairs, line = d["edf"], d["steps"], d["pairs"], d["line"]
    byd, clean, comp = d["byd"], d["clean"], d["comp"]
    out.mkdir(parents=True, exist_ok=True)

    with analyze.plt.rc_context(analyze._TH):
        # ------------------------------------------------------------------
        # ONE LINE PER FIGURE. Comment out any single line to skip it; the
        # rest are unaffected.
        # Shared scale: the distance and RSSI establishment panels are set
        # side by side, so both take the union of their band ranges.
        est_ylim = analyze._est_shared_ylim(byd, edf)
        analyze._th_establishment_vs_rssi(edf, out / "line200_establishment_vs_rssi.pdf", ylim=est_ylim)
        stages_ylim = analyze._stages_shared_ylim(byd, edf)
        analyze._th_stages_vs_rssi(edf, out / "line200_stages_vs_rssi.pdf",
                                   ylim=stages_ylim)
        #analyze._th_establishment(byd, out / "line200_establishment.pdf",
        #                          ylim=est_ylim)
        #analyze._th_stages(byd, out / "line200_stages.pdf", ylim=stages_ylim, compact=True)
        #analyze._th_path_loss(edf, out / "line200_path_loss.pdf")
        #analyze._th_control_bytes(edf, out / "line200_control_bytes.pdf")
        #analyze._th_stage_bytes_pair(edf, out)
        #analyze._th_delivery_vs_rssi(line, out / "line200_delivery_vs_rssi.pdf")
        #analyze._th_latency_vs_rssi(line, out / "line200_latency_vs_rssi.pdf")
        # Appendix pair: the same two figures over trials in which no dial
        # was refused, so the ladder is the cost of a link that forms.
        #analyze._th_establishment(clean, out / "line200_establishment_clean.pdf")
        #analyze._th_stages(clean, out / "line200_stages_clean.pdf")
        #analyze._th_stages(comp, out / "line200_stages_complete.pdf")
        # ------------------------------------------------------------------

    # Self-gates on carrying N= steps at >=2 clique sizes, so a line sweep's
    # pickle just produces nothing here. Self-wraps its own rc_context, so
    # it sits outside the `with` block above rather than inside it.
    #analyze.plot_thesis_clique_figures(edf, steps, pairs, out)

    print(f"[{exp}] -> {out}/")


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("pickle", type=Path,
                    help="pickle written by analysis_dan_data.py")
    ap.add_argument("--out", type=Path, default=Path("."),
                    help="output directory for the figures (default: cwd)")
    args = ap.parse_args()

    if not args.pickle.exists():
        print(f"no such file: {args.pickle}", file=sys.stderr)
        return 1

    data = pickle.loads(args.pickle.read_bytes())
    for exp, d in data.items():
        plot_one(exp, d, args.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
