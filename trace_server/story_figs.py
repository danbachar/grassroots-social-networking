#!/usr/bin/env python3
"""
The two narrative figures for the advisor email that are NOT about establishment
cost (those live in fieldday_figs.py):

  fieldday_lineexp.png   the line experiment itself — establishment probability,
                         forward vs round-trip delivery, and the path-loss fit
  throughput_story.png   the 1 m laboratory characterization — capacity ceiling,
                         bufferbloat, raw GATT pipe per leg, per-message wire cost

Sources: the field split db (data/field.db) and the analyzer's per-experiment
CSVs for the lab runs, plus the raw wire ledger in data/traces.db for the raw-leg
and payload arms (the analyzer's steps.csv has no rows for raw mode, which
bypasses the message path entirely).

Usage:
    ~/.pyenv/shims/python3 story_figs.py
"""
from __future__ import annotations

import argparse
import json
import re
import sqlite3
from collections import defaultdict
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

C1, C2, C3, C4 = "#2a78d6", "#eb6834", "#1baf7a", "#eda100"
C_VIOLET, C_RED = "#4a3aa7", "#e34948"
INK, INK2 = "#0b0b0b", "#52514e"
SURFACE = "#fcfcfb"
GRID = "#d9d8d4"

# Unsaturated round trip from the overnight soak (9000 messages at 1 m).
UNSATURATED_RTT_MS = 112.0


def _despine(ax, grid_axis="y"):
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK2, length=0)
    ax.grid(axis=grid_axis, color=GRID, linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)


# --------------------------------------------------------------------------- #
# Figure 1 — the line experiment
# --------------------------------------------------------------------------- #
def line_experiment(est: pd.DataFrame, steps: pd.DataFrame, pathloss: str,
                    out: Path) -> None:
    fig, axes = plt.subplots(1, 3, figsize=(13.6, 4.6), dpi=200)
    ax1, ax2, ax3 = axes

    # The three stages coincide wherever nothing is lost between them, so the
    # lines are drawn widest-first: a hidden stage means "same as the one above".
    for key, label, color, lw, ms in (("discovered_rate", "Discovered", C3, 4.5, 9),
                                      ("session_rate", "Noise session", C2, 2.6, 6.5),
                                      ("usable_rate", "Usable (ACK back)", C1, 1.5, 4.5)):
        ax1.plot(est["d"], est[key] * 100, marker="o", markersize=ms,
                 linewidth=lw, color=color, label=label, zorder=3)
    ax1.set_ylim(-4, 108)
    ax1.set_xticks(est["d"])
    ax1.set_xlabel("Distance (m)", color=INK2)
    ax1.set_ylabel("Trials reaching the stage (%)", color=INK2)
    ax1.set_title("Establishment probability", color=INK, fontsize=11, loc="left")
    # ax1.axvspan(0, 50, color=C3, alpha=0.06, zorder=0)
    # ax1.annotate("reliable hop\n<= 50 m", (30, 20), ha="center", fontsize=8.5,
    #              color=INK2)
    _despine(ax1)
    ax1.legend(frameon=False, fontsize=8.5, labelcolor=INK2, loc="lower left")

    ax2.plot(est["d"], est["recv_rate"] * 100, marker="o", markersize=6,
             linewidth=2, color=C1, label="Received (forward path)", zorder=3)
    ax2.plot(est["d"], est["delivery_rate"] * 100, marker="o", markersize=6,
             linewidth=2, color=C2, label="ACK-confirmed (round trip)", zorder=3)
    ax2.fill_between(est["d"], est["delivery_rate"] * 100, est["recv_rate"] * 100,
                     color=C2, alpha=0.12, zorder=2)
    ax2.set_ylim(-4, 108)
    ax2.set_xticks(est["d"])
    ax2.set_xlabel("Distance (m)", color=INK2)
    ax2.set_ylabel("Share of messages sent (%)", color=INK2)
    ax2.set_title("Delivery: forward vs. round trip", color=INK, fontsize=11, loc="left")
    # ax2.annotate("shaded gap =\nreverse-path loss", (70, 45), ha="center",
    #              fontsize=8.5, color=INK2)
    for _, row in est.iterrows():
        ax2.annotate(f"{int(row.msg_sent)}", (row.d, 104), ha="center",
                     fontsize=7.5, color=INK2)
    _despine(ax2)
    ax2.legend(frameon=False, fontsize=8.5, labelcolor=INK2, loc="lower left")

    per_d = steps.groupby("d")["rssi_adv_mean"]
    mean, sd = per_d.mean(), per_d.std()
    ax3.errorbar(mean.index, mean.values, yerr=sd.values, fmt="o", markersize=6,
                 capsize=3, linewidth=1.6, color=C1, label="Measured (mean +- sd)",
                 zorder=3)
    m = re.search(r"RSSI\(d\) = (-?[\d.]+) - 10 \* ([\d.]+) \* log10\(d\)", pathloss)
    if m:
        a, n = float(m.group(1)), float(m.group(2))
        dd = np.linspace(10, 100, 100)
        ax3.plot(dd, a - 10 * n * np.log10(dd), linewidth=2, color=C2,
                 label=f"Log-distance fit", zorder=2)
    # ax3.axhline(-91, linestyle=":", linewidth=1.4, color=C_RED, zorder=1)
    # ax3.annotate("receiver floor ~ -91 dBm", (12, -90.4), fontsize=8.5, color=C_RED)
    ax3.set_xticks(mean.index)
    ax3.set_xlabel("Distance (m)", color=INK2)
    ax3.set_ylabel("Advertisement RSSI (dBm)", color=INK2)
    ax3.set_title("Path loss", color=INK, fontsize=11, loc="left")
    _despine(ax3)
    ax3.legend(frameon=False, fontsize=8.5, labelcolor=INK2, loc="lower left")

    # fig.suptitle("Line experiment",color=INK, fontsize=13, x=0.005, ha="left", y=1.03)
    # fig.text(0.005, -0.07,
    #          "Far points are sensitivity-censored: RSSI can only be measured from advertisements that were "
    #          "actually received, so the mean at 80-100 m is\nbiased upward by the ones that were not. "
    #          "Delivery rates are over messages sent in that step (the count above each point), which is "
    #          "itself smaller at distance:\nsends only fire once the link settles, and at 80 m the settle eats "
    #          "most of the 30 s dwell.",
    #          fontsize=7.5, color=INK2)
    fig.tight_layout()
    out.mkdir(parents=True, exist_ok=True)
    fig.savefig(out / "fieldday_lineexp.png", bbox_inches="tight", facecolor=SURFACE)
    print(f"Save field day line experiment to {out}/fieldday_lineexp.png")
    plt.close(fig)


