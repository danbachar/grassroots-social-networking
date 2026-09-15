# churn-n8-1 — link churn and throughput at N=8

Run finished 2026-09-10 22:53 UTC, eight phones, 2 h 42 min, 8,501,011 records.
This is the handover for anyone consuming the run: the simulator calibration
(`grassroots-simulations/CLIQUE-CALIBRATION-PLAN.md`) and the thesis figures.

## How to scope the buffer results (settled 2026-09-12)

**Every arm is its own experiment; do not compare buffer state across arms.**
`resetDtnBuffer: firstOfArm` in `linkChurn()`
(`lib/src/testbed/field_plan_presets.dart:427`) empties the DTN buffer once at
the start of each arm — moderate, sat, hold — and never again inside it. That
is the intended behaviour, not a defect: the three arms offer different loads,
so each has its own steady state, and an arm that inherited the previous arm's
backlog would start outside its own.

This was briefly withdrawn on 2026-09-11 on the reading that the buffer should
have run continuously across the whole session. Dan settled it on 2026-09-12:
cross-arm continuity was never the question, so the arm-boundary reset is
correct and **Results 4 and 5 stand as within-arm measurements.**

Two things follow for anyone quoting them:

- **Within an arm only.** Result 4's t1 → t10 decline is each arm's transient
  from a defined cold start toward its own steady state. It is not a
  cross-arm quantity, and absolute buffer occupancy is not comparable between
  arms.
- **t1 is the arm's cold start.** If you want steady-state rather than
  transient numbers, drop early runs as warm-up and say so — an ordinary
  analysis choice, not a correction.

Results 1, 2, 3, 6 and 7 never depended on buffer contents and are unaffected
either way.

## Where the data is

| what | where |
|---|---|
| local extract, this run only | `/Users/dbachar/git/TUM/grassroots-social-networking/trace_server/data/churn-n8-1.db` (3.09 GB, SQLite, 8,501,011 records) |
| clock offsets | `/Users/dbachar/git/TUM/grassroots-social-networking/clocks_8.json` (all 8 within 50 ms) |
| analysis output | `trace_server/analysis/churn-n8-1-msg/`, `-wire/`, `-custody/` |
| server, live DB | `ssh trace-server`, `/mnt/HC_Volume_106351660/data/traces.db` |
| server, this run extracted | `trace-server:/home/dbachar/churn-n8-1-v.db` |

Open the server DB `file:…?mode=ro` — **not** `immutable=1`. There is a 1.27 GB
WAL and this run is in it; `immutable` ignores the WAL and returns a database
with no churn-n8-1 in it. `immutable=1` is only for the archived root-disk DB
(history to 2026-08-15).

The local extract has the same `records` / `uploads` schema as the server, so
`analyze.py` takes it directly. It carries only this experiment.

### Reproduce the analysis

`analyze.py` loads every record into one DataFrame, so the full 8.5 M will
exhaust a 16 GB machine. Run it in passes with `--types`:

```bash
python3 trace_server/analyze.py trace_server/data/churn-n8-1.db --exp churn-n8-1 \
  --clocks clocks_8.json --types marker,message,link,flow \
  --out trace_server/analysis/churn-n8-1-msg
```

Pass 2 swaps `--types` for `marker,wire,power,buf,flow,session,link`, pass 3 for
`marker,custody,sync,relay`. Peak resident was 4.8 GB on pass 1.

## The fleet, and why the split matters

The two classes must never be pooled: the Nexus 5X airs about half the bytes a
modern handset does, and its behaviour differs on every measure below.

| node | phone | class | pubkey |
|---|---|---|---|
| 1 | Nexus 5X | nexus | `72440e8a` |
| 2 | Nexus 5X | nexus | `07e47335` |
| 3 | Nexus 5X | nexus | `44a266c4` |
| 4 | Nexus 5X | nexus | `18130c0f` |
| 5 | Pixel 10 Pro | modern | `366dca50` |
| 6 | Pixel 10 Pro | modern | `a2b11ef1` |
| 7 | Galaxy S10e | modern | `929a022c` |
| 8 | Huawei HMA-L09 | modern | `be3a5ef5` |

## The run completed cleanly

