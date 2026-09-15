# Plan: link churn and throughput per active-link count — testbed run

> **Reduced spec, Dan, 2026-09-10 — this supersedes the sizes below.** The
> simulated fleet is Nexus and every simulated node holds the cap of seven
> links, and the clique already gives the Nexus rows at k = 2..6. So the
> run is **N = 8 only**, eight phones (the four Nexus at join order 1–4 plus
> four others), which puts every Nexus at k = 7:
>
> - fixed-load arm, 10 runs (churn hazard, repair, unavailability,
>   establishment, delivery at k = 7);
> - saturating arm, 10 runs (per-radio budget at k = 7);
> - long-hold arm, 3 runs of ten minutes (uncensored outage durations at
>   k = 7);
> - optional, only if a tenth phone is on hand: 10 saturating runs at
>   N = 10 to test whether the cap of seven binds.
>
> About one hour of running plus setup. Everything else in this file
> (resets, sessions kept, marker, pair table, links.csv, archive rule,
> length check) applies unchanged. Nodes that drop below seven links in the
> simulation use the clique's k = 2..6 rows.


Dan's spec, 2026-09-10, written down by the oversight session (tum-42).
Supersedes the earlier three-arm version of this file entirely. Repository:
`~/git/TUM/grassroots-social-networking`. Everything below already exists in
the harness as a step field; the work is one preset and the per-device
analysis table.

**Cutoff: raw uploads on the hard drive by 11 September.**

## The run

- **Fleet.** The four Nexus 5X at join order 1–4. N grows to **10**, one
  phone per step, so ten phones in total. If only eight are on hand, stop at
  N = 8 and say so.
- **N starts at 4**, as Dan specified. (N = 2 and 3 were added on
  2026-09-10 and struck the same day: the argument for them belonged to the
  earlier saturating design. At a fixed 100 messages per destination per
  minute, N = 2 is nowhere near capacity and measures nothing the clique's
  N = 2 cell and the two-node line sweep have not already measured in depth.)
- **Ten runs per N**, seven sizes, seventy runs.
- **Each run:**
  1. **60 s send.** Every device sends **100 messages to every Noise session
     it holds** (per-destination rate, as the harness's round-paced path
     already does with `sendTo: 'all'`, `sendCount: 100`, `dwellSec: 60`).
  2. **60 s quiet.** Nothing sent; messages and acknowledgements land.
  3. **Purge DTN buffers and break every link** on every device
     (`resetLinks: true` on every step, plus the DTN clear). **Noise
     sessions are never reset** (`resetSessions` false on every step,
     including the first). The testbed starts warm: before the first run
     the operator establishes sessions between all devices by hand, so
     every run measures link establishment against sessions that already
     exist.
- Nothing else changes between runs. Payload 138 B as before.

Roughly 2.5 minutes a run with the reset window, about three hours for the
seventy runs.

**This run produces no capacity constants.** Nothing in it saturates: the
load is fixed at 100 messages per destination per minute, so the throughput
columns are what the phones carried under that load, floors and not
ceilings, and must not be read as a per-radio byte budget. The budget as a
function of link count would need a saturating arm, which the rewrite
dropped on purpose. What this run measures is churn, establishment and
delivery under a fixed load, by link count and by class. The clique's
saturated 6.8 against 9.5 kB/s per radio at six links stays the only
capacity evidence.

**Sessions and joins.** The operator establishes Noise sessions by hand
before the first run between the phones that are up at the first step.
Phones that join later are dark until their step opens (`scriptedRadio` with
`cliqueN`), so they can only handshake at their join, inside the join gap;
that is by design and is not churn. The session-loss rule below therefore
exempts the joining device and its peers during the first run of each new N.

## Two additions so this is the last run (2026-09-10, pending Dan's go)

1. **Saturating steps at N = 4, 7, 8 and 10**, ten runs each, same preset
   with `saturate: true, sendLanes: 1`, label `N=$n L=sat t$t`, run after
   the fixed-load sweep. k = N−1, so these give the Nexus per-radio ceiling
   at k = 3, 6 and 7, and N = 10 offers nine peers, past anything a Nexus
   has been seen to hold, so it shows whether the cap of seven binds or
   not — the only direct evidence a `maxDegree` can get. (An earlier draft
   said N = 10 for k = 7; that assumed the cap rather than testing it.) The
   simulator's budget today rests on the clique's k = 5 and 6 only; k = 7 is
   copied from 6 and k = 3 is a floor. About fifty minutes. This reverses
   the "no capacity constants" paragraph above for these sizes and only
   these. Note that with four Nexus in a fleet of ten, k = 6 and 7 are a
   Nexus among mixed peers, not Nexus-to-Nexus; that is fine for a
   per-radio budget, which is about what the radio carries, not to whom.
