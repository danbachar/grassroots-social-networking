"""Control-plane line-sweep figures for the thesis.

Fetches the two newest exp_line-* upload generations (one per device) from
the trace server, joins the pair by message id, and writes the chapter's
figures next to this script as PDF + PNG, plus summary.csv.

    python3 analyze.py             # newest pair, figures + CSV
    python3 analyze.py --list      # show candidate uploads and exit
    python3 analyze.py --uploads 'exp_line-1.jsonl:123:0' 'exp_line-1.jsonl:456:0'
    python3 analyze.py --until '2026-08-22 10:49:48'   # cut the window (UTC)

Figures:
    fig_establishment  per-trial stack-cold establishment vs distance
    fig_delivery       delivered fraction per direction vs distance
    fig_stages         bt-on -> discovered/GATT/session/usable medians
    fig_control_power  control-plane bytes a trial by class; power
    fig_path_loss      conn-RSSI medians + log-distance fit (Pixel overlay)

Establishment is anchored at the bt-on marker; in this build links-reset and
bt-on stamp in the same second, so the numbers compare directly with the
July Pixel run's links-reset anchor. Delivery counts only traffic between
the analyzed pair: sends to bystander phones (any other session peer in
radio range) are excluded on the message record's peer field.
"""
import argparse, collections, csv, html, json, math, os, re, statistics
import subprocess, sys

DB = "/mnt/HC_Volume_106351660/data/traces.db"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
STEP = re.compile(r"^d=(\d+) t(\d+)$")
PIXEL_FIT = (-36.6, -18.2)  # July Pixel comparator: A, slope (line-field/)


def server(sql):
    out = subprocess.run(["ssh", "trace-server", f"sqlite3 -json {DB} \"{sql}\""],
                         capture_output=True, text=True, timeout=1200)
    if out.returncode != 0:
        sys.exit(f"server query failed: {out.stderr.strip()}")
    return json.loads(out.stdout) if out.stdout.strip() else []


def newest_pair():
    rows = server(
        "select upload_id, device_id, max(id) mx, count(*) n,"
        " datetime(min(t)/1000,'unixepoch') a, datetime(max(t)/1000,'unixepoch') b"
        " from records where upload_id like 'exp_line-%'"
        " group by upload_id, device_id order by mx desc limit 12")
    picked, seen = [], set()
    for r in rows:
        if r["device_id"] in seen:
            continue
        seen.add(r["device_id"])
        picked.append(r)
        if len(picked) == 2:
            break
    return picked, rows


def fetch(upload_id):
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, upload_id.replace("/", "_").replace(":", "_") + ".json")
    if os.path.exists(path):
        return json.load(open(path))
    rows = server(
        "select device_id, t, type, body from records"
        f" where upload_id='{upload_id}'"
        " and type in ('marker','message','rssi','wire','power','link')"
        " order by t, id")
    json.dump(rows, open(path, "w"))
    return rows


def parse(rows, until_ms):
    dev = rows[0]["device_id"] if rows else "?"
    ev = []
    for r in rows:
        b = json.loads(r["body"]) if r["body"] else {}
        t = r["t"] if r["t"] is not None else b.get("t")
        if t is None or t > until_ms:
            continue
        ev.append((t, r["type"], b))
    ev.sort(key=lambda x: x[0])
    return dev, ev