# --------------------------------------------------------------------------- #
# Figure 2 — the laboratory characterization
# --------------------------------------------------------------------------- #
def _segments(conn, exp: str, dev: str, prefix: str) -> list[dict]:
    rows = conn.execute(
        "SELECT t, body FROM records WHERE upload_id LIKE ? AND device_id LIKE ? "
        "AND type='marker' ORDER BY t", (f"exp_{exp}%", dev + "%")).fetchall()
    segs: list[dict] = []
    for t, body in rows:
        rec = json.loads(body)
        label = rec.get("label", "")
        if label.startswith(prefix):
            segs.append({"label": label, "t0": t, "raw": None, "t1": None})
        elif label == "raw-start" and segs:
            segs[-1]["raw"] = t
        elif label == "end" or rec.get("event") == "expStop":
            if segs and segs[-1]["t1"] is None:
                segs[-1]["t1"] = t
    for i in range(len(segs) - 1):
        if segs[i]["t1"] is None:
            segs[i]["t1"] = segs[i + 1]["t0"]
    return [s for s in segs if s["t1"]]


def raw_pipe(conn) -> pd.DataFrame:
    """Raw-blob GATT throughput per leg, measured at the RECEIVER.

    Sender-side counts include everything handed to the OS stack, which
    completes writes at enqueue; only the peer's rx ledger says what crossed.
    Trials where the link never settled (no `raw-start`) are dropped, not
    counted as zero.
    """
    w = [(t, d[:8], json.loads(b)) for t, d, b in conn.execute(
        "SELECT t, device_id, body FROM records WHERE upload_id LIKE 'exp_raw-link-1%' "
        "AND type='wire' ORDER BY t")]
    out = []
    for s in _segments(conn, "raw-link-1", "adbed3e0", "leg="):
        if s["raw"] is None:
            continue
        dur = (s["t1"] - s["raw"]) / 1000.0
        rx = sum((r.get("rxBytes") or {}).get("raw", 0)
                 for t, dev, r in w if s["t0"] <= t < s["t1"] and dev == "ba2af95f")
        out.append({"leg": s["label"].split("=")[1].split()[0],
                    "kBps": rx / dur / 1024})
    return pd.DataFrame(out)


