"""Nexus 5X thesis line sweep (line-2, 2026-08-22): per-trial establishment
anchored at bt-on, delivery both directions, RSSI path-loss fit, and the
fall-and-restart forensics. Reads the four upload dumps from the scratchpad."""
import json, math, re, statistics, collections, datetime, sys

SC = "/private/tmp/claude-502/-Users-dbachar-git-TUM-grassroots-social-networking/a4c78fd3-1407-4439-929e-c5337b346d0a/scratchpad"
SURV = "3ff8f0af3dcfe082af6758f1c57de88863266f13e56087b60643e8260ec5517d"
FALL = "499f5c752c04ffe4d18f2f775ec89ec3336f26d78110c429cb0e0115a8b26beb"

def load(name):
    rows = json.load(open(f"{SC}/{name}"))
    out = []
    for r in rows:
        b = json.loads(r["body"]) if r["body"] else {}
        t = r["t"] if r["t"] is not None else b.get("t")
        if t is None: continue
        out.append((t, r["type"], b))
    out.sort(key=lambda x: x[0])
    return out

def ts(t): return datetime.datetime.fromtimestamp(t/1000, datetime.timezone.utc).strftime("%H:%M:%S")

surv = load("exp_line-2.jsonl_3085171_0.json")
rest = load("exp_line-2.jsonl_210193_0.json")
s_l1 = load("exp_line-1.jsonl_148037_0.json")
f_l1 = load("exp_line-1.jsonl_136005_0.json")

STOP = max(t for t, ty, b in surv if b.get("event") == "expStop")  # analysis cutoff

STEP = re.compile(r"^d=(\d+) t(\d+)$")

def trials_of(rows, cutoff):
    """Parse the marker cadence into per-trial windows."""
    marks = [(t, b.get("label", "")) for t, ty, b in rows
             if ty == "marker" and b.get("event") == "note"]
    out = []
    bt_on = None
    for i, (t, lab) in enumerate(marks):
        if lab == "bt-on":
            bt_on = t
        m = STEP.match(lab)
        if not m:
            continue
        d, tr = int(m.group(1)), int(m.group(2))
        sess = settled = end = None
        for t2, lab2 in marks[i+1:]:
            if lab2 == "session-up" and sess is None: sess = t2
            elif lab2 == "link-settled" and settled is None: settled = t2
            elif lab2 == "run-end": end = t2; break
            elif STEP.match(lab2): break
        out.append(dict(d=d, tr=tr, t0=t, bt=bt_on, sess=sess, settled=settled,
                        end=end if end else t + 30000))
    return [w for w in out if w["t0"] <= cutoff]

tw = trials_of(surv, STOP)
rw = trials_of(rest, STOP)

# ---- message accounting (survivor) --------------------------------------
sent = {}    # messageId -> t
ack = {}     # messageId -> t of ackRx
recv = []    # t list
for t, ty, b in surv:
    if ty != "message" or t > STOP: continue
    if b.get("dir") == "sent": sent[b["messageId"]] = t
    elif b.get("dir") == "ackRx": ack[b["messageId"]] = t
    elif b.get("dir") == "recv": recv.append(t)

# restart-side messages (fallen phone, within cutoff)
r_sent, r_ack, r_recv = {}, {}, []
for t, ty, b in rest:
    if ty != "message" or t > STOP: continue
    if b.get("dir") == "sent": r_sent[b["messageId"]] = t
    elif b.get("dir") == "ackRx": r_ack[b["messageId"]] = t
    elif b.get("dir") == "recv": r_recv.append(t)

# rssi + wire + dialFailed (survivor)
rssi = [(t, b["rssi"]) for t, ty, b in surv if ty == "rssi" and b.get("src") == "conn" and t <= STOP]
fails = [(t, b.get("error", "")) for t, ty, b in surv
         if ty == "link" and b.get("event") == "dialFailed" and t <= STOP]