def trials_of(ev):
    marks = [(t, b.get("label", "")) for t, ty, b in ev
             if ty == "marker" and b.get("event") == "note"]
    out, bt = [], None
    for i, (t, lab) in enumerate(marks):
        if lab == "bt-on":
            bt = t
        m = STEP.match(lab)
        if not m:
            continue
        d, tr = int(m.group(1)), int(m.group(2))
        sess = end = None
        for t2, l2 in marks[i + 1:]:
            if l2 == "session-up" and sess is None:
                sess = t2
            elif l2 == "run-end":
                end = t2
                break
            elif STEP.match(l2):
                break
        out.append(dict(d=d, tr=tr, t0=t, bt=bt, sess=sess,
                        end=end if end else t + 30000))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--uploads", nargs=2, metavar="UPLOAD_ID")
    ap.add_argument("--until", help="UTC cutoff 'YYYY-MM-DD HH:MM:SS'")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    if args.list or not args.uploads:
        picked, rows = newest_pair()
        if args.list:
            for r in rows:
                print(f"{r['upload_id']:44s} {r['device_id'][:8]} "
                      f"{r['n']:>7} records  {r['a']}..{r['b']}")
            return
    uploads = args.uploads or [r["upload_id"] for r in picked]
    if len(uploads) < 2:
        sys.exit("need two uploads (one per device); use --list / --uploads")
    until_ms = 4102444800000
    if args.until:
        import datetime as dt
        until_ms = int(dt.datetime.fromisoformat(args.until + "+00:00").timestamp() * 1000)

    sides = []
    for u in uploads:
        dev, ev = parse(fetch(u), until_ms)
        sides.append(dict(u=u, dev=dev, ev=ev, tw=trials_of(ev)))
        print(f"{u}  device {dev[:8]}  {len(ev)} records  {len(sides[-1]['tw'])} trials")
    pair = {s["dev"] for s in sides}
    if len(pair) != 2:
        sys.exit("the two uploads are the same device — pick one per phone")

    # message ledger per side, pair traffic only
    for s in sides:
        other = next(d for d in pair if d != s["dev"])
        sent, ack, recv = {}, {}, []
        for t, ty, b in s["ev"]:
            if ty != "message":
                continue
            if b.get("peer") not in (other, None) and b.get("dir") in ("sent", "ackRx"):
                continue
            d = b.get("dir")
            if d == "sent":
                sent[b["messageId"]] = t
            elif d == "ackRx":
                ack[b["messageId"]] = t
            elif d == "recv":
                recv.append(t)
        s.update(sent=sent, ack=ack, recv=recv)
        s["rssi"] = [(t, b["rssi"]) for t, ty, b in s["ev"]
                     if ty == "rssi" and b.get("src") == "conn" and b.get("peer") == other]
        s["wire"] = [(t, b.get("txBytes", {})) for t, ty, b in s["ev"] if ty == "wire"]
        s["power"] = [(t, b) for t, ty, b in s["ev"] if ty == "power"]
        s["link"] = [(t, b) for t, ty, b in s["ev"] if ty == "link"]

    # per-trial attribution
    for s in sides:
        for w in s["tw"]:
            a, e = w["t0"], w["end"]
            ids = [m for m, t in s["sent"].items() if a <= t < e]
            w["sent"] = len(ids)
            w["acked"] = sum(1 for m in ids if m in s["ack"])
            w["recv"] = sum(1 for t in s["recv"] if a <= t < e + 5000)
            w["rssi"] = [v for t, v in s["rssi"] if a <= t < e]
            w["estab"] = (w["sess"] - w["bt"]) / 1000 if w["sess"] and w["bt"] else None
            w["wire"] = collections.Counter()
            for t, tx in s["wire"]:
                if a <= t < e:
                    for k, v in tx.items():
                        w["wire"][k] += v
            cur = [-b["currentNowUa"] / 1000 for t, b in s["power"]
                   if a <= t < e and not b.get("charging") and b.get("currentNowUa", 0) < 0]
            w["mA"] = statistics.median(cur) if cur else None
            stages = {}
            for t, b in s["link"]:
                evn = b.get("event")
                if evn in ("discovered", "gattConnected", "session", "usable") \
                        and w["bt"] and w["bt"] <= t < e and evn not in stages:
                    stages[evn] = (t - w["bt"]) / 1000
            w["stages"] = stages

    ds = sorted({w["d"] for s in sides for w in s["tw"]})

    def agg(dist):
        ws = [w for s in sides for w in s["tw"] if w["d"] == dist]
        est = [w["estab"] for w in ws if w["estab"] is not None]
        rssi = [v for w in ws for v in w["rssi"]]
        return ws, est, rssi

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 11, "figure.dpi": 110})
    C_A, C_B = "#2b6cb0", "#dd6b20"

    def save(fig, name):
        fig.tight_layout()
        fig.savefig(os.path.join(HERE, f"{name}.pdf"))
        fig.savefig(os.path.join(HERE, f"{name}.png"), dpi=300)
        plt.close(fig)
        print(f"wrote {name}.pdf/.png")

    # 1 — establishment
    fig, ax = plt.subplots(figsize=(7.2, 4.2))
    for dist in ds:
        ws, est, _ = agg(dist)
        ax.scatter([dist] * len(est), est, s=14, alpha=0.5, color=C_A, zorder=3)
        if est:
            ax.scatter([dist], [statistics.median(est)], marker="_", s=110,
                       color="#c53030", linewidths=2.4, zorder=4)
        ax.annotate(f"{len(est)}/{len(ws)}", (dist, 0.3), ha="center",
                    fontsize=8, color="#4a5568")
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("stack-cold establishment (s)")
    ax.set_title("Session establishment per trial (bt-on anchored)")
    ax.set_xticks(ds)
    ax.grid(alpha=0.25)
    ax.set_ylim(bottom=0)
    save(fig, "fig_establishment")

    # 2 — delivery per direction
    fig, ax = plt.subplots(figsize=(7.2, 4.2))
    for s, col, off in zip(sides, (C_A, C_B), (-0.8, 0.8)):
        xs, ys = [], []
        for dist in ds:
            ws = [w for w in s["tw"] if w["d"] == dist]
            snt = sum(w["sent"] for w in ws)
            if snt:
                xs.append(dist)
                ys.append(100 * sum(w["acked"] for w in ws) / snt)
        ax.plot([x + off for x in xs], ys, "o-", color=col, ms=5,
                label=f"{s['dev'][:8]} → peer (acked/sent)")
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("delivered (%)")
    ax.set_title("End-to-end delivery per direction")
    ax.set_xticks(ds)
    ax.set_ylim(0, 104)
    ax.grid(alpha=0.25)
    ax.legend(fontsize=9)
    save(fig, "fig_delivery")

    # 3 — establishment stages
    fig, ax = plt.subplots(figsize=(7.2, 4.2))
    for stage, col in (("discovered", "#718096"), ("gattConnected", "#2b6cb0"),
                       ("session", "#c53030"), ("usable", "#2f855a")):
        xs, ys = [], []
        for dist in ds:
            vals = [w["stages"][stage] for s in sides for w in s["tw"]
                    if w["d"] == dist and stage in w["stages"]]
            if vals:
                xs.append(dist)
                ys.append(statistics.median(vals))
        ax.plot(xs, ys, "o-", ms=4, color=col, label=stage)
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("median seconds after bt-on")
    ax.set_title("Control-plane stages to a usable pair")
    ax.set_xticks(ds)
    ax.grid(alpha=0.25)
    ax.legend(fontsize=9)
    save(fig, "fig_stages")

    # 4 — control-plane bytes a trial + power
    classes = sorted({k for s in sides for w in s["tw"] for k in w["wire"]})
    ctrl = [c for c in classes if c != "secure"]
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(10.5, 4.2))
    bottom = {d: 0.0 for d in ds}
    palette = ["#2b6cb0", "#dd6b20", "#2f855a", "#718096", "#b83280", "#975a16"]
    for c, col in zip(ctrl, palette):
        ys = []
        for dist in ds:
            vals = [w["wire"].get(c, 0) for s in sides for w in s["tw"] if w["d"] == dist]
            ys.append(statistics.median(vals) / 1000 if vals else 0)
        ax1.bar(ds, ys, 6.5, bottom=[bottom[d] for d in ds], label=c, color=col)
        for d, y in zip(ds, ys):
            bottom[d] += y
    ax1.set_xlabel("distance (m)")
    ax1.set_ylabel("kB per trial (median, tx)")
    ax1.set_title("Control plane on the wire")
    ax1.set_xticks(ds)
    ax1.legend(fontsize=8)
    ax1.grid(alpha=0.25, axis="y")
    xs, ys = [], []
    for dist in ds:
        vals = [w["mA"] for s in sides for w in s["tw"] if w["d"] == dist and w["mA"]]
        if vals:
            xs.append(dist)
            ys.append(statistics.median(vals))
    ax2.plot(xs, ys, "o-", color=C_A, ms=5)
    ax2.set_xlabel("distance (m)")
    ax2.set_ylabel("median discharge (mA)")
    ax2.set_title("Power during the dwell")
    ax2.set_xticks(ds)
    ax2.set_ylim(bottom=0)
    ax2.grid(alpha=0.25)
    save(fig, "fig_control_power")

    # 5 — path loss
    med = {}
    for dist in ds:
        _, _, rssi = agg(dist)
        if rssi:
            med[dist] = statistics.median(rssi)
    fig, ax = plt.subplots(figsize=(7.2, 4.2))
    n = A = sigma = None
    if len(med) >= 3:
        xs = [math.log10(d) for d in med]
        ys = list(med.values())
        mx, my = statistics.mean(xs), statistics.mean(ys)
        sl = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / sum((x - mx) ** 2 for x in xs)
        A = my - sl * mx
        n = -sl / 10
        res = [y - (A + sl * x) for x, y in zip(xs, ys)]
        sigma = (sum(r * r for r in res) / max(1, len(res) - 2)) ** 0.5
        dd = [min(med) * 10 ** (i / 40) for i in range(0, 45)]
        ax.plot(dd, [A + sl * math.log10(x) for x in dd], color=C_A, lw=1.2,
                label=f"fit: {A:.1f} − {-sl:.1f}·log₁₀d  (n={n:.2f}, σ={sigma:.1f} dB)")
        ax.plot(dd, [PIXEL_FIT[0] + PIXEL_FIT[1] * math.log10(x) for x in dd],
                ls="--", color="#c53030", lw=1.2, label="Pixel 10 Pro, July (n=1.82)")
    ax.scatter(list(med), list(med.values()), color=C_A, zorder=3, label="median conn-RSSI")
    ax.set_xscale("log")
    ax.set_xticks(ds)
    ax.set_xticklabels(ds)
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("RSSI (dBm)")
    ax.set_title("Path loss")
    ax.grid(alpha=0.25, which="both")
    ax.legend(fontsize=9)
    save(fig, "fig_path_loss")

    # summary CSV + stdout table
    with open(os.path.join(HERE, "summary.csv"), "w", newline="") as f:
        wcsv = csv.writer(f)
        wcsv.writerow(["distance_m", "trials", "sessions", "estab_median_s",
                       "estab_max_s", "sent_AtoB", "acked_AtoB", "sent_BtoA",
                       "acked_BtoA", "rssi_median_dBm", "ctrl_kB_trial", "mA_median"])
        print(f"\n{'d':>4} {'sess':>7} {'estab':>7} {'A→B':>9} {'B→A':>9} {'rssi':>6}")
        for dist in ds:
            ws, est, rssi = agg(dist)
            per_side = []
            for s in sides:
                sws = [w for w in s["tw"] if w["d"] == dist]
                per_side.append((sum(w["sent"] for w in sws),
                                 sum(w["acked"] for w in sws)))
            ctrl_kb = statistics.median(
                [sum(v for k, v in w["wire"].items() if k != "secure") / 1000
                 for w in ws]) if ws else 0
            mas = [w["mA"] for w in ws if w["mA"]]
            wcsv.writerow([dist, len(ws), len(est),
                           round(statistics.median(est), 2) if est else "",
                           round(max(est), 2) if est else "",
                           per_side[0][0], per_side[0][1],
                           per_side[1][0], per_side[1][1],
                           statistics.median(rssi) if rssi else "",
                           round(ctrl_kb, 2),
                           round(statistics.median(mas)) if mas else ""])
            print(f"{dist:>4} {len(est):>3}/{len(ws):<3} "
                  f"{statistics.median(est):>7.2f} " if est else f"{dist:>4} {0:>3}/{len(ws):<3} {'-':>7} ",
                  end="")
            print(f"{per_side[0][1]:>4}/{per_side[0][0]:<4} "
                  f"{per_side[1][1]:>4}/{per_side[1][0]:<4} "
                  f"{statistics.median(rssi) if rssi else float('nan'):>6.1f}")
    if n is not None:
        print(f"\npath loss: n={n:.2f}, A={A:.1f} dBm, σ={sigma:.1f} dB")
    print("wrote summary.csv")


if __name__ == "__main__":
    main()