def payload_arm(conn) -> pd.DataFrame:
    """Sender air bytes per delivered message, per payload size."""
    w = [(t, d[:8], json.loads(b)) for t, d, b in conn.execute(
        "SELECT t, device_id, body FROM records WHERE upload_id LIKE 'exp_throughput-arm-2%' "
        "AND type='wire' ORDER BY t")]
    steps = pd.read_csv("analysis/throughput-arm-2/steps.csv")
    out = []
    for s in _segments(conn, "throughput-arm-2", "ba2af95f", "p="):
        tx = defaultdict(float)
        for t, dev, r in w:
            if s["t0"] <= t < s["t1"] and dev == "ba2af95f":
                for k, v in (r.get("txBytes") or {}).items():
                    if k.startswith("secure"):
                        tx[k] += v
        row = steps[steps.label == s["label"]]
        if not len(row):
            continue
        delivered = float(row.msg_delivered.iloc[0])
        payload = float(row.payloadB.iloc[0])
        if delivered:
            out.append({"payloadB": payload, "B_per_msg": sum(tx.values()) / delivered})
    return pd.DataFrame(out)


def throughput_story(ceiling: pd.DataFrame, raw: pd.DataFrame,
                     arm: pd.DataFrame, out: Path) -> None:
    fig, axes = plt.subplots(1, 4, figsize=(17.0, 4.4), dpi=200)
    ax1, ax2, ax3, ax4 = axes

    ceiling = ceiling.copy()
    ceiling["offered"] = ceiling.msg_sent / ceiling.active_s
    ceiling["carried"] = ceiling.msg_per_s
    g = ceiling.groupby("lanes")[["offered", "carried"]].mean()
    x = np.arange(len(g))
    ax1.bar(x - 0.2, g["offered"], 0.38, color=C4, label="Offered", zorder=3,
            edgecolor=SURFACE, linewidth=1.0)
    ax1.bar(x + 0.2, g["carried"], 0.38, color=C1, label="Carried", zorder=3,
            edgecolor=SURFACE, linewidth=1.0)
    for i, lanes in enumerate(g.index):
        pts = ceiling[ceiling.lanes == lanes]
        ax1.plot(np.full(len(pts), i - 0.2), pts["offered"], "o", markersize=4,
                 color=INK2, alpha=0.7, zorder=4)
        ax1.plot(np.full(len(pts), i + 0.2), pts["carried"], "o", markersize=4,
                 color=INK2, alpha=0.7, zorder=4)
    ax1.set_xticks(x)
    ax1.set_xticklabels([f"{int(v)}" for v in g.index])
    ax1.set_xlabel("Concurrent senders", color=INK2)
    ax1.set_ylabel("Messages/s", color=INK2)
    ax1.set_title("Capacity does not scale", color=INK, fontsize=11, loc="left")
    _despine(ax1)
    ax1.legend(frameon=False, fontsize=8.5, labelcolor=INK2)

    r = ceiling.groupby("lanes")[["rtt_median_ms", "rtt_p90_ms"]].mean()
    ax2.plot(np.arange(len(r)), r["rtt_median_ms"], marker="o", markersize=6,
             linewidth=2, color=C1, label="RTT median", zorder=3)
    ax2.plot(np.arange(len(r)), r["rtt_p90_ms"], marker="o", markersize=6,
             linewidth=2, color=C2, label="RTT p90", zorder=3)
    ax2.axhline(UNSATURATED_RTT_MS, linestyle=":", linewidth=1.4, color=C_RED, zorder=1)
    ax2.annotate(f"unsaturated {UNSATURATED_RTT_MS:.0f} ms", (0, UNSATURATED_RTT_MS * 1.25),
                 fontsize=8.5, color=C_RED)
    ax2.set_yscale("log")
    ax2.set_xticks(np.arange(len(r)))
    ax2.set_xticklabels([f"{int(v)}" for v in r.index])
    ax2.set_xlabel("Concurrent senders", color=INK2)
    ax2.set_ylabel("Round trip (ms, log)", color=INK2)
    ax2.set_title("Bufferbloat, not loss", color=INK, fontsize=11, loc="left")
    _despine(ax2)
    ax2.legend(frameon=False, fontsize=8.5, labelcolor=INK2, loc="upper right")

    order = ["notify", "write", "stripe"]
    means = [raw[raw.leg == leg]["kBps"].mean() for leg in order]
    ax3.bar(np.arange(3), means, 0.55, color=[C1, C2, C_VIOLET], zorder=3,
            edgecolor=SURFACE, linewidth=1.0)
    for i, leg in enumerate(order):
        pts = raw[raw.leg == leg]["kBps"]
        ax3.plot(np.full(len(pts), i), pts, "o", markersize=5, color=INK2,
                 alpha=0.75, zorder=4)
        ax3.annotate(f"n={len(pts)}", (i, means[i]), textcoords="offset points",
                     xytext=(0, 14), ha="center", fontsize=8, color=INK2)
    best = max(means[0], means[1])
    ax3.axhline(best * 2, linestyle=":", linewidth=1.4, color=C_RED, zorder=1)
    ax3.annotate("if the two legs added up", (-0.4, best * 2 * 1.02), fontsize=8.5,
                 color=C_RED)
    ax3.set_xticks(np.arange(3))
    ax3.set_xticklabels(["notify", "write", "stripe"])
    ax3.set_xlabel("GATT leg used", color=INK2)
    ax3.set_ylabel("Received (KB/s)", color=INK2)
    ax3.set_title("Raw pipe: one shared radio", color=INK, fontsize=11, loc="left")
    ax3.set_ylim(0, best * 2 * 1.18)
    _despine(ax3)

    a = arm.groupby("payloadB")["B_per_msg"].mean()
    ax4.bar(np.arange(len(a)), a.values, 0.55, color=C1, zorder=3,
            edgecolor=SURFACE, linewidth=1.0)
    for i, (p, v) in enumerate(a.items()):
        ax4.annotate(f"{v/p:.2f}x", (i, v), textcoords="offset points",
                     xytext=(0, 4), ha="center", fontsize=9, color=INK2)
    ax4.set_xticks(np.arange(len(a)))
    ax4.set_xticklabels([f"{int(p)} B" for p in a.index])
    ax4.set_xlabel("Payload per message", color=INK2)
    ax4.set_ylabel("Sender air bytes per message", color=INK2)
    ax4.set_title("Wire cost is flat in payload", color=INK, fontsize=11, loc="left")
    ax4.set_ylim(0, a.max() * 1.18)
    _despine(ax4)

    fig.suptitle("Laboratory characterization: the same pair at 1 m",
                 color=INK, fontsize=13, x=0.004, ha="left", y=1.04)
    fig.text(0.004, -0.10,
             "Offered = messages/s pushed into the send path; carried = messages/s whose end-to-end acknowledgment came back. "
             "Two trials per configuration, both plotted as dots over the mean —\nthe ceiling is qualitatively unambiguous but the "
             "point estimate is not tight. Raw-pipe rates are counted at the receiver, since the sender's writes complete at enqueue; "
             "one notify and one\nstripe trial never settled a link and are dropped rather than counted as zero.",
             fontsize=7.5, color=INK2)
    fig.tight_layout()
    out.mkdir(parents=True, exist_ok=True)
    fig.savefig(out / "throughput_story.png", bbox_inches="tight", facecolor=SURFACE)
    plt.close(fig)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--field-analysis", default="analysis/cp-line-field/cp-line-1")
    ap.add_argument("--traces", default="data/traces.db")
    ap.add_argument("--out", default="analysis/cp-line-field")
    args = ap.parse_args()

    fa = Path(args.field_analysis)
    line_experiment(pd.read_csv(fa / "establishment.csv"),
                    pd.read_csv(fa / "steps.csv"),
                    (fa / "pathloss.txt").read_text(),
                    Path(args.out))

    # conn = sqlite3.connect(args.traces)
    # raw = raw_pipe(conn)
    # arm = payload_arm(conn)
    # conn.close()
    # ceiling = pd.read_csv("analysis/ceiling-1/steps.csv")
    # throughput_story(ceiling, raw, arm, Path(args.out))

    # print("raw pipe (KB/s at receiver):")
    # print(raw.groupby("leg")["kBps"].agg(["count", "mean", "min", "max"]).round(1).to_string())
    # print("\npayload arm (sender air bytes per message):")
    # a = arm.groupby("payloadB")["B_per_msg"].mean()
    # print(pd.DataFrame({"B_per_msg": a.round(1), "x_payload": (a / a.index).round(2)}).to_string())
    # print("\nceiling (messages/s):")
    # ceiling["offered"] = ceiling.msg_sent / ceiling.active_s
    # print(ceiling.groupby("lanes")[["offered", "msg_per_s", "rtt_median_ms", "rtt_p90_ms"]]
    #       .mean().round(1).to_string())


if __name__ == "__main__":
    main()