2. **Stamp the live peer count on-device at every step boundary**, a marker
   carrying the device's own count of peers with an open link. That gives
   the k axis from the phone rather than from any reconstruction, which has
   been wrong twice today, and it is the only in-run source for the cap.
   Small runner change.

3. **For churn specifically, two things.** (a) The analysis must produce
   the pair table the clique had — per pair and per run, `sent`, `aired`,
   `queued` — because the simulator's link-unavailability `u(k)` is the
   fraction of sends that found no link at send time, and link-stage
   `drop` counts undercount it by an order of magnitude (a link can be up
   and unusable). Hazard and repair come from `links.csv`; `u(k)` comes
   from the pair table; report both and they must reconcile. (b) Outage
   durations are censored at a run's 120 s, and the clique showed means of
   one to five minutes. **Approved by Dan 2026-09-10: a long-hold arm**,
   three runs of ten minutes at N = 7 and three at N = 10, fixed load, no
   link resets inside the run, so a link that drops is watched until it
   returns or the run ends. That is the only way to measure the
   outage-duration draw uncensored. About an hour. Run it last; report
   outage durations with the censored fraction at ten minutes beside them.

With these, the run yields everything the simulator takes: budget B(k)
for the Nexus at k = 3, 6, 7 (saturated); outage hazard and duration per k
from forced breaks with real timestamps; establishment time per k; delivery
per k under the fixed load as the validation target; the k axis and the cap
from the phones themselves. What no clique run can give is relay share and
conveyance cost, since the clique is diameter one; those are already
measured on the ring (1.65x, 1.25x, 195 B frames) and are used from there.

## What to measure, per device and per run

Everything is already logged; this is the analysis table.

- **Time to link establishment**, per peer, from the run's start marker to
  `gattConnected` and `connected`. Sessions persist across runs, so a
  `session` stage inside a run is a session loss — except for the joining
  device and its peers in the first run of a new N, where it is the join.
- **Link lifetime**: from establishment to `drop`, or censored at the run's
  end.
- **Link breaks**, with timestamps, and the device's **number of active
  links at that moment**.
- **Throughput**: bytes sent and received per second per device, and
  messages sent, arrived, acknowledged.
- **Active-link count over time**, sampled, since above N = 8 the seven-link
  cap binds and a device holds fewer links than it has peers.

## What comes out

Grouped by the device's active-link count at the time of each event, and
by device-class pair (Nexus–Nexus, Nexus–modern, modern–modern). **Retracted 2026-09-10: there is no Nexus link cap in the data.** An earlier version of this paragraph said the Nexus 5X held at most six links, on two runs. The count behind it was a measurement bug in the concurrency tracker (it keyed the open set on peer identity, which `gattConnected` does not carry, so it counted closes and missed opens). A recount then returned eight and nine on both classes, and that number is an artefact too: ten to thirty percent of paths never receive a close event, so the tracker drifts toward cumulative peers ever linked, which saturates at the ring's nine. **No concurrency ceiling from the ring analysis stands, in either direction.** The seven-link cap is sourced to Dan's direct observation, seven being the most he has ever seen a Nexus 5X hold, and to nothing else. Everything built on the six is void; **group by k alone**. The reduction was fixed the same day on Dan's go: a device holds at most one leg per peer and role, so a new path for a pair that already has one supersedes it, which bounds the open set from the protocol with no timeout. Validated against the ring gate, whose permitted degree is 2r capped at N-1: `links_mean` now tracks 2.73, 4.48, 5.29, 5.92, 6.13 against permitted 2, 4, 6, 8, 9 (before the fix it sat flat at 6 to 8 whatever the gate allowed). Use `links_mean`, which tracks but runs high at small radii; do not use `links_max`, which still overshoots on radius transitions. Sustained concurrency tops out near 6 even where 9 are permitted, which corroborates Dan's seven as an upper bound without measuring a ceiling; the source stays his observation. For this run, the active-link-count column uses this reduction.

