"""Control-plane line-sweep figures for the thesis.

Fetches line-sweep uploads from the trace server, joins the pair by message
id, and writes the chapter's figures next to this script as PDF + PNG, plus
summary.csv.

    python3 analyze.py                       # newest pair on the server
    python3 analyze.py --list                # candidate uploads, then exit
    python3 analyze.py --uploads A B         # pin the two upload ids
    python3 analyze.py --until '2026-08-22 10:49:48'    # cut the window (UTC)

Figures:
    fig_establishment   per-trial stack-cold establishment, per device
    fig_delivery        delivered fraction per direction
    fig_stages          bt-on -> discovered / GATT / session / usable
    fig_control_bytes   control-plane bytes a trial by class, data overlaid
    fig_power           discharge current during the dwell
    fig_path_loss       conn-RSSI medians + log-distance fit, Pixel overlay

Establishment is anchored at the bt-on marker; in this build links-reset and
bt-on stamp within the same second, so the numbers compare directly with the
July Pixel run's links-reset anchor.

Delivery is measured from whichever side recorded it. A sender's own file is
authoritative (it holds sent and the end-to-end ackRx). Where a sender's file
is missing — a phone that crashed mid-run loses everything since its last
flush — the direction is reconstructed from the RECEIVER's receipts, with the
denominator taken from the per-trial send rate observed on the recording side
(the plan is symmetric). Those points are drawn hollow and named INFERRED in
the legend and the CSV; they are a floor, since a message lost in flight is
invisible to both files.

Only traffic between the analyzed pair is counted: sends to bystander phones
in radio range are excluded on the message record's peer field.
"""
import argparse, collections, csv, json, math, os, re, statistics, subprocess, sys

DB = "/mnt/HC_Volume_106351660/data/traces.db"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
STEP = re.compile(r"^d=(\d+) t(\d+)$")
PIXEL_FIT = (-36.6, -18.2)      # July Pixel comparator (line-field/README.md)
# The plane split follows one test: does the traffic exist when no user
# message does? ANNOUNCE, the handshake and the sync filter all flow on the
# announce cycle regardless of load — control plane. End-to-end ACKs exist
# only because a payload does and scale one-to-one with them — data-plane
# overhead, not control.
CTRL_ORDER = ["announce", "handshake", "secure:sync"]
ACK_CLASS = "secure:ack"
BIN = 3          # dB, width of an RSSI bin in fig_delivery_vs_rssi
MIN_N = 5        # messages a bin needs before its proportion is plotted
BOX_MIN_SENDS = 10   # messages a trial needs before per-trial rates are boxed
DATA_CLASS = "secure"


def server(sql):
    out = subprocess.run(["ssh", "trace-server", f"sqlite3 -json {DB} \"{sql}\""],
                         capture_output=True, text=True, timeout=1800)
    if out.returncode != 0:
        sys.exit(f"server query failed: {out.stderr.strip()}")
    return json.loads(out.stdout) if out.stdout.strip() else []


FILE = "substr(upload_id, 1, instr(upload_id, '.jsonl') + 5)"


def experiments(like="exp_line-%"):
    """One row per (run file, device).

    A large run is stored in 20 000-record chunks whose upload_ids differ only
    in a trailing index, so an upload_id is a slice of one phone's run and
    never the run itself — and picking devices off the newest rows finds only
    the phone that uploaded last.
    """
    return server(
        f"select {FILE} f, device_id, count(*) n,"
        " count(distinct upload_id) chunks, max(id) mx,"
        " datetime(min(t)/1000,'unixepoch') a,"
        " datetime(max(t)/1000,'unixepoch') b"
        f" from records where upload_id like '{like}'"
        " group by f, device_id order by mx desc")


def fetch(fname, device):
    """Every chunk this device uploaded for this run, in time order."""
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(
        CACHE, re.sub(r"[/:.]", "_", f"{fname}_{device[:8]}") + "_full.json")
    if os.path.exists(path):
        return json.load(open(path))
    rows = server(
        "select device_id, t, type, body from records"
        f" where upload_id like '{fname}:%' and device_id='{device}'"
        " and type in ('marker','message','rssi','wire','power','link')"
        " order by t, id")
    json.dump(rows, open(path, "w"))
    return rows