All 30 steps fired on all 8 phones: 10 × 60 s moderate fixed load, 10 × 60 s
saturating, 10 × 600 s hold with no in-run resets. `run-end` 240 = 30 × 8.
`custody-reset` 24 = 3 arms × 8, so the buffer was purged on the first run of
each arm and never again inside it. `links-reset` 160 = the 20 breaking steps ×
8; the hold arm reset nothing, as designed. Sessions were 7 on every phone at
peak and at the end — the `minSessionsToLaunch: 7` gate held for the whole run.

One thing to know before reading per-device numbers: `bt-on` is 167 against
`bt-off` 160 plus 8 starts, so one phone is one marker short.

## Result 1 — the mesh never reached seven links

This is the finding that governs how the rest may be used.

Time-weighted concurrent peer links per node, from `links.csv`:

| class | mean links | time at 7 links | time at ≥5 |
|---|---|---|---|
| nexus | 4.63 | 5.2% | 56.6% |
| modern | 4.64 | 15.7% | 54.5% |

Seven links was reachable — the maximum observed is exactly 7 — but not
holdable. Under load a node at N=8 sits at four to five links, not seven.

**Consequence for the calibration.** This run does not produce a k=7 row
comparable to the clique's k=1..6 table, and it cannot be made to. In the
clique, k was exogenous: it was set by how many phones were in the room and
every link was up, so u(k) measured what k links do to a radio. Here N is
pinned at 8 and k varies only because links break, so k is an outcome. Grouping
this run's sends by measured k inverts the relationship — u falls as k rises,
because a node holding seven links at that instant is a node whose links are
healthy, not a node under more load:

| pooled, all arms | k=3 | k=4 | k=5 | k=6 | k=7 |
|---|---|---|---|---|---|
| nexus | 0.860 | 0.852 | 0.893 | 0.881 | 0.881 |
| modern | 0.806 | 0.775 | 0.734 | 0.717 | 0.649 |

Read that as selection, not causation. **Do not fit u(k) to it.**

What this run does give the model is the N=8 point with all seven peers
addressable, which is a different and honest quantity:

| moderate arm, whole run | sends | found no link |
|---|---|---|
| nexus | 28,000 | 0.686 |
| modern | 28,000 | 0.588 |

Against the clique's k=6 values of 0.42 (nexus) and 0.10 (modern). The offered
rates are not identical, so treat the step up as a direction, not a coefficient.

## Result 2 — outage lengths, de-censored

This is what the 600 s hold arm was for, and it worked. Measured on the send
stream: an outage opens at the first send to a peer that finds no link and
closes at the next send to that peer that airs.

| arm | class | fraction of time down | episodes | mean s | median s | p90 s | max s |
|---|---|---|---|---|---|---|---|
| moderate | nexus | 0.686 | 348 | 11.9 | 3.6 | 38.6 | 59.5 |
| moderate | modern | 0.589 | 864 | 6.0 | 1.8 | 17.2 | 59.4 |
| sat | nexus | 0.831 | 137 | 13.6 | 6.8 | 43.0 | 64.4 |
| sat | modern | 0.696 | 403 | 8.3 | 1.5 | 30.2 | 58.0 |
| hold | nexus | 0.907 | 1107 | 37.0 | 3.1 | 117.0 | 966.6 |
| hold | modern | 0.770 | 1968 | 31.0 | 3.0 | 93.6 | 598.8 |

The 60 s arms max out at 59.5, 59.4, 64.4 and 58.0 seconds — the step length.
The censoring the hold arm was designed to remove is visible in the numbers,
and removing it moves the maximum from one minute to sixteen. Use the hold row.

The distribution is heavy-tailed, not exponential: the median outage is about
three seconds while the mean is thirty-plus and the p90 is one to two minutes.
A model drawing outages from an exponential with the mean will produce far too
few short outages and far too few very long ones. Draw from the empirical
episode lengths.

Episodes still open when a step ended are counted in the "fraction down" column
but excluded from the duration statistics, so the durations remain slightly
right-censored even in the hold arm.

## Result 3 — what a radio actually put on the air

Bytes transmitted per node-second. The saturating arm is the per-radio ceiling.

| arm | nexus | modern |
|---|---|---|
| moderate | 5,260 B/s | 8,194 B/s |
| sat | **4,180 B/s** | **9,406 B/s** |
| hold | 1,762 B/s | 4,767 B/s |