wire = [(t, sum(b.get("txBytes", {}).values())) for t, ty, b in surv if ty == "wire" and t <= STOP]

for w in tw:
    a, e = w["t0"], w["end"]
    ids = [m for m, t in sent.items() if a <= t < e]
    w["sent"] = len(ids)
    w["acked"] = sum(1 for m in ids if m in ack)
    w["recv"] = sum(1 for t in recv if a <= t < e + 5000)
    w["rssi"] = [v for t, v in rssi if a <= t < e]
    w["fails"] = sum(1 for t, _ in fails if w["bt"] <= t < e)
    w["estab"] = (w["sess"] - w["bt"]) / 1000 if w["sess"] and w["bt"] else None

for w in rw:
    a, e = w["t0"], w["end"]
    w["estab"] = (w["sess"] - w["bt"]) / 1000 if w["sess"] and w["bt"] else None
    ids = [m for m, t in r_sent.items() if a <= t < e]
    w["sent"], w["acked"] = len(ids), sum(1 for m in ids if m in r_ack)
    w["recv"] = sum(1 for t in r_recv if a <= t < e + 5000)

# ---- per-distance rollup -------------------------------------------------
print("=== survivor per-distance (anchor = bt-on marker) ===")
print(f"{'d':>4} {'sess':>6} {'estab med':>9} {'p max':>7} {'sent':>5} {'acked':>5} {'recv':>5} {'rssi med':>8} {'fails':>5}")
per_d = collections.defaultdict(list)
for w in tw: per_d[w["d"]].append(w)
fit_pts = []
for d in sorted(per_d):
    ws = per_d[d]
    est = [w["estab"] for w in ws if w["estab"] is not None]
    ok = len(est)
    rs = [v for w in ws for v in w["rssi"]]
    med_r = statistics.median(rs) if rs else None
    if med_r is not None: fit_pts.append((d, med_r))
    print(f"{d:>4} {ok:>3}/{len(ws):<2} {statistics.median(est):>9.2f} {max(est):>7.2f} "
          f"{sum(w['sent'] for w in ws):>5} {sum(w['acked'] for w in ws):>5} "
          f"{sum(w['recv'] for w in ws):>5} {med_r if med_r is not None else float('nan'):>8.1f} "
          f"{sum(w['fails'] for w in ws):>5}")

est_all = [w["estab"] for w in tw if w["estab"] is not None]
print(f"\nall trials: {len(est_all)}/{len(tw)} sessions; estab median {statistics.median(est_all):.2f}s "
      f"p90 {statistics.quantiles(est_all, n=10)[8]:.2f}s max {max(est_all):.2f}s")
print(f"survivor totals: sent {len(sent)} acked {len(ack)} recv {len(recv)}")
print(f"unacked ids: {[ (ts(sent[m]), m[:8]) for m in sent if m not in ack ]}")

# ---- path-loss fit -------------------------------------------------------
xs = [math.log10(d) for d, r in fit_pts]; ys = [r for d, r in fit_pts]
n = len(xs); mx, my = sum(xs)/n, sum(ys)/n
slope = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / sum((x-mx)**2 for x in xs)
A = my - slope*mx
resid = [y - (A + slope*x) for x, y in zip(xs, ys)]
sigma = (sum(r*r for r in resid)/(n-2))**0.5
print(f"\npath loss fit: RSSI(d) = {A:.1f} + {slope:.1f}*log10(d)  ->  n = {-slope/10:.2f}, sigma {sigma:.1f} dB  ({n} pts)")

# ---- restart side --------------------------------------------------------
print("\n=== fallen phone restart (labels are schedule; physical d = 120 m) ===")
for w in rw:
    print(f"  {ts(w['t0'])} label d={w['d']} t{w['tr']}  estab {w['estab'] if w['estab'] is None else round(w['estab'],2)}s "
          f"sent {w['sent']} acked {w['acked']} recv {w['recv']}")