def parse(rows, until_ms):
    dev, ev = (rows[0]["device_id"] if rows else "?"), []
    for r in rows:
        b = json.loads(r["body"]) if r["body"] else {}
        t = r["t"] if r["t"] is not None else b.get("t")
        if t is not None and t <= until_ms:
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
        sess = end = None
        for t2, l2 in marks[i + 1:]:
            if l2 == "session-up" and sess is None:
                sess = t2
            elif l2 == "run-end":
                end = t2
                break
            elif STEP.match(l2):
                break
        out.append(dict(d=int(m.group(1)), tr=int(m.group(2)), t0=t, bt=bt,
                        sess=sess, end=end if end else t + 30000))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--exp", help="experiment id, e.g. line-20")
    ap.add_argument("--devices", help="comma-separated device-id prefixes, "
                    "for a file name reused by a different pair")
    ap.add_argument("--until", help="UTC cutoff 'YYYY-MM-DD HH:MM:SS'")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    like = f"exp_{args.exp}.jsonl%" if args.exp else "exp_line-%"
    rows = experiments(like)
    if not rows:
        sys.exit(f"no uploads matching {like}")
    if args.list:
        for r in rows:
            print(f"{r['f']:30s} {r['device_id'][:8]} {r['n']:>8} records "
                  f"in {r['chunks']:>3} chunks  {r['a']}..{r['b']}")
        return
    if args.devices:
        want = tuple(args.devices.split(","))
        rows = [r for r in rows if r["device_id"].startswith(want)]
    fname = rows[0]["f"]
    mine = [r for r in rows if r["f"] == fname]
    if len(mine) < 2:
        sys.exit(f"{fname} has only {len(mine)} device uploaded — the other "
                 "phone has not uploaded yet (see --list)")
    until_ms = 4102444800000
    if args.until:
        import datetime as dt
        until_ms = int(dt.datetime.fromisoformat(args.until + "+00:00")
                       .timestamp() * 1000)

    sides = []
    for r in mine[:2]:
        print(f"loading {r['device_id'][:8]}: {r['n']} records across "
              f"{r['chunks']} chunks ...", flush=True)
        dev, ev = parse(fetch(fname, r["device_id"]), until_ms)
        sides.append(dict(u=fname, dev=dev, ev=ev, tw=trials_of(ev)))
        print(f"  {dev[:8]}: {len(ev)} records, {len(sides[-1]['tw'])} trials")
    if len({s["dev"] for s in sides}) != 2:
        sys.exit("both uploads are the same device — pick one per phone")
    sides.sort(key=lambda s: -len(s["tw"]))     # the fuller recording first

    for s in sides:
        other = next(x["dev"] for x in sides if x["dev"] != s["dev"])
        sent, ack, recv, recv_ids = {}, {}, [], set()
        for t, ty, b in s["ev"]:
            if ty != "message":
                continue
            d = b.get("dir")
            if d in ("sent", "ackRx") and b.get("peer") not in (other, None):
                continue          # traffic with a bystander phone in range
            if d == "sent":
                sent[b["messageId"]] = t
            elif d == "ackRx":
                ack[b["messageId"]] = t
            elif d == "recv":
                recv.append(t)
                recv_ids.add(b["messageId"])
        s.update(sent=sent, ack=ack, recv=recv, recv_ids=recv_ids)
        s["rssi"] = [(t, b["rssi"]) for t, ty, b in s["ev"]
                     if ty == "rssi" and b.get("src") == "conn" and b.get("peer") == other]
        s["wire"] = [(t, b.get("txBytes") or {}) for t, ty, b in s["ev"] if ty == "wire"]
        s["power"] = [(t, b) for t, ty, b in s["ev"] if ty == "power"]
        s["link"] = [(t, b) for t, ty, b in s["ev"] if ty == "link"]

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
            st = {}
            for t, b in s["link"]:
                n = b.get("event")
                if n not in ("discovered", "gattConnected", "identified",
                             "connected", "session", "usable"):
                    continue
                # Peer-scope everything that names a peer. gattConnected does
                # not: a GATT link exists before identity does, so a leg the
                # PEER dialled lands before its advertisement is ever seen.
                if b.get("peer") and b["peer"] != other:
                    continue
                if w["bt"] and w["bt"] <= t < e and n not in st:
                    st[n] = (t - w["bt"]) / 1000
            w["stages"] = st

    # Per-message outcome against the RSSI at the moment it was sent.
    # acked  = the originator saw the end-to-end ACK come back
    # arrived = the RECEIVER's file logs that message id (cross-file, so it
    #           exists only where the receiver's recording survived)
    for s in sides:
        # What span of wall-clock this side's recording actually covers. A
        # message sent outside the PEER's coverage has no arrival evidence
        # either way — a phone that crashed logs nothing, which must read as
        # unknown and never as "did not arrive".
        s["cover"] = (s["ev"][0][0], s["ev"][-1][0]) if s["ev"] else (1, 0)
    for s in sides:
        peer = next(x for x in sides if x["dev"] != s["dev"])
        lo, hi = peer["cover"]
        # RSSI samples are far sparser than messages, so a send takes the
        # nearest sample measured at the SAME position rather than only one
        # inside its own trial — the phone has not moved between trials.
        by_d = collections.defaultdict(list)
        for w in s["tw"]:
            for t, v in s["rssi"]:
                if w["t0"] <= t < w["end"]:
                    by_d[w["d"]].append((t, v))
        s["msgs"] = []
        for w in s["tw"]:
            band = by_d.get(w["d"]) or []
            for mid, t in s["sent"].items():
                if not (w["t0"] <= t < w["end"]) or not band:
                    continue
                s["msgs"].append(dict(
                    d=w["d"], trial=(s["dev"], w["tr"]),
                    rssi=min(band, key=lambda x: abs(x[0] - t))[1],
                    acked=mid in s["ack"],
                    arrived=(mid in peer["recv_ids"]) if lo <= t <= hi else None))

    ds = sorted({w["d"] for s in sides for w in s["tw"]})

    def at(s, dist):
        return [w for w in s["tw"] if w["d"] == dist]

    def direction(sender, receiver, dist):
        """(delivered, offered, inferred) for sender -> receiver at dist."""
        sw = at(sender, dist)
        if sw and sum(w["sent"] for w in sw):
            return sum(w["acked"] for w in sw), sum(w["sent"] for w in sw), False
        rw = at(receiver, dist)
        got = sum(w["recv"] for w in rw)
        rate = [w["sent"] for w in rw if w["sent"]]
        if not rw or not rate:
            return None, None, True
        return got, round(statistics.median(rate)) * len(rw), True

    def fisher(a, b, c, d):
        """Two-sided Fisher exact p for a 2x2 table. Exact rather than a
        chi-square because the failure counts are single digits."""
        from math import comb
        n = a + b + c + d
        if not n or not (a + c) or not (b + d):
            return 1.0
        obs = comb(a + b, a) * comb(c + d, c) / comb(n, a + c)
        p = 0.0
        for i in range(min(a + b, a + c) + 1):
            k2, l = a + c - i, c + d - (a + c - i)
            if k2 < 0 or l < 0 or a + b - i < 0:
                continue
            pr = comb(a + b, i) * comb(c + d, k2) / comb(n, a + c)
            if pr <= obs + 1e-12:
                p += pr
        return min(1.0, p)

    def wilson(k, n, z=1.96):
        """95% CI for a binomial proportion — the right error bar for a
        yes/no outcome. A per-trial percentage box plot is not: at two
        messages a trial it can only take the values 0, 50 and 100."""
        if not n:
            return 0.0, 0.0, 0.0
        p = k / n
        d = 1 + z * z / n
        c = (p + z * z / (2 * n)) / d
        h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
        return 100 * p, 100 * max(0.0, c - h), 100 * min(1.0, c + h)

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"font.size": 11, "figure.dpi": 110})
    COL = ["#2b6cb0", "#dd6b20"]

    def save(fig, name):
        fig.tight_layout()
        fig.savefig(os.path.join(HERE, f"{name}.pdf"))
        fig.savefig(os.path.join(HERE, f"{name}.png"), dpi=300)
        plt.close(fig)
        print(f"wrote {name}.pdf/.png")

    # 1 — establishment, per device
    fig, ax = plt.subplots(figsize=(7.6, 4.3))
    span = max(ds) - min(ds) if len(ds) > 1 else 10
    jit = span / len(ds) / 6
    for s, col, off in zip(sides, COL, (-jit, jit)):
        xs = [w["d"] + off for w in s["tw"] if w["estab"] is not None]
        ys = [w["estab"] for w in s["tw"] if w["estab"] is not None]
        ax.scatter(xs, ys, s=15, alpha=0.55, color=col, zorder=3,
                   label=f"{s['dev'][:8]} ({len(ys)}/{len(s['tw'])} sessions)")
        mx = [(d, statistics.median([w["estab"] for w in at(s, d)
                                     if w["estab"] is not None]))
              for d in ds if any(w["estab"] is not None for w in at(s, d))]
        ax.plot([d + off for d, _ in mx], [m for _, m in mx], color=col, lw=1.1,
                alpha=0.85)
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("stack-cold establishment (s)")
    ax.set_title("Session establishment per trial (anchored at bt-on)")
    ax.set_xticks(ds)
    ax.grid(alpha=0.25)
    ax.set_ylim(bottom=0)
    ax.legend(fontsize=9, title="lines are per-distance medians", title_fontsize=8)
    save(fig, "fig_establishment")

    # 2 — delivery per direction
    fig, ax = plt.subplots(figsize=(7.6, 4.3))
    for (a, b), col in zip(((0, 1), (1, 0)), COL):
        solid_x, solid_y, inf_x, inf_y = [], [], [], []
        for dist in ds:
            got, off_, inferred = direction(sides[a], sides[b], dist)
            if got is None or not off_:
                continue
            (inf_x if inferred else solid_x).append(dist)
            (inf_y if inferred else solid_y).append(100 * got / off_)
        lbl = f"{sides[a]['dev'][:8]} → {sides[b]['dev'][:8]}"
        if solid_x:
            ax.plot(solid_x, solid_y, "o-", color=col, ms=5, label=lbl)
        if inf_x:
            ax.plot(inf_x, inf_y, "o--", color=col, ms=6, mfc="white", mew=1.4,
                    label=f"{lbl} — INFERRED from receipts")
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("delivered (%)")
    ax.set_title("End-to-end delivery per direction")
    ax.set_xticks(ds)
    ax.set_ylim(0, 104)
    ax.grid(alpha=0.25)
    ax.legend(fontsize=9, loc="lower left")
    save(fig, "fig_delivery")

    # 3 — stages
    fig, ax = plt.subplots(figsize=(7.6, 4.3))
    for stage, col, name in (
            ("gattConnected", "#2b6cb0", "GATT link up (anonymous)"),
            ("discovered", "#718096", "peer ANNOUNCE seen"),
            ("identified", "#b7791f", "identified (ANNOUNCE bound to the path)"),
            ("connected", "#6b46c1", "path ready (MTU negotiated, subscribed)"),
            ("session", "#c53030", "Noise session"),
            ("usable", "#2f855a", "pair usable (first payload acked)")):
        xs, ys = [], []
        for dist in ds:
            v = [w["stages"][stage] for s in sides for w in at(s, dist)
                 if stage in w["stages"]]
            if v:
                xs.append(dist)
                ys.append(statistics.median(v))
        if xs:
            print(f"stage {stage:14s} median-of-medians "
                  f"{statistics.median(ys):.2f} s")
            # discovered and identified are near-coincident — the same
            # ANNOUNCE both reveals and authenticates the peer — so the
            # earlier one is drawn dashed with open markers to stay visible
            # under the later one.
            if stage == "discovered":
                ax.plot(xs, ys, "o--", ms=8, mfc="none", mew=1.6, lw=1.2,
                        color=col, label=name)
            else:
                ax.plot(xs, ys, "o-", ms=4, color=col, label=name)
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("median seconds after bt-on")
    ax.set_title("Control-plane stages to a usable pair")
    ax.text(0.01, -0.235, "GATT can precede discovery: the leg the peer dials "
            "lands before its advertisement is seen.", transform=ax.transAxes,
            fontsize=8, color="#4a5568")
    ax.set_xticks(ds)
    ax.grid(alpha=0.25)
    ax.legend(fontsize=9)
    save(fig, "fig_stages")

    # 4 — control bytes by class, with the data plane overlaid
    present = [c for c in CTRL_ORDER
               if any(w["wire"].get(c) for s in sides for w in s["tw"])]
    fig, ax = plt.subplots(figsize=(7.6, 4.3))
    bottom = {d: 0.0 for d in ds}
    palette = ["#2b6cb0", "#dd6b20", "#718096", "#2f855a", "#b83280"]
    width = (span / len(ds)) * 0.62 if len(ds) > 1 else 6
    for c, col in zip(present, palette):
        ys = []
        for dist in ds:
            v = [w["wire"].get(c, 0) for s in sides for w in at(s, dist)]
            ys.append(statistics.median(v) / 1000 if v else 0)
        ax.bar(ds, ys, width, bottom=[bottom[d] for d in ds], label=c, color=col)
        for d, y in zip(ds, ys):
            bottom[d] += y
    dat, ack = [], []
    for dist in ds:
        v = [w["wire"].get(DATA_CLASS, 0) for s in sides for w in at(s, dist)]
        dat.append(statistics.median(v) / 1000 if v else 0)
        v = [w["wire"].get(ACK_CLASS, 0) for s in sides for w in at(s, dist)]
        ack.append(statistics.median(v) / 1000 if v else 0)
    ax.plot(ds, dat, "k^--", ms=5, lw=1.2, label="payload (data plane)")
    ax.plot(ds, ack, "kv:", ms=5, lw=1.2, label="acks (data plane)")
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("kB transmitted per trial (median)")
    ax.set_title("Control plane on the wire, by packet class")
    ax.set_xticks(ds)
    ax.grid(alpha=0.25, axis="y")
    ax.set_ylim(0, max(bottom.values()) * 1.34)
    ax.legend(fontsize=9, ncol=3, loc="upper center", framealpha=0.95)
    ctrl_tot = statistics.median(list(bottom.values()))
    dat_tot = statistics.median(dat)
    if dat_tot:
        ax.set_xlabel(f"distance (m)          control : data = "
                      f"{ctrl_tot / dat_tot:.1f} : 1 at this load")
    save(fig, "fig_control_bytes")

    # 5 — power
    fig, ax = plt.subplots(figsize=(7.6, 4.0))
    for s, col in zip(sides, COL):
        xs, ys = [], []
        for dist in ds:
            v = [w["mA"] for w in at(s, dist) if w["mA"]]
            if v:
                xs.append(dist)
                ys.append(statistics.median(v))
        if xs:
            ax.plot(xs, ys, "o-", color=col, ms=5, label=s["dev"][:8])
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("median discharge during dwell (mA)")
    ax.set_title("Power")
    ax.set_xticks(ds)
    ax.set_ylim(bottom=0)
    ax.grid(alpha=0.25)
    ax.legend(fontsize=9)
    save(fig, "fig_power")

    # 6 — path loss
    med = {}
    for dist in ds:
        v = [x for s in sides for w in at(s, dist) for x in w["rssi"]]
        if v:
            med[dist] = statistics.median(v)
    fig, ax = plt.subplots(figsize=(7.6, 4.3))
    n = A = sigma = None
    if len(med) >= 3:
        xs = [math.log10(d) for d in med]
        ys = list(med.values())
        mx, my = statistics.mean(xs), statistics.mean(ys)
        sl = sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / \
            sum((x - mx) ** 2 for x in xs)
        A, n = my - sl * mx, -sl / 10
        res = [y - (A + sl * x) for x, y in zip(xs, ys)]
        sigma = (sum(r * r for r in res) / max(1, len(res) - 2)) ** 0.5
        dd = [min(med) * 10 ** (i / 40) for i in range(46)]
        ax.plot(dd, [A + sl * math.log10(x) for x in dd], color=COL[0], lw=1.3,
                label=f"fit: {A:.1f} − {-sl:.1f}·log₁₀d   n={n:.2f}, σ={sigma:.1f} dB")
        ax.plot(dd, [PIXEL_FIT[0] + PIXEL_FIT[1] * math.log10(x) for x in dd],
                "--", color="#c53030", lw=1.2, label="Pixel 10 Pro, July (n=1.82)")
    ax.scatter(list(med), list(med.values()), color=COL[0], zorder=3,
               label="median conn-RSSI")
    ax.set_xscale("log")
    ax.set_xticks(ds)
    ax.set_xticklabels(ds)
    ax.set_xlabel("distance (m)")
    ax.set_ylabel("RSSI (dBm)")
    ax.set_title("Path loss")
    ax.grid(alpha=0.25, which="both")
    ax.legend(fontsize=9)
    save(fig, "fig_path_loss")

    # 7 — data-plane outcome against RSSI, and how RSSI groups by distance
    allm = [m for s in sides for m in s["msgs"]]
    if allm:
        fig, (axb, axp) = plt.subplots(2, 1, figsize=(8.0, 7.4),
                                       gridspec_kw={"height_ratios": [1, 1.25]})
        # (a) RSSI per distance — the overlap question, answered visually
        data = [[x for s in sides for w in at(s, d) for x in w["rssi"]] for d in ds]
        keep = [(d, v) for d, v in zip(ds, data) if v]
        bp = axb.boxplot([v for _, v in keep], positions=[d for d, _ in keep],
                         widths=(span / len(ds)) * 0.55, patch_artist=True,
                         medianprops=dict(color="#c53030", lw=1.6))
        for b_ in bp["boxes"]:
            b_.set(facecolor="#bee3f8", edgecolor="#2b6cb0", alpha=0.9)
        pairs = [(a, b_) for i, a in enumerate(keep) for b_ in keep[i + 1:]]
        def iqr(v):
            q = statistics.quantiles(sorted(v), n=4)
            return q[0], q[2]
        nov = sum(1 for (_, va), (_, vb) in pairs
                  if iqr(va)[0] <= iqr(vb)[1] and iqr(vb)[0] <= iqr(va)[1])
        axb.set_xlabel("distance (m)")
        axb.set_ylabel("conn-RSSI (dBm)")
        axb.set_title(f"RSSI by distance — {nov} of {len(pairs)} distance pairs "
                      f"overlap in IQR")
        axb.set_xticks([d for d, _ in keep])
        axb.set_xticklabels([d for d, _ in keep])
        axb.grid(alpha=0.25, axis="y")

        # (b) delivered / acked against RSSI, Wilson 95% CI
        lo = int(math.floor(min(m["rssi"] for m in allm) / BIN) * BIN)
        hi = int(math.ceil(max(m["rssi"] for m in allm) / BIN) * BIN)
        bins = list(range(lo, hi + BIN, BIN))
        series = (("arrived", "arrived at the receiver", "#2b6cb0", -BIN * 0.16),
                  ("acked", "end-to-end ACK returned", "#dd6b20", BIN * 0.16))
        # With a handful of messages a trial, a per-trial percentage can only
        # be 0, 50 or 100 and a box plot of it says nothing. Box plots are
        # drawn once a trial carries enough messages for its own rate to mean
        # something; below that the pooled proportion with a Wilson interval
        # is the honest summary.
        per_trial = statistics.median([w["sent"] for s in sides for w in s["tw"]
                                       if w["sent"]] or [0])
        boxes = per_trial >= BOX_MIN_SENDS
        for key, name, col, off in series:
            xs, ys, el, eh, ns, rates = [], [], [], [], [], []
            for b0 in bins:
                sel = [m for m in allm if b0 <= m["rssi"] < b0 + BIN
                       and m[key] is not None]
                if len(sel) < MIN_N:
                    continue
                k = sum(1 for m in sel if m[key])
                p, l, h = wilson(k, len(sel))
                xs.append(b0 + BIN / 2 + off)
                ys.append(p)
                # The Wilson interval is not centred on p, so an arm can come
                # out negative at p = 0 or 100; the bar is clipped there.
                el.append(max(0.0, p - l))
                eh.append(max(0.0, h - p))
                ns.append(len(sel))
                if boxes:
                    by_trial = collections.defaultdict(list)
                    for m in sel:
                        by_trial[(m["d"], m["trial"])].append(m[key])
                    rates.append([100 * sum(v) / len(v) for v in by_trial.values()])
            if not xs:
                continue
            if boxes and any(len(r) > 2 for r in rates):
                bp2 = axp.boxplot(rates, positions=xs, widths=BIN * 0.26,
                                  patch_artist=True, manage_ticks=False,
                                  medianprops=dict(color="#1a202c", lw=1.3))
                for b_ in bp2["boxes"]:
                    b_.set(facecolor=col, alpha=0.35, edgecolor=col)
            axp.errorbar(xs, ys, yerr=[el, eh], fmt="o", color=col, ms=6,
                         capsize=4, lw=1.4, label=name)
            ytxt = 2.0 if key == "arrived" else 7.0
            for x, nn in zip(xs, ns):
                axp.annotate(f"{nn}", (x, ytxt), ha="center", fontsize=7,
                             color=col)
        axp.set_xlabel("conn-RSSI at the moment of sending (dBm, "
                       f"{BIN} dB bins)")
        axp.set_ylabel("data-plane messages (%)")
        axp.set_title("Delivery and acknowledgement against signal strength")
        axp.text(0.015, 0.09,
                 "small figures are message counts per bin.\n"
                 "An ACK implies arrival, but the two series rest on different\n"
                 "evidence: ACKs come from the sender's own file, arrival needs\n"
                 "the receiver's — so their bins need not hold the same messages.",
                 transform=axp.transAxes, ha="left", va="bottom", fontsize=7.5,
                 color="#4a5568")
        axp.set_ylim(0, 106)
        axp.grid(alpha=0.25)
        axp.legend(fontsize=9, loc="lower right")
        save(fig, "fig_delivery_vs_rssi")
        for key, name, _, _ in series:
            have = [m for m in allm if m[key] is not None]
            if have:
                k = sum(1 for m in have if m[key])
                p, l, h = wilson(k, len(have))
                print(f"{name:28s} {k}/{len(have)} = {p:.1f}%  "
                      f"[{l:.1f}, {h:.1f}] 95% CI")
            else:
                print(f"{name:28s} no cross-file evidence in this pair")

    # Does link budget predict failure? Transmit power only shifts RSSI, so
    # if the weakest third of sends is no worse than the strongest, there is
    # no headroom for more power to buy — delivery is limited by whether the
    # link exists, not by how loud it is.
    for key, name in (("acked", "ACK returned"), ("arrived", "arrived")):
        have = sorted([m for m in allm if m[key] is not None],
                      key=lambda m: m["rssi"])
        if len(have) < 3 * MIN_N:
            continue
        third = len(have) // 3
        weak, strong = have[:third], have[-third:]
        a1 = sum(1 for m in weak if m[key])
        a2 = sum(1 for m in strong if m[key])
        p = fisher(a1, len(weak) - a1, a2, len(strong) - a2)
        print(f"\nlink budget vs {name}: weakest third "
              f"{a1}/{len(weak)} = {100 * a1 / len(weak):.1f}% "
              f"({weak[0]['rssi']}..{weak[-1]['rssi']} dBm)  vs  strongest third "
              f"{a2}/{len(strong)} = {100 * a2 / len(strong):.1f}% "
              f"({strong[0]['rssi']}..{strong[-1]['rssi']} dBm)")
        # A significant p with the WEAK side ahead is not a link-budget
        # effect — it is the failures clustering somewhere else. Report the
        # direction, or a backwards result reads as a range finding.
        weaker_better = (a1 / len(weak)) >= (a2 / len(strong))
        if p >= 0.05:
            verdict = "  — no detectable effect of signal strength"
        elif weaker_better:
            verdict = ("  — significant BUT INVERTED: the weaker half did "
                       "better, so this is clustering, not link budget")
        else:
            verdict = "  — signal strength DOES predict failure"
        print(f"  Fisher exact two-sided p = {p:.3f}" + verdict)
        bad = [m for m in have if not m[key]]
        if bad:
            print("  failures at: " + ", ".join(
                f"d={m['d']}m {m['rssi']}dBm" for m in sorted(
                    bad, key=lambda m: m["rssi"])[:10]))

    # summary
    A_, B_ = sides[0]["dev"][:8], sides[1]["dev"][:8]
    with open(os.path.join(HERE, "summary.csv"), "w", newline="") as f:
        wr = csv.writer(f)
        wr.writerow(["distance_m", "trials", "sessions", "estab_median_s",
                     "estab_max_s", f"{A_}_to_{B_}_delivered", f"{A_}_to_{B_}_offered",
                     f"{B_}_to_{A_}_delivered", f"{B_}_to_{A_}_offered",
                     "reverse_inferred", "rssi_median_dBm",
                     "ctrl_kB_per_trial", "data_incl_acks_kB_per_trial", "mA_median"])
        print(f"\n{'d':>5} {'sessions':>9} {'estab':>7} {'A→B':>10} {'B→A':>12} "
              f"{'rssi':>6} {'ctrl kB':>8}")
        tot = collections.Counter()
        for dist in ds:
            ws = [w for s in sides for w in at(s, dist)]
            est = [w["estab"] for w in ws if w["estab"] is not None]
            rssi = [x for w in ws for x in w["rssi"]]
            fwd = direction(sides[0], sides[1], dist)
            rev = direction(sides[1], sides[0], dist)
            ctrl = statistics.median(
                [sum(v for k, v in w["wire"].items()
                     if k not in (DATA_CLASS, ACK_CLASS)) / 1000
                 for w in ws]) if ws else 0
            data = statistics.median(
                [(w["wire"].get(DATA_CLASS, 0)
                  + w["wire"].get(ACK_CLASS, 0)) / 1000 for w in ws]) if ws else 0
            mas = [w["mA"] for w in ws if w["mA"]]
            wr.writerow([dist, len(ws), len(est),
                         round(statistics.median(est), 2) if est else "",
                         round(max(est), 2) if est else "",
                         fwd[0] if fwd[0] is not None else "", fwd[1] or "",
                         rev[0] if rev[0] is not None else "", rev[1] or "",
                         "yes" if rev[2] else "no",
                         statistics.median(rssi) if rssi else "",
                         round(ctrl, 2), round(data, 2),
                         round(statistics.median(mas)) if mas else ""])
            tot["fwd_g"] += fwd[0] or 0; tot["fwd_o"] += fwd[1] or 0
            tot["rev_g"] += rev[0] or 0; tot["rev_o"] += rev[1] or 0
            e_txt = f"{statistics.median(est):7.2f}" if est else f"{'-':>7}"
            r_txt = f"{rev[0]}/{rev[1]}{'*' if rev[2] else ''}" if rev[0] is not None else "-"
            print(f"{dist:>5} {len(est):>4}/{len(ws):<4} {e_txt} "
                  f"{str(fwd[0]) + '/' + str(fwd[1]):>10} {r_txt:>12} "
                  f"{statistics.median(rssi) if rssi else float('nan'):>6.1f} "
                  f"{ctrl:>8.2f}")
    print(f"\ntotals   {A_}→{B_} {tot['fwd_g']}/{tot['fwd_o']}"
          f"   {B_}→{A_} {tot['rev_g']}/{tot['rev_o']}   (* = inferred from receipts)")
    if n is not None:
        print(f"path loss: n={n:.2f}  A={A:.1f} dBm  σ={sigma:.1f} dB")
    print("wrote summary.csv")


if __name__ == "__main__":
    main()
