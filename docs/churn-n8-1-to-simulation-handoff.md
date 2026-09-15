# churn-n8-1 → simulation: three questions before the figures are generated

From the testbed-analysis side (session `grassroots-social-networking-98`) to
the simulation session, 2026-09-12, at Dan's request. Self-contained: you do
not need to have read anything else. Source data and the full write-up are in
the app repo at `docs/churn-n8-1-results.md`; the run's database is
`trace_server/data/churn-n8-1.db`.

---

## The questions, first

**Q1. Where is the simulator's seven-link row coming from, and is it coming
from this run?** `FIGURES-PLAN.md` says "the testbed's N = 8 run of
11 September supplies the seven-link row … since the hall runs at seven
links." That run cannot supply it, for the reason in §1 below. If the churn
constants or figure E's left panel currently take a k = 7 point from
churn-n8-1, we need to decide together what to do instead. If they don't,
say so and Q1 closes.

**Q2. Is the simulator's churn model a function of link count?** If the
per-link drop hazard varies with k in the model, and that k-dependence was
taken from testbed rows, it has inherited a load confound (§2). A model where
the per-link hazard is flat in k, with the per-node rate emerging from
holding more links, is the shape the data actually supports.

**Q3. Where does `LINK_BYTES_PER_SEC = 7000` come from?** The simulation
assumes a Nexus 5X fleet. This run's saturating arm never measured a Nexus
above 5.1 kB/s per radio at any link count, and 4.2 kB/s pooled (§3). 7000
may be right for a reason I don't know about — but if it was taken from a
Nexus measurement, I can't find the measurement it came from.

---

## 1. Why churn-n8-1 cannot give you a k = 7 row

The run held eight phones (four Nexus 5X, two Pixel 10 Pro, a Galaxy S10e, a
Huawei HMA-L09) at N = 8 for 2 h 42 min, so every node had seven addressable
peers. The intent was exactly the one `FIGURES-PLAN.md` states: produce the
seven-link row the diluting clique never reached, because N = 7 there gives
k = 6.

It did not, and no reanalysis of it will:

| class | mean concurrent links | time at 7 links | time at ≥5 |
|---|---|---|---|
| nexus | 4.63 | 5.2% | 56.6% |
| modern | 4.64 | 15.7% | 54.5% |

Seven links was reached — the maximum observed is exactly 7 — but not held.
Under load a node at N = 8 sits at four to five links.

**The deeper problem is not thin exposure, it is that k is an outcome here.**
In the diluting clique, k was exogenous: it was set by how many phones were
in the room and every link was up, so a measurement grouped by k tells you
what k links do to a radio. In this run the phone count is fixed and k varies
*only because links break*. Grouping this run's sends by the k measured at the
time therefore inverts the relationship — delivery *rises* with k, because a
node holding seven links at that instant is a node whose links are healthy:

| pooled, all arms | k=3 | k=4 | k=5 | k=6 | k=7 |
|---|---|---|---|---|---|
| nexus | 0.860 | 0.852 | 0.893 | 0.881 | 0.881 |
| modern | 0.806 | 0.775 | 0.734 | 0.717 | 0.649 |

That is selection, not causation. A k = 7 row lifted from it describes the
5.2% of Nexus time when everything happened to be working.

**To get a real k = 7 row you need k held at seven by construction** — links
that stay up, which means a lower offered rate or a different mechanism for
pinning degree. Re-running this shape will not produce a different answer.

## 2. The per-link hazard by degree is confounded by per-link load

If the churn model's hazard depends on k, please read this before using
testbed rows for that dependence.

Hold arm, Nexus 5X, per-link loss hazard against the throughput each link was
actually carrying:

| k | throughput per link (B/s) | peer-link losses per link-minute |
|---|---|---|
| 2 | 901 | 0.563 |
| 3 | 1194 | 0.394 |
| 4 | 737 | 0.340 |
| 5 | 299 | 0.256 |
| 6 | 72 | 0.240 |
| 7 | 49 | 0.224 |

The per-link hazard falls as k rises — but so does the load on each link, by a
factor of eighteen. The modern handsets keep pushing 800–1400 B/s per link at
every k and their per-link hazard stays correspondingly higher (0.36–0.49).
Pool both classes and plot hazard against throughput per link rather than
against k and you get one rising trend, not two class-separated ones: a link
carrying 50–100 B/s is nearly idle and survives; a link carrying ~1000 B/s
under contention is the one being stress-tested.

So "the Nexus loses links less often at high k" is not a hardware property to
model — it is the Nexus having stopped transmitting (434 and 345 B/s at k = 6
and 7, against 5,983 B/s for a modern handset at the same k).

**What is safe to take:** the *per-node* loss rate, which rises with links
held as intuition expects — modern 0.65 → 2.92 losses per node-minute from
k = 1 to 6 (4.5x), Nexus 1.13 → 1.57 from k = 2 to 7 (1.4x). Note the Nexus
rise is shallow, and shallower than a model in which each link carries
independent risk would predict.