The modern ceiling of 9.4 kB/s sits near the 8.2 kB/s per-radio cap already in
the calibration plan. The Nexus reaches less than half of it. At the measured
mean of 4.6 links that is roughly 0.9 kB/s per link on a Nexus and 2.0 kB/s on
a modern handset, against the plan's 1.6 kB/s per-link figure.

By content, 74–83% of transmitted bytes were message payload, 12–19%
acknowledgements and 4–6% sync filters. Treat the ack and sync shares as lower
bounds: the trace's content classifier (`_sealedContentById`,
`grassroots_network.dart:2478`) is a FIFO capped at 8192 entries and sat at that
cap for the whole run, so packets sealed earlier lose their label and fall into
the unclassified `secure` bucket. This affects the trace ledger only, never
delivery.

## Result 4 — arrival, and the decay inside each arm

| arm | offered | arrived | ACK-confirmed | direct-written | buffered |
|---|---|---|---|---|---|
| moderate | 56,000 | 56.3% | 38.6% | 36.3% | 63.7% |
| sat | 289,305 | 20.7% | 10.5% | 21.3% | 78.7% |
| hold | 538,784 | 22.9% | 10.8% | 16.8% | 83.2% |

Arrival falls monotonically within every arm: moderate 0.946 at t1 down to
0.326 at t10, sat 0.288 down to 0.128 by t5, hold 0.559 down to 0.065. The
buffer is purged only on the first run of each arm, by design, so runs inside an
arm share one accumulating state rather than reaching a steady one. Whatever the
mechanism, **the runs inside an arm are not independent samples** and should not
be pooled as if they were. The first run of each arm is the only one that starts
from a purged buffer.

The buffer was not the limit. Peak occupancy was 75 k–163 k packets and
12.6–25.8 MB per node against the 512 MiB cap, so eviction never fired, and
`dtnRecipients` was 7 everywhere. Peak equals final on every node: the buffer
filled and never drained.

Wire RTT medians run from 8 s to 600 s across steps and the p90 reaches
1.1–1.5 million ms. Messages are being delivered by the carry path minutes to
tens of minutes after they were composed, which is the store-carry-forward
design working, at a latency the fixed-load arms cannot show.

## Result 5 — custody exits, and whether retirement ran the show

Every packet that left a DTN buffer, pooled over the fleet:

| exit | count | share |
|---|---|---|
| end-to-end ACK | 110,903 | 83.3% |
| retired on the recipient's own seen-filter | 22,196 | 16.7% |
| age expiry | 0 | — |
| eviction (bytes or recipients) | 0 | — |

Retirement fired against all seven peers on all eight phones, over 163 to 1,223
answered filter rounds per device, and accounts for 11–21% of exits depending on
the handset. Nothing aged out and nothing was evicted, which follows from
Result 4: the buffer never came close to its cap.

So the answer to the question this column exists for is **no** — these custody
numbers describe the mesh, not the retirement rule. Acknowledgement is the
dominant exit by five to one.

Two cautions on reading it further. Retirement is 100% of *non*-ACK exits
here, simply because it is the only non-ACK exit that fired at all, so that
ratio carries no information in this run. And `retired_frac` in
`retirement.csv` is documented as retirements over non-ACK exits
(`analyze.py:1047`) but computed as retirements over *all* exits
(`analyze.py:1076`). The column is the second of those. The documentation is
wrong, not the numbers.

## Result 6 — air rate depends on link count, and on how long the load has run

Result 3's per-arm figures average over a link-count distribution centred on
4.6, so they are not per-link-count rates and must not be compared against a
measurement taken at fixed k. Split by the node's concurrent link count at the
time, bytes transmitted per node-second:

| arm | class | k=3 | k=4 | k=5 | k=6 | k=7 |
|---|---|---|---|---|---|---|
| moderate | nexus | 2,812 | 4,814 | 5,119 | 6,153 | 7,029 |
| moderate | modern | 7,095 | 6,594 | 7,788 | 8,742 | 8,508 |
| sat | nexus | 3,936 | 4,053 | 4,540 | 5,113 | 4,354 |
| sat | modern | 4,456 | 6,883 | 9,157 | 9,479 | 13,224 |
| hold | nexus | 3,581 | 2,947 | 1,495 | **434** | **345** |
| hold | modern | 4,236 | 4,925 | 5,344 | 5,983 | 5,692 |