The per-link rate difference reported after the recount (270 against 571 B/s) is withdrawn too: every device sent the same number of messages at the same 98.2% arrival, so the modern phones aired about twice the bytes for the same delivered work. That is airtime cost per delivered message, not capability, mechanism not identified (relay share, sync, acknowledgements or retransmission, separable by packet kind in the wire records). Checked against the clique's own wire bytes (2026-09-10): there the ratio is 1.3x, not 2x — 500 against 382 bytes aired per message sent — and it is spread across every packet kind (data 286 against 223 per message sent, acknowledgements 175 against 152 per message received, sync 42 against 35, announce 18 against 14), which reads as the modern phones receiving and relaying more rather than any one mechanism. No class constant comes out of either dataset. The clique's saturated per-radio figures, 6.8 against 9.5 kB/s at six links, remain the only capacity evidence, and the 0.57 against 0.89 arrival split at N=7 is an observation without a supported mechanism. There is no fallback: a Nexus-fleet simulation caps
links at six, and the simulator's `maxDegree` follows the fleet switch (6
for Nexus, 7 for modern).

- **probability that a link breaks per second** = breaks / link-up seconds;
- **mean link lifetime**, with the censored fraction reported;
- **time to establishment** at each k;
- **throughput per device** at each k, and per link — under the fixed
  load, so a floor where nothing was lost and a carried rate where it was;
  not a ceiling;
- delivery and acknowledgement rates.

- **the wire bytes split by packet kind**, per device and per message sent, with the data column read against the others. Reason (2026-09-10): comparing the clique (diameter one, nothing to relay) with the ring (relaying required), the modern-to-Nexus ratio of bytes aired is about 1.3 for announce, sync and acknowledgements in both runs, and for data it is 1.28 in the clique but 2.03 in the ring. So the class gap looks like a 1.3 baseline in all activity, cause unidentified, plus a relay-share excess on the modern phones where transit traffic exists. The candidate mechanism is the request-driven conveyance itself: the fastest phone to answer a neighbour's sync filter carries the copy, so relay load concentrates on the fastest hardware. The direct check was run on the ring's custody records (2026-09-10, from the drive copy): convey events modern over Nexus 1.65x, with `store` and `end` at exactly 1.00x as the control, so both classes took the same packets into custody and retired the same and differed only in how many they handed onward. Relay share is measured, and the request-driven explanation survives as its leading cause. It is not the whole 2.03x: the extra bytes per extra conveyance come to about 204 B against a 244 B frame, and secure bytes per aired data packet imply 122 B on the Nexus against 153 B on the modern phones, which cannot both be full 244 B frames. The likelier reading of that residual is a Nexus deficit rather than a modern excess: a conveyance is logged before the write, and the Nexus had refused writes thirteen to one in the clique, so part of its logged conveyances never reached the air. The check closed it (2026-09-10, wire records on the ring): frame size 195 B on the Nexus against 192 on the modern phones, identical, so MTU and fragmentation are out; packets aired per logged conveyance 0.66 against 0.82, so the Nexus airs a third of its conveyances into nothing, with `writeFailed` per device 525 against 355 as the independent total. 1.65 x 1.25 = 2.06 against the observed 2.03, from three separately sourced counts. The airtime gap is therefore the fleet meeting the design, not carrying capacity: relay load concentrates on the faster phones because the first neighbour to answer a sync filter carries the packet, and the slower phones then lose a third of what they try to convey at the write. No per-link rate constant follows from it. In this run, a step where every kind moves together is the baseline effect; a step where data moves alone is relay share.

**Decision 2026-09-10: the simulation assumes a Nexus 5X fleet.** So the rows that matter are Nexus at each k; the modern phones are in the run to make N = 8..10 exist, which is what pushes a Nexus to k = 7 and past its cap, and their own rows are a by-product. What this run adds that the clique could not: the k = 7 row, which the clique never reached (N = 7 gives k = 6) and which the simulator currently assumes from k = 6; the over-cap regime at N = 8..10, where a phone has more peers than link slots and links churn by design, which is the hall's regime; outage and re-establishment times measured from forced breaks with real timestamps, instead of censored 60 s slots; and the establishment cost the simulator currently charges nothing for.

The Nexus–Nexus row at each k is the one the simulator takes by default;
the other two rows are the sensitivity bound.

## Rules

- Archive the raw uploads the same day, before analysis. The trace server
  has been reset before; clique-final was lost to it, and dial-8-n11 and the
  17–27 August runs survive only on the external drive.
- Log the join order; the class mapping comes from it.
- Analysis output goes as `steps_by_device.csv` (one row per device and
  run) plus a `links.csv` (one row per link event with device, peer, stage,
  timestamp, and the device's active-link count), so the grouping above can
  be recomputed by anyone.

Results to the SIMULATION session for the constants and to tum-42 for the
record.