Counting note, in case it matters for comparison: these are **peer-link
losses** (a peer's *last* GATT leg dropping), not leg drops. A converged pair
holds two legs, so counting legs overstates churn by 1.4–1.7x. Both columns
are in `trace_server/analysis/churn-n8-1-outages/churn_rate_by_degree.csv`.

## 3. The per-radio budget this run measured

Bytes transmitted per node-second. The saturating arm is the ceiling; the
fixed-load arm is a floor (it reports what it was given, not what it could
carry).

| arm | nexus | modern |
|---|---|---|
| moderate (fixed load) | 5,260 B/s | 8,194 B/s |
| **sat (ceiling)** | **4,180 B/s** | **9,406 B/s** |
| hold | 1,762 B/s | 4,767 B/s |

By link count, the Nexus saturating arm runs 3,936 / 4,053 / 4,540 / 5,113 /
4,354 B/s at k = 3…7.

**Correction, 2026-09-12 — these figures are depressed by dead time inside
each run, and the original version of this section used them to contradict
`LINK_BYTES_PER_SEC = 7000`. That was wrong; withdraw it.** The moderate and
saturating arms set `resetLinks: true`, so every 75 s step opens with a reset
and dark window and the links come back during the dwell. Splitting the
60 s dwell into quarters, per radio:

| arm | class | q1 | q2 | q3 | q4 | dwell mean |
|---|---|---|---|---|---|---|
| moderate | nexus | 1,913 | 7,873 | 5,102 | 8,768 | 5,914 B/s |
| moderate | modern | 2,287 | 11,219 | 6,768 | 13,791 | 8,516 B/s |
| sat | nexus | 1,324 | 5,852 | 4,466 | 7,074 | 4,679 B/s |
| sat | modern | 2,520 | 12,948 | 9,532 | 17,185 | 10,546 B/s |

The first quarter is depressed on every arm and both classes — that is links
still returning, not radio capacity. Excluding it, the Nexus saturating arm
averages **5,797 B/s with its top quarter at 7,074 B/s**. So this run does
*not* contradict 7,000: it brackets it. The residual difference against the
clique's 6.84–7.15 kB/s is roughly 17 %, not the 40 % first claimed here, and
fleet, room and methodology differences are an adequate explanation for what
is left.

(Do not read the quarter-to-quarter zig-zag as physical: `wire` records land
about every 10 s, so 15 s quarters alias. The depressed first quarter and the
dwell means are the parts that survive that.)

The same dead time explains the apparent inversion at k = 7, where the
*moderate* arm aired more than the *saturating* arm on the Nexus (7,029
against 4,354 B/s): both are step-window averages over different amounts of
re-establishment, not comparable ceilings.

**If you want a per-radio ceiling from this run, take the saturating arm's
dwell excluding its first quarter, not the pooled step average.**

## 4. What this run *does* give you, cleanly

**The outage duration distribution, de-censored.** This is the run's real
contribution and the hold arm was built for it.

| arm | class | fraction of time down | closed episodes | mean s | median s | p90 s | max s |
|---|---|---|---|---|---|---|---|
| moderate | nexus | 0.686 | 348 | 11.9 | 3.6 | 38.6 | 59.5 |
| moderate | modern | 0.589 | 864 | 6.0 | 1.8 | 17.2 | 59.4 |
| sat | nexus | 0.831 | 137 | 13.6 | 6.8 | 43.0 | 64.4 |
| sat | modern | 0.696 | 403 | 8.3 | 1.5 | 30.2 | 58.0 |
| **hold** | **nexus** | **0.907** | **1107** | **37.0** | **3.1** | **117.0** | **966.6** |
| **hold** | **modern** | **0.770** | **1968** | **31.0** | **3.0** | **93.6** | **598.8** |

The 60 s arms max out at 59.5, 59.4, 64.4 and 58.0 s — the step length, in
every case. That *is* the censoring, visible. The 600 s hold arm reaches
966 s. **Use the hold rows.**

The distribution is heavy-tailed, not exponential: median ≈ 3 s against a mean
of 31–37 s and a p90 of one to two minutes. An exponential draw at the mean
produces far too few short outages and far too few very long ones. Draw from
the empirical episode lengths.

Per-episode rows for sampling:
`trace_server/analysis/churn-n8-1-outages/outages_link_level.csv` (2,975 rows;
an episode runs from a peer's last leg dropping to its first leg returning, so
it spans steps) and `outages_send_level.csv` (6,042 rows; "a send found no
link"). The two differ by an order of magnitude in the median (34 s against
3 s) — use the **link-level** file for a two-state link model.

Keep the censored rows for a survival estimate and drop them for a naive mean:
the 20 Nexus and 15 modern censored episodes in the hold arm have lower bounds
averaging 1,146 s and 1,390 s against closed means of 162 s and 114 s. They
are the longest outages in the run, every one truncated by observation ending
rather than by recovery, so a closed-only resample is optimistic in exactly
the tail that matters.

## 5. Results 4 and 5: scoped, not retracted (updated 2026-09-12)

An earlier version of this section said these were retracted. **That is
withdrawn — they stand.** `resetDtnBuffer: firstOfArm`
(`lib/src/testbed/field_plan_presets.dart:427`) empties the DTN buffer at the
start of each of the three arms and never again inside one. Dan settled on
2026-09-12 that this is correct: each arm is its own experiment at its own
offered load, cross-arm buffer continuity was never the question, so an
arm-boundary reset is what you want.

Use them **within an arm**. Result 4's t1 → t10 decline is that arm's
transient from a cold start toward its own steady state; absolute buffer
occupancy is not comparable between arms. No replacement run is needed and
none is being done.

## What I'd like back

Answers to Q1–Q3, and specifically: which constants in
`GrassrootsInterface` were sourced from churn-n8-1, and which from the
diluting clique. If figure E's left panel needs a k = 7 point and this run
can't supply one, tell me what you want to do — plot 2–6 from the clique and
mark 7 as unmeasured is one option, and honest.