The moderate row settles an apparent conflict with the clique's per-radio
figure: a Nexus at five to seven links airs 5.1–7.0 kB/s here, which is what
the clique measured at stable links. The lower whole-arm averages in Result 3
are an aggregation over k, not a different radio.

The hold row is the finding. **A Nexus holding six or seven links under
sustained load stops transmitting** — 434 and 345 B/s, an order of magnitude
below the same handset at three links, and against 5,983 B/s for a modern
handset in the same condition at the same link count. The effect is specific to
this arm: the same phones at the same link count air 6.2 kB/s in the moderate
arm. What distinguishes the hold arm is duration and an accumulating buffer, not
link count, so the trigger is time under load rather than degree alone.

A capacity model cannot represent this as a per-radio constant. On the Nexus
class the rate rises with k for the first few links, peaks around three to four,
and then falls away once the node has been loaded for several minutes.

**Per LINK rather than per radio**, the same measurements divided by the link
count. This is the denominator a link-capacity model wants, and it is a
different number by a factor of k:

| arm | class | k=4 | k=5 | k=6 | k=7 |
|---|---|---|---|---|---|
| moderate | nexus | 1,204 | 1,024 | 1,026 | 1,004 |
| moderate | modern | 1,648 | 1,558 | 1,457 | 1,215 |
| sat | nexus | 1,013 | 908 | 852 | 622 |
| sat | modern | 1,721 | 1,831 | 1,580 | 1,889 |

About 1.0 kB/s per link on a Nexus and 1.5 kB/s on a modern handset, against the
1.6 kB/s per-link ceiling the calibration plan already carries. A per-radio
figure of 7 kB/s and a per-link figure of 1.0 kB/s are the same measurement at
seven links; quoting either without its denominator is how a capacity model ends
up four times too fast. Row data:
`trace_server/analysis/churn-n8-1-outages/air_rate_by_degree.csv`.

## Per-episode outage data

`trace_server/analysis/churn-n8-1-outages/` holds one row per outage episode,
for sampling rather than for fitting a parametric form:

- `outages_send_level.csv` — `arm, step, class, node, peer_node, duration_s,
  censored`. 6,042 rows. An episode opens at the first send to a peer that finds
  no live link and closes at the next send to that peer that airs, so it is
  bounded by send cadence and by the step. Hold arm: 1,107 closed (nexus),
  1,968 closed (modern), plus 260 and 210 still open at the step end.
- `outages_link_level.csv` — `arm, class, node, peer_node, duration_s,
  censored`. 2,975 rows. An episode runs from the moment a peer's last GATT leg
  drops to the moment its first leg comes back, so it spans steps. Hold arm:
  551 closed (nexus), 797 closed (modern), plus 20 and 15 open.

The two measure different things and differ by an order of magnitude in the
median (3 s against 34 s). Use the link-level file for "the link is down" in a
two-state link model; use the send-level file for "a send found no link".
Censored rows carry the time from the drop to the end of that device's
observation, so keep them for a survival estimate and drop them for a naive
mean. They are not a rounding detail: the 20 Nexus and 15 modern censored
episodes in the hold arm have lower bounds averaging 1,146 s and 1,390 s
against closed means of 162 s and 114 s. They are the longest outages in the
run, every one truncated by the observation ending rather than by recovery, so
a closed-only resample is optimistic in exactly the tail that matters.

## Result 7 — does a node with more links up lose links faster?

Yes on both classes, strongly on modern and weakly on the Nexus.

Hold arm only; the other two break links between runs, which inflates their
rates four- to five-fold for a reason that is not the radio. `links_up` is the
node's own concurrent peer count at the moment of the loss.

**A peer-link loss is the moment a peer's LAST GATT leg drops.** That
distinction is the whole table: a converged pair holds two legs, so a peer going
unreachable usually produces two `drop` records, and counting legs overstates
churn by a factor of 1.4 to 1.7. It is also the same event that opens an episode
in `outages_link_level.csv`, so hazard and outage duration share one definition.
Both columns are in the row data; `leg_drops_per_node_minute` is there for
comparison, not for a model.

