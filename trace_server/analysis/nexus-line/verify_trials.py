"""Per-trial message ledger for a two-phone run, joined across both files.

Answers, for every trial and both directions: were the planned messages
actually sent, did the PEER's own file log each one arriving, and did the
end-to-end ACK come back — with the ack latency.

    python3 verify_trials.py                       # newest exp_line pair
    python3 verify_trials.py --exp line-4          # a named experiment
    python3 verify_trials.py --uploads A B
    python3 verify_trials.py --expect 100          # flag trials off the plan

A message is only counted for a direction when the sender's file logs the
send and the receiver's file is the one that confirms arrival — nothing here
is inferred from a single side.
"""
import argparse, collections, json, os, re, statistics, subprocess, sys

DB = "/mnt/HC_Volume_106351660/data/traces.db"
HERE = os.path.dirname(os.path.abspath(__file__))
CACHE = os.path.join(HERE, ".cache")
STEP = re.compile(r"^d=(\d+) t(\d+)$")


def server(sql):
    r = subprocess.run(["ssh", "trace-server", f"sqlite3 -json {DB} \"{sql}\""],
                       capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        sys.exit(f"server query failed: {r.stderr.strip()}")
    return json.loads(r.stdout) if r.stdout.strip() else []


# A run is one file, but the server stores it in 20 000-record chunks whose
# upload_ids differ only in a trailing index. Treating an upload_id as a run
# reads one slice of one phone — and picking devices off the newest rows finds
# only the phone that uploaded last, because all of its chunks sort above the
# other phone's however high the limit goes.
FILE = "substr(upload_id, 1, instr(upload_id, '.jsonl') + 5)"


def experiments(like):
    return server(
        f"select {FILE} f, device_id, count(*) n,"
        " count(distinct upload_id) chunks, max(id) mx,"
        " datetime(min(t)/1000,'unixepoch') a,"
        " datetime(max(t)/1000,'unixepoch') b"
        f" from records where upload_id like '{like}'"
        " group by f, device_id order by mx desc")


def fetch(fname, device):
    """Every chunk this device uploaded for this experiment, in time order."""
    os.makedirs(CACHE, exist_ok=True)
    p = os.path.join(CACHE,
                     re.sub(r"[/:.]", "_", f"{fname}_{device[:8]}") + ".json")
    if os.path.exists(p):
        return json.load(open(p))
    rows = server("select device_id, t, type, body from records"
                  f" where upload_id like '{fname}:%' and device_id='{device}'"
                  " and type in ('marker','message') order by t, id")
    json.dump(rows, open(p, "w"))
    return rows


def parse(rows):
    dev, ev = (rows[0]["device_id"] if rows else "?"), []
    for r in rows:
        b = json.loads(r["body"]) if r["body"] else {}
        t = r["t"] if r["t"] is not None else b.get("t")
        if t is not None:
            ev.append((t, r["type"], b))
    ev.sort(key=lambda x: x[0])
    return dev, ev


def trials(ev):
    marks = [(t, b.get("label", "")) for t, ty, b in ev
             if ty == "marker" and b.get("event") == "note"]
    out = []
    for i, (t, lab) in enumerate(marks):
        m = STEP.match(lab)
        if not m:
            continue
        end = None
        for t2, l2 in marks[i + 1:]:
            if l2 == "run-end":
                end = t2
                break
            if STEP.match(l2):
                break
        out.append(dict(label=lab, d=int(m.group(1)), tr=int(m.group(2)),
                        t0=t, end=end if end else t + 30000))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true",
                    help="show experiments, devices and chunk counts")
    ap.add_argument("--exp", help="experiment id, e.g. line-4")
    ap.add_argument("--expect", type=int, default=None,
                    help="planned sends per trial per direction")
    a = ap.parse_args()

    like = f"exp_{a.exp}.jsonl%" if a.exp else "exp_line-%"
    rows = experiments(like)
    if not rows:
        sys.exit(f"no uploads matching {like}")
    if a.list:
        for r in rows:
            print(f"{r['f']:30s} {r['device_id'][:8]} {r['n']:>8} records "
                  f"in {r['chunks']:>3} chunks  {r['a']}..{r['b']}")
        return
    # One run means one file name and every device that uploaded under it.
    fname = rows[0]["f"]
    mine = [r for r in rows if r["f"] == fname]
    if len(mine) < 2:
        sys.exit(f"{fname} has only {len(mine)} device uploaded — the other "
                 "phone has not uploaded yet (check with --list)")

    sides = []
    for r in mine[:2]:
        print(f"loading {r['device_id'][:8]}: {r['n']} records across "
              f"{r['chunks']} chunks ...", flush=True)
        dev, ev = parse(fetch(fname, r["device_id"]))
        sides.append(dict(u=f"{fname} [{r['chunks']} chunks]", dev=dev,
                          ev=ev, tw=trials(ev)))
    if len({s["dev"] for s in sides} ) != 2:
        sys.exit("both uploads are the same device")

    for s in sides:
        peer = next(x for x in sides if x["dev"] != s["dev"])
        s["sent"], s["ack"], s["recv"] = {}, {}, {}
        for t, ty, b in s["ev"]:
            if ty != "message":
                continue
            d, mid = b.get("dir"), b.get("messageId")
            if d in ("sent", "ackRx") and b.get("peer") not in (peer["dev"], None):
                continue
            if d == "sent":
                s["sent"][mid] = t
            elif d == "ackRx":
                s["ack"][mid] = t
            elif d == "recv":
                s["recv"][mid] = t

    print(f"A = {sides[0]['dev'][:8]}   {sides[0]['u']}")
    print(f"B = {sides[1]['dev'][:8]}   {sides[1]['u']}")
    # A send fans out to EVERY identified peer, so a third phone left powered
    # on nearby does not merely sit there: it takes a full share of the
    # trial's messages and of the airtime, and the pair's own traffic is what
    # gets truncated. Name anyone else the run talked to.
    pair = {x["dev"] for x in sides}
    strangers = collections.Counter()
    for s_ in sides:
        for t, ty, b in s_["ev"]:
            if ty == "message" and b.get("dir") == "sent" \
                    and b.get("peer") and b["peer"] not in pair:
                strangers[b["peer"][:8]] += 1
    if strangers:
        print("\n*** NOT A TWO-PHONE RUN — messages also went to: "
              + ", ".join(f"{k} ({v})" for k, v in strangers.most_common())
              + "\n*** every extra phone takes its own 100 a trial and its "
                "share of the airtime.")
    print()
    hdr = (f"{'trial':>10} {'dir':>7} {'sent':>5} {'arrived':>8} {'acked':>6} "
           f"{'ack ms p50':>11} {'p95':>7} {'max':>7}  status")
    print(hdr)
    print("-" * len(hdr))
    bad, totals = [], collections.Counter()
    lat_all = []
    labels = sorted({w["label"] for s in sides for w in s["tw"]},
                    key=lambda l: (int(STEP.match(l).group(1)),
                                   int(STEP.match(l).group(2))))
    for lab in labels:
        for si, s in enumerate(sides):
            peer = sides[1 - si]
            w = next((x for x in s["tw"] if x["label"] == lab), None)
            if w is None:
                continue
            ids = [m for m, t in s["sent"].items() if w["t0"] <= t < w["end"]]
            arrived = [m for m in ids if m in peer["recv"]]
            acked = [m for m in ids if m in s["ack"]]
            lat = sorted(s["ack"][m] - s["sent"][m] for m in acked)
            lat_all += lat
            name = f"{'AB'[si]}→{'AB'[1 - si]}"
            problems = []
            # A trial that sent nothing is never "ok", with or without a
            # plan to compare against — it measured no delivery at all.
            if not ids:
                problems.append("sent NOTHING")
            elif a.expect is not None and len(ids) != a.expect:
                problems.append(f"sent {len(ids)}≠{a.expect}")
            if len(arrived) != len(ids):
                problems.append(f"{len(ids) - len(arrived)} never arrived")
            if len(acked) != len(ids):
                problems.append(f"{len(ids) - len(acked)} unacked")
            status = "ok" if not problems else "  <-- " + ", ".join(problems)
            if problems:
                bad.append((lab, name, problems))
            totals[f"{name}_sent"] += len(ids)
            totals[f"{name}_arr"] += len(arrived)
            totals[f"{name}_ack"] += len(acked)
            p50 = lat[len(lat) // 2] if lat else 0
            p95 = lat[int(len(lat) * 0.95)] if lat else 0
            print(f"{lab:>10} {name:>7} {len(ids):>5} {len(arrived):>8} "
                  f"{len(acked):>6} {p50:>11} {p95:>7} {lat[-1] if lat else 0:>7}"
                  f"  {status}")

    print()
    for name in ("A→B", "B→A"):
        st, ar, ak = (totals[f"{name}_sent"], totals[f"{name}_arr"],
                      totals[f"{name}_ack"])
        if st:
            print(f"{name}: sent {st}, arrived {ar} ({100 * ar / st:.1f}%), "
                  f"acked {ak} ({100 * ak / st:.1f}%)")
    if lat_all:
        lat_all.sort()
        print(f"ack latency over {len(lat_all)} messages: "
              f"p50 {lat_all[len(lat_all)//2]} ms, "
              f"p95 {lat_all[int(len(lat_all)*0.95)]} ms, max {lat_all[-1]} ms")
    print(f"\n{'PROBLEMS in ' + str(len(bad)) + ' trial-directions' if bad else 'every trial-direction is complete on both sides'}")


if __name__ == "__main__":
    main()