print(f"restart totals within cutoff: sent {len(r_sent)} acked {len(r_ack)} recv {len(r_recv)}")

# ---- fall forensics ------------------------------------------------------
print("\n=== fall forensics ===")
last_recv = max((t for t in recv if t < STOP - 300000), default=None)
peer_ev = [t for t, ty, b in surv if ty == "link" and b.get("event") in ("discovered", "identified")
           and b.get("peer", b.get("pubkey", "")) in ("", FALL) ]
d110 = [w for w in tw if w["d"] == 110]
t10 = [w for w in d110 if w["tr"] == 10][0]
disc_in = [ (t,b.get("event")) for t, ty, b in surv if ty=="link" and b.get("event") in ("discovered","dialIssued","dialFailed") and t10["bt"] <= t < t10["end"] ]
print(f"d=110 t10 window {ts(t10['bt'])}..{ts(t10['end'])}: link events: {collections.Counter(e for _,e in disc_in)}")
rest_first = min(t for t, ty, b in rest)
print(f"restart file first record: {ts(rest_first)}")
lastseen = max((t for t, ty, b in surv if ty=="rssi" and b.get("peer")==FALL and t < t10["bt"]), default=None)
print(f"last conn-RSSI from peer before d110t10: {ts(lastseen) if lastseen else '-'}")

# ---- power / flush forensics --------------------------------------------
def pw(rows, name):
    ps = [(t, b) for t, ty, b in rows if ty == "power"]
    if not ps: print(f"{name}: no power records"); return
    f, l = ps[0][1], ps[-1][1]
    print(f"{name}: level {f['levelPct']}%→{l['levelPct']}%  charging {f['charging']}→{l['charging']}  "
          f"n={len(ps)}  current first {f['currentNowUa']/1000:.0f}mA last {l['currentNowUa']/1000:.0f}mA")
print()
pw(surv, "survivor line-2"); pw(rest, "fallen restart"); pw(s_l1, "survivor line-1"); pw(f_l1, "fallen line-1")

# discharge-rate check: currents during trials (survivor)
cur = [ -b["currentNowUa"]/1000 for t, ty, b in surv if ty == "power" and not b.get("charging") and b["currentNowUa"] < 0 ]
if cur: print(f"survivor discharge current: median {statistics.median(cur):.0f} mA over {len(cur)} samples")

# wire per trial
wt = []
for w in tw:
    tx = sum(v for t, v in wire if w["t0"] <= t < w["end"])
    wt.append(tx)
print(f"control+data on the wire per trial: median {statistics.median(wt)/1000:.2f} kB")

# operator cycles between positions
marks = [(t, b.get("label","")) for t, ty, b in surv if ty=="marker" and b.get("event")=="note"]
print("\noperator bt cycles between positions:")
pos_end = {}
for d in sorted(per_d):
    pos_end[d] = max(w["end"] for w in per_d[d])
ds = sorted(per_d)
for i in range(len(ds)-1):
    a, b_ = pos_end[ds[i]], min(w["t0"] for w in per_d[ds[i+1]]) 
    offs = [t for t, lab in marks if lab=="bt-off" and a < t < b_ - 120000]
    print(f"  walk {ds[i]}->{ds[i+1]}m: {len(offs)} operator cycle(s) at {[ts(t) for t in offs]}")

# false starts
for rows, nm in ((s_l1, "survivor line-1"), (f_l1, "fallen line-1")):
    t0, t1 = rows[0][0], rows[-1][0]
    steps = [b.get("label") for t, ty, b in rows if ty=="marker" and STEP.match(b.get("label",""))]
    print(f"{nm}: {ts(t0)}..{ts(t1)}, {len(rows)} records, steps {steps[:3]}")

# nickname / identity check
for t, ty, b in surv:
    if ty=="link" and b.get("event")=="identified":
        print("\nidentified body keys:", sorted(b.keys()), "nickname:", b.get("nickname"), "peer:", str(b.get("peer"))[:12]); break