| links up | nexus /node-min | nexus /link-min | modern /node-min | modern /link-min |
|---|---|---|---|---|
| 1 | — | — | 0.65 | 0.65 |
| 2 | 1.13 | 0.56 | 0.81 | 0.41 |
| 3 | 1.18 | 0.39 | 1.38 | 0.46 |
| 4 | 1.36 | 0.34 | 1.45 | 0.36 |
| 5 | 1.28 | 0.26 | 2.20 | 0.44 |
| 6 | 1.44 | 0.24 | 2.92 | 0.49 |
| 7 | 1.57 | 0.22 | 2.55 | 0.36 |

A modern handset's per-node loss rate rises about 4.5-fold from one link to six.
A Nexus 5X rises about 40% from two links to seven — a real trend, but a shallow
one, and it was invisible in the leg counts, where double-counting flattened it
into a horizontal line.

Per individual link the hazard falls on both classes, 0.57 to 0.22 on the Nexus
and roughly flat around 0.4 on modern. So more links means more losses per node
without each link becoming much more fragile.

**Caution, added 2026-09-11: the per-link hazard by class is confounded by
per-link load, and reading it as a handset-robustness difference is wrong.**
Cross-referencing against `air_rate_by_degree.csv` (hold arm, bytes per link
per second): the Nexus's per-link throughput collapses as k rises — 901, 1194,
737, 299, 72, 49 B/s at k=2..7 — and its per-link hazard falls in the same
order, 0.56, 0.39, 0.34, 0.26, 0.24, 0.22. Modern's per-link throughput stays
high throughout (1299 down to 813 B/s) and its hazard stays correspondingly
higher (0.36-0.49) at every k≥3. Pooling both classes and plotting hazard
against throughput per link rather than against k shows one rough rising
trend, not two class-separated ones: a link carrying 50-100 B/s is nearly idle
and of course survives; a link carrying ~1,000 B/s under contention is the one
actually being stress-tested. **The Nexus does not have a more robust link —
it is failing to keep up (Result 6), and an idle link is a stable link.**
Do not cite "Nexus loses links less often" as a hardware finding without this
throughput context. One combined figure carries both axes at once —
`hazard_combined.pdf` / `plot_hazard_combined.py` (scratchpad, 2026-09-11):
per-link hazard (y) against per-link throughput (x, log), one line per class
walking k=1/2→7 in order, endpoints labeled.

**Why per-link hazard falls with k even though per-node hazard rises (both
classes):** per-link hazard is per-node hazard divided by k. Per-node hazard
does rise with k as intuition expects — modern 0.65→2.92 losses/node-min
(4.5x, k=1→6), Nexus 1.13→1.57 (1.4x, k=2→7) — but neither rises anywhere
near k-fold, so dividing by the growing k drives the per-link average down.
The counting itself is not double-counted: `peer_link_losses` in the row data
is already the peer-level ("last leg drops") count, not the leg-level one —
compare the `leg_drops` column alongside it, e.g. Nexus k=6 is 146 leg drops
against 106 peer-link losses, the same 1.4x this document's Result 7 text
already names.

The k=7 row rests on 19.2 node-minutes of Nexus exposure and k=2 on 11.5, so
both ends of that curve are thin. Per-node and per-link rates point opposite
ways by construction; a figure showing only one of them reads as the opposite
conclusion from the other, so plot both.

Row data: `trace_server/analysis/churn-n8-1-outages/churn_rate_by_degree.csv`.

## Open, for whoever picks this up

- `degreeAtEvent` is present on every `sent` record and is **0 in all
  8,501,011 records**. It is `_reachablePeerCount()`
  (`message_router.dart:278`), which counts peer RECORDS flagged
  `bleAuthenticated`, and `isReachable` needs such a record to exist
  (`peers_state.dart:269`). Sessions were 7 on every phone throughout, so the
  sessions existed and the records did not — the same record-instead-of-session
  gate CLAUDE.md warns about, one layer down. The link count at send
  time had to be reconstructed by joining against `links.csv`. Populating it
  would make u(k) a one-line query.
- Two step labels appear twice in `steps.csv` (`N=8 L=hold t9` with 58 sends and
  a second `N=8 L=hold t10`), so the last hold steps are split across segments.
  Check before using per-step hold numbers.
- The `custody exits by reason:` line that `analyze.py` is supposed to write
  (`analyze.py:1898`) does not appear in `summary.txt` for this run. The table
  above was taken from the database directly.
- `goodput_Bps` is negative in some rows of `summary.txt`. The window arithmetic
  is wrong somewhere; the `air_Bps` figures above are computed from `wire`
  records directly and are unaffected.
