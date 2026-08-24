#!/usr/bin/env python3
"""
Field-day (line experiment) figure: what a link actually costs on the air,
per distance step, split into the bytes our protocol puts there and the bytes
the OS radio puts there regardless of us.

Protocol bytes come from the `wire` records (per-type tx byte ledger, summed
over BOTH devices — one side's tx is the other's rx, so summing tx counts each
byte on the air exactly once). Step boundaries come from the runner's step
markers on the mover (`d=<m> <dir> t<k>`).

OS advertising is NOT in the wire ledger — it is emitted by the controller
below the app. It is computed from the measured advertisement, per BLE 4.2
legacy ADV_IND on the three primary channels:

    per channel = 1 preamble + 4 access address + 2 PDU header
                + 6 AdvA + len(AdvData) + 3 CRC
    per event   = 3 x that (one PDU per primary channel)
    per second  = per event / advertising interval

AdvData was dumped with nRF Connect off device adbed3e0 (21 B:
`02 01 02` flags + `11 07 <16-byte service UUID>`); both phones run the same
build with `includeDeviceName=false` and no manufacturer data, so the length
is identical on both and the scan response is empty. Interval 130 ms measured
(the plugin asks for ADVERTISE_MODE_LOW_LATENCY, AOSP nominal 100 ms).

Usage:
    ~/.pyenv/shims/python3 fieldday_figs.py \
        --db data/field.db --est analysis/cp-line-field/cp-line-1/establishment.csv \
        --out analysis/cp-line-field
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

# --- measured advertisement -------------------------------------------------
ADV_DATA_HEX = "02010211071F8047D715B2E0C8ADE571081603C484"
ADV_INTERVAL_S = 0.130
PRIMARY_CHANNELS = 3
PHY_OVERHEAD_B = 1 + 4 + 2 + 6 + 3  # preamble, access addr, PDU hdr, AdvA, CRC
N_ADVERTISERS = 2  # static peer advertises the whole step; mover only while its stack is up
# The plan's dwell — the accounting window for a trial. The marker-to-marker
# span is ~65 s: 30 s dwell + 5 s auto-advance gap + a measured 30.2 s BLE-stack
# bounce (median over 70 steps at d<=70 m, sd 4.8 s) that resetLinks costs the
# mover. Only the dwell is part of a link attempt.
DWELL_S = 30.0

# categorical slots 1/2/3/7/8 of the reference palette (light surface)
C_SECURE = "#2a78d6"
C_ANNOUNCE = "#eb6834"
C_HANDSHAKE = "#1baf7a"
C_SYNC = "#4a3aa7"
C_ADV = "#e34948"
INK = "#0b0b0b"
INK2 = "#52514e"

STEP_RE = re.compile(r"^d=(\d+(?:\.\d+)?)\s+(approach|retreat)\s+t(\d+)$")


def adv_bytes_per_second() -> float:
    adv_len = len(bytes.fromhex(ADV_DATA_HEX))
    per_channel = PHY_OVERHEAD_B + adv_len
    return per_channel * PRIMARY_CHANNELS / ADV_INTERVAL_S


def step_segments(conn: sqlite3.Connection, mover_prefix: str) -> list[dict]:
    rows = conn.execute(
        "SELECT t, body FROM records WHERE type='marker' AND device_id LIKE ? ORDER BY t",
        (mover_prefix + "%",),
    ).fetchall()
    segs: list[dict] = []
    for t, body in rows:
        rec = json.loads(body)
        label = rec.get("label", "")
        m = STEP_RE.match(label)
        if m:
            segs.append({"d": float(m.group(1)), "dir": m.group(2),
                         "trial": int(m.group(3)), "t0": t, "t1": None})
        elif label == "end" or rec.get("event") == "expStop":
            if segs and segs[-1]["t1"] is None:
                segs[-1]["t1"] = t
    for i in range(len(segs) - 1):
        if segs[i]["t1"] is None:
            segs[i]["t1"] = segs[i + 1]["t0"]
    return [s for s in segs if s["t1"]]


def per_step_bytes(conn: sqlite3.Connection, segs: list[dict]) -> pd.DataFrame:
    """Control-plane bytes per trial, charged over the DWELL only.

    A trial's accounting window is the 30 s dwell the plan configures, not the
    marker-to-marker span: the span also carries the 5 s auto-advance gap and
    the ~30 s BLE-stack bounce the runner's resetLinks costs, which are
    experiment scaffolding rather than part of a link attempt. Both radios are
    up for the whole dwell (the bounce lands after it), so the advertising floor
    is a constant per trial.

    Data-plane traffic — sealed messages, their acknowledgments, and the custody
    sync exchange — is deliberately excluded: this figure is what it costs to
    GET a link, not what is then carried over it.
    """
    wire = [(t, json.loads(b)) for t, b in conn.execute(
        "SELECT t, body FROM records WHERE type='wire' ORDER BY t")]
    out = []
    for s in segs:
        t_end = min(s["t0"] + int(DWELL_S * 1000), s["t1"])
        tx: dict[str, float] = defaultdict(float)
        for t, w in wire:
            if s["t0"] <= t < t_end:
                for k, v in (w.get("txBytes") or {}).items():
                    tx[k] += v
        dwell = (t_end - s["t0"]) / 1000.0
        out.append({
            "d": s["d"], "dir": s["dir"], "trial": s["trial"], "dwell_s": dwell,
            "announce": tx.get("announce", 0.0),
            "handshake": tx.get("handshake", 0.0),
            "os_adv": adv_bytes_per_second() * dwell * N_ADVERTISERS,
        })
    return pd.DataFrame(out)


def _despine(ax) -> None:
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color("#d9d8d4")
    ax.tick_params(colors=INK2, length=0)
    ax.grid(axis="y", color="#d9d8d4", linewidth=0.6, zorder=0)
    ax.set_axisbelow(True)


def make_figure(steps: pd.DataFrame, est: pd.DataFrame, out: Path) -> pd.DataFrame:
    cols = ["os_adv", "announce", "handshake", "dwell_s"]
    agg = steps.groupby("d")[cols].mean().reset_index()
    usable = (est.set_index("d")["usable_rate"] * est.set_index("d")["trials"]).round().astype(int)
    trials = est.set_index("d")["trials"].astype(int)
    agg["usable_n"] = agg["d"].map(usable)
    agg["trials"] = agg["d"].map(trials)

    # os_adv stays in the aggregate \u2014 it is the CSV's OS-floor column and the
    # ratio main() prints \u2014 but it is not drawn: it is an analytic constant,
    # identical at every distance, and a flat bar of it crushes the scale of
    # the only thing here that actually varies.
    series = [("announce", "ANNOUNCE", C_ANNOUNCE),
              ("handshake", "Noise handshake", C_HANDSHAKE)]

    fig, ax = plt.subplots(figsize=(9.4, 5.2), dpi=200)
    x = np.arange(len(agg))

    bottom = np.zeros(len(agg))
    for key, label, color in series:
        vals = agg[key].to_numpy(dtype=float) * 1e-3
        ax.bar(x, vals, 0.62, bottom=bottom, label=label, color=color,
               edgecolor="#fcfcfb", linewidth=1.0, zorder=3)
        bottom = bottom + vals

    ax.set_xticks(x)
    ax.set_xticklabels([f"{d:.0f}" for d in agg["d"]])
    ax.set_xlabel("Distance (m)", color=INK2)
    ax.set_ylabel("kB per trial (both devices)", color=INK2)
    ax.set_title("Control plane costs",
                 color=INK, fontsize=13, loc="left", pad=26)
    _despine(ax)
    ax.set_ylim(0, bottom.max() * 1.2)

    for xi, row in zip(x, agg.itertuples()):
        ax.annotate(f"{row.usable_n}/{row.trials}", (xi, 1.0),
                    xycoords=("data", "axes fraction"),
                    textcoords="offset points", xytext=(0, 6), ha="center",
                    fontsize=8, color=INK2)
    ax.annotate("usable", (0, 1.0), xycoords=("data", "axes fraction"),
                textcoords="offset points", xytext=(-26, 6), ha="right",
                fontsize=8, color=INK2)

    ax.legend(frameon=False, ncol=2, loc="upper center", fontsize=9,
              labelcolor=INK2, bbox_to_anchor=(0.5, -0.12), columnspacing=1.6,
              handlelength=1.2, handleheight=0.9)
    fig.tight_layout()
    out.mkdir(parents=True, exist_ok=True)
    fig.savefig(out / "fieldday_establish_bytes.png", bbox_inches="tight",
                facecolor="#fcfcfb")
    plt.close(fig)
    agg.to_csv(out / "fieldday_establish_bytes.csv", index=False)
    return agg


def make_time_figure(est_steps: pd.DataFrame, out: Path) -> pd.DataFrame:
    """Establishment latency vs distance, per stage, from the analyzer's steps.csv.

    Every value is conditional on reaching the stage — failed trials are absent,
    not infinite — and right-censored by the step dwell, so both are annotated.
    """
    stages = [("t_discovered_s", "Discovered", C_HANDSHAKE),
              ("t_session_s", "Noise session up", C_ANNOUNCE),
              ("t_usable_s", "Usable (first ACK back)", C_SECURE)]
    rows = []
    for d, g in est_steps.groupby("d"):
        row = {"d": d, "trials": len(g)}
        for key, _, _ in stages:
            v = g[key].dropna()
            row[f"n_{key}"] = len(v)
            row[f"mean_{key}"] = v.mean() if len(v) else np.nan
            row[f"median_{key}"] = v.median() if len(v) else np.nan
            row[f"sem_{key}"] = v.std(ddof=1) / np.sqrt(len(v)) if len(v) > 1 else np.nan
        rows.append(row)
    tt = pd.DataFrame(rows).sort_values("d").reset_index(drop=True)

    fig, ax = plt.subplots(figsize=(9.4, 5.2), dpi=200)
    for key, label, color in stages:
        ax.plot(tt["d"], tt[f"mean_{key}"], linewidth=2.4, color=color, zorder=3)
        ax.errorbar(tt["d"], tt[f"mean_{key}"], yerr=tt[f"sem_{key}"],
                    fmt="o", markersize=7, capsize=3, linewidth=1.6,
                    color=color, label=label, zorder=4)
    _despine(ax)
    ax.set_xticks(tt["d"])
    ax.set_xlabel("Distance (m)", color=INK2)
    ax.set_ylabel("Control plane establishment time (s)", color=INK2)
    ax.set_ylim(0, 75)

    for _, r in tt.iterrows():
        n = int(r["n_t_usable_s"])
        ax.annotate(f"{n}/{int(r['trials'])}", (r["d"], 1.0),
                    xycoords=("data", "axes fraction"), textcoords="offset points",
                    xytext=(0, 6), ha="center", fontsize=8,
                    color=INK2 if n else C_ADV)
    ax.annotate("usable", (tt["d"].iloc[0], 1.0), xycoords=("data", "axes fraction"),
                textcoords="offset points", xytext=(-26, 6), ha="right",
                fontsize=8, color=INK2)

    ax.legend(frameon=False, ncol=3, loc="upper center", fontsize=9,
              labelcolor=INK2, bbox_to_anchor=(0.5, -0.12), columnspacing=1.6,
              handlelength=1.6)
    # fig.text(0.01, -0.16,
    #          "Means are over the trials that REACHED the stage (10 attempted per distance); failures are\n"
    #          "excluded, not counted as infinite, so every point is a lower bound — increasingly so with\n"
    #          "distance. Also right-censored: nothing longer than the step (62-106 s) could be observed.\n"
    #          "At 80 m only 2/10 reached any stage and 0/10 became usable; at 100 m nothing was discovered.",
    #          fontsize=7.5, color=INK2)
    fig.tight_layout()
    out.mkdir(parents=True, exist_ok=True)
    fig.savefig(out / "fieldday_establish_time.png", bbox_inches="tight",
                facecolor="#fcfcfb")
    plt.close(fig)
    tt.to_csv(out / "fieldday_establish_time.csv", index=False)
    return tt


def make_power_figure(conn: sqlite3.Connection, segs: list[dict], out: Path) -> pd.DataFrame:
    """Battery behaviour over the run — device-level only, deliberately.

    The fuel gauge measures the WHOLE handset (screen at max brightness for the
    entire field day), so nothing here isolates the radio. Two things are
    defensible from it: how much charge the run actually cost each role, and
    whether the draw depends on distance. Level-vs-time is not plotted — it is
    the same fact as cumulative charge, quantised to 1% steps and rescaled by a
    capacity the gauge only estimates.
    Charging samples are excluded; both phones ran unplugged throughout.
    """
    rows = [(d[:8], json.loads(b)) for d, b in conn.execute(
        "SELECT device_id, body FROM records WHERE type='power' ORDER BY t")]
    df = pd.DataFrame([{**r, "dev": d} for d, r in rows])
    df = df[~df["charging"].fillna(False).astype(bool)].copy()
    roles = {"ba2af95f": "mover (sends)", "adbed3e0": "static (receives)"}
    colors = {"ba2af95f": C_SECURE, "adbed3e0": C_ANNOUNCE}

    fig, (ax2, ax3) = plt.subplots(1, 2, figsize=(9.4, 4.4), dpi=200)
    summary = []
    for dev, g in df.groupby("dev"):
        g = g.sort_values("t")
        hours = (g["t"] - g["t"].iloc[0]) / 3.6e6
        mAh = (g["chargeCounterUah"].iloc[0] - g["chargeCounterUah"]) / 1000.0
        mA = -g["currentNowUa"] / 1000.0
        label, color = roles.get(dev, dev), colors.get(dev, INK2)
        ax2.plot(hours, mAh, linewidth=2, color=color, label=label, zorder=3)
        cap = float(np.median(g["chargeCounterUah"] / 1000.0 / (g["levelPct"] / 100.0)))
        summary.append({"dev": dev, "role": label, "hours": float(hours.iloc[-1]),
                        "level_from": int(g["levelPct"].iloc[0]),
                        "level_to": int(g["levelPct"].iloc[-1]),
                        "mAh_used": float(mAh.iloc[-1]), "mean_mA": float(mA.mean()),
                        "capacity_mAh": cap, "runtime_h": cap / mA.mean()})

    ax2.set_xlabel("Elapsed (h)", color=INK2)
    ax2.set_ylabel("Charge drawn since start (mAh)", color=INK2)
    # ax2.set_title("Cumulative charge drawn", color=INK, fontsize=11, loc="left")
    _despine(ax2)
    ax2.legend(frameon=False, fontsize=8.5, labelcolor=INK2, loc="upper left")

    # Per-step mean draw, to show the absence of a distance effect rather than
    # to claim a radio number.
    per = []
    for s in segs:
        end = s["t0"] + int(DWELL_S * 1000)
        w = df[(df["t"] >= s["t0"]) & (df["t"] < end)]
        for dev, g in w.groupby("dev"):
            per.append({"d": s["d"], "dev": dev, "mA": float((-g["currentNowUa"] / 1000).mean())})
    pdf = pd.DataFrame(per).dropna()
    for dev, g in pdf.groupby("dev"):
        m = g.groupby("d")["mA"].agg(["mean", "sem"])
        ax3.errorbar(m.index, m["mean"], yerr=m["sem"], marker="o", markersize=6,
                     capsize=3, linewidth=2, color=colors.get(dev, INK2),
                     label=roles.get(dev, dev), zorder=3)
    ax3.set_xticks(sorted(pdf["d"].unique()))
    ax3.set_xlabel("Distance (m)", color=INK2)
    ax3.set_ylabel("Mean draw during dwell (mA)", color=INK2)
    # ax3.set_title("Draw vs. distance", color=INK, fontsize=11, loc="left")
    ax3.set_ylim(0, max(500, pdf["mA"].max() * 1.15))
    _despine(ax3)
    ax3.legend(frameon=False, fontsize=8.5, labelcolor=INK2, loc="lower left")

    # fig.suptitle("Battery over the field day (whole device, screen on throughout)",
    #              color=INK, fontsize=13, x=0.005, ha="left", y=1.03)
    # fig.text(0.005, -0.13,
    #          "The fuel gauge measures the entire handset with the screen at maximum brightness, which dominates every "
    #          "number here; none of it isolates\nthe BLE radio, and no per-component attribution is claimed. The static "
    #          "peer is flat across distance. The mover declines ~20% over the\nsweep — which is also the order in which "
    #          "it stopped being able to send, but distance advances monotonically with elapsed time here, so\nbattery "
    #          "state and thermals are equally consistent with it. It is reported as an unresolved observation, not a "
    #          "radio measurement.",
    #          fontsize=7.5, color=INK2)
    fig.tight_layout()
    out.mkdir(parents=True, exist_ok=True)
    fig.savefig(out / "fieldday_power.png", bbox_inches="tight", facecolor="#fcfcfb")
    plt.close(fig)
    sdf = pd.DataFrame(summary)
    sdf.to_csv(out / "fieldday_power.csv", index=False)
    return sdf


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default="data/field.db")
    ap.add_argument("--est", default="analysis/cp-line-field/cp-line-1/establishment.csv")
    ap.add_argument("--steps", default="analysis/cp-line-field/cp-line-1/steps.csv",
                    help="analyzer steps.csv — source of the per-stage latencies")
    ap.add_argument("--out", default="analysis/cp-line-field")
    ap.add_argument("--mover", default="ba2af95f", help="device id prefix carrying step markers")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    segs = step_segments(conn, args.mover)
    steps = per_step_bytes(conn, segs)
    conn.close()
    est = pd.read_csv(args.est)
    agg = make_figure(steps, est, Path(args.out))
    tt = make_time_figure(pd.read_csv(args.steps), Path(args.out))
    conn = sqlite3.connect(args.db)
    pw = make_power_figure(conn, step_segments(conn, args.mover), Path(args.out))
    conn.close()

    print(f"adv air rate: {adv_bytes_per_second():.1f} B/s per advertiser "
          f"({adv_bytes_per_second()*N_ADVERTISERS:.1f} B/s for two)")
    show = agg.copy()
    show["protocol"] = show[["announce", "handshake"]].sum(axis=1)
    show["adv_share"] = show["os_adv"] / (show["os_adv"] + show["protocol"])
    print(show.round(1).to_string(index=False))
    print()
    print(tt.round(2).to_string(index=False))
    print()
    print(pw.round(1).to_string(index=False))


if __name__ == "__main__":
    main()
