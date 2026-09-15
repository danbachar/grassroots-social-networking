# Testbed experiment kit

Instrumentation and drivers for the two physical-layer baseline experiments in
the evaluation chapter: **control plane** (RSSI & link establishment on a
line) and **data plane** (throughput of a diluting clique). Everything lives
behind the debug Testbed screen (Settings → Testbed) and is inert in
production.

## Experiment recording

Press **Record** on the Testbed screen with an experiment id (e.g.
`cp-line-approach-1`): from that moment every trace record — RSSI samples,
link stages, wire-byte ledger, message send/recv/deliver, markers — is
appended to `exp_<id>.jsonl` in the app documents dir. Files are never
pseudonymized (real pubkey hex throughout, correlatable across devices) and
leave the device only on your explicit action:

- **Share files** — share sheet (AirDrop/Drive/etc.), works offline;
- **Upload files** — one tap POSTs every exp file to the trace server
  (`trace_server/`, the same `/v1/traces` endpoint; envelope `deviceId` is
  this device's pubkey hex, `experiment` is the file name). Requires a build
  with `--dart-define=TRACE_TOKEN=<token>` and the server running
  (`trace_server/docker-compose.yml`, `TRACE_UPLOAD_TOKEN` matching).
  Uploads are idempotent per unchanged file; files stay on the device until
  **Clear files**.

Every device participating in a run should be recording; files are merged
offline (each record's `t` is the device's epoch ms — keep the fleet
NTP-synced, or bound skew with a start-of-run marker ritual on each device).

### Record types (JSONL, one object per line)

| type | emitted | fields |
|---|---|---|
| `marker` | expStart / expStop / **Mark** button | `event`, `label`, `exp`, `t` |
| `rssi` | every adv sighting (≤1/s/path) + the 10 s connected-RSSI poll | `src` (`adv`\|`conn`), `path`, `role`, `rssi`, `peer`, `t` |
| `link` | stage transitions | `event` = `discovered` (verified ANNOUNCE, 1/announce-cycle), `connected` (GATT leg ready), `session` (Noise established), `usable` (first e2e ACK after session), `drop` (leg lost, with `reason`); + `peer`, `path`, `role`, `rssi`, `t` |
| `wire` | every 10 s while traffic moved | per-outer-type tx/rx `{bytes,packets}` deltas: `announce`, `handshake`, `secure`. Our OWN tx `secure` is split by inner content at seal time — `secure:data`, `secure:ack`, `secure:receipt`, `secure:sync` — while rx `secure` stays aggregate, exactly what a peer on the air can distinguish |
| `message` | send / recv / delivered / dup (dup = the same logical message re-delivered; should be 0) | `messageId`, `peer`, `payloadSize`, `appLatencyMs`, `relayHops`, … |
| `packetDup` | a redundant PACKET arrival dropped by the packetId bloom (dual-leg copy, re-flood, sync-exchange conveyance). Outer `packetId` — a different namespace from `messageId`, never join the two |
| `drop` | a packet or message lost, one shape for every site | `where` (relay/decrypt/frame/announce/ack/receipt/sync/seal/ackIndex/reassembly/handshake/bleSend/bleBroadcast/bleRx/udpSend/udpConnect/udpRx/ackTx/receiptTx), `reason`, plus whatever ids were in scope |
| `buf` | occupancy of every message-path buffer, sampled every 10 s + at both run boundaries | `dtnPackets/dtnRecipients/dtnBytes`, `preSeal/preSealBytes`, `ackIndex`, `sessions`, `reassembly/reassemblyBytes`, `sealedContentIds`, `outgoingTracked`, `traceBufferedBytes/Records` |
| `app` | app lifecycle (resumed/paused/…) — screen & background confound witness | `event` |
| `custody` | a packet's buffer lifecycle: direct (the originator wrote it straight on a live link — the one packet movement outside the sync exchange) / store / convey / end | `packetId`, `recipient` (holder side only), `held` (buffer occupancy); `direct` and `convey` carry `via` (`ble`/`udp`); `convey` carries `toDevice`/`toPeer`/`ttl`; `end` carries `reason` |
| `relay` | this node forwarded someone else's packet | `packetId`, `ttlIn`/`ttlOut`/`hop`, `fromDevice` (BLE path), `fromPeer` (the authenticated neighbour it came from — the topology EDGE; null before the path is identified), `carried`, `degreeAtEvent` |
| `power` | fuel-gauge sample every 10 s while recording | `currentNowUa` (Android sign convention: negative = discharge; recorded raw), `chargeCounterUah`, `levelPct`, `voltageMv`, `tempDeciC`, `charging` |

## Auto runner (scripted, hands-free)

Instead of driving the markers/dwell/upload by hand, load a **plan** and let
the app run it. Testbed → **Auto runner**: pick a **preset** from the
dropdown (line sweep, diluting clique, or the clique's desk-sized smoke
test) or paste JSON directly — then **Launch**. The full-screen runner then,
per step: shows the target label, waits for your
**IN POSITION** tap (which stamps the marker), holds the dwell with a
countdown (buzzing when it ends), and advances. The tap is only required
when you actually moved: a step whose distance equals the previous step's
(a repeat trial at the same position) **auto-advances** after a short settle
gap — IN POSITION becomes a "start now" skip. So a same-distance repeat run
needs just one tap to begin, then runs hands-free.

**Two devices, one moves.** Only the moving device runs the plan. The static
device is **record-only**: give it the same experiment id, press Record, and
Stop + Upload when the sweep ends — the moving device's distance markers
segment the static device's trace offline (keep the two phones' clocks
NTP-synced). After the last step the runner stamps `end`, settles, stops
recording, and uploads — no further taps. (On 3+ devices load the same JSON on
each; two devices need nothing shared — plans are rosterless.)

```json
{
  "expId": "cp-line-2",
  "resetSessions": true,
  "steps": [
    {"label": "d=1 anchor",     "dwellSec": 120, "sendCount": 5},
    {"label": "d=5 anchor",     "dwellSec": 120, "sendCount": 5},
    {"label": "d=120 approach", "dwellSec": 180, "sendCount": 5},
    {"label": "d=80 approach",  "dwellSec": 180, "sendCount": 5},
    {"label": "d=40 approach",  "dwellSec": 180, "sendCount": 5},
    {"label": "d=20 approach",  "dwellSec": 180, "sendCount": 5},
    {"label": "d=10 approach",  "dwellSec": 180, "sendCount": 5},
    {"label": "d=20 retreat",   "dwellSec": 180, "sendCount": 5},
    {"label": "d=40 retreat",   "dwellSec": 180, "sendCount": 5},
    {"label": "d=80 retreat",   "dwellSec": 180, "sendCount": 5}
  ]
}
```

Per step the runner: bounces the BLE transport when `resetLinks` is set (the
line-sweep default — a full disable/enable like the settings toggle, so the
pair goes dark and re-establishes through the clean cold-start election
rather than a chaotic same-identity redial; the step waits for the transport
to come back — the dark gap is two announce cycles + 10 s unless the plan
sets `linkResetDarkSec`, which is only sound when EVERY device bounces at the
same step boundary, since then both sides dispose together and no stale path
survives to wait out), drops all Noise sessions (`resetSessions`, so the
establishment ladder re-runs from a cold handshake every step), stamps the
marker, and — when `sendCount` > 0 — sends that many `sendBytes`-sized
messages (**default 138** — see Payload size below). Sends are **gated on the link being settled**
(authenticated session + converged dual-leg pair; a `link-settled` marker
stamps the moment) and then paced at the FULL dwell's interval until the
dwell ends — data never races a re-forming link, a late settle sends fewer
messages rather than the same count faster, and a step where no peer
settles sends nothing (the correct zero at an out-of-range distance). Sessionless peers
re-handshake eagerly on ANNOUNCE from either side, so settling needs no
data-send trigger. Targets: with **no
`roster`** (the two-device default) every identified peer, labeled by 8-hex
pubkey prefix — no manual pubkey entry; with a `roster`, every other roster
row (roster labels name the ids), and a device not in the roster sends
nothing — that's the static receiver on 3+ device campaigns. Ids are the
reproducible UUIDv5 set `field|expId|src|dst|step|seq`, so the offered
count is computable offline.

**Payload size.** The default is **138 bytes**: the largest payload that
still fits ONE sealed packet at the BLE floor MTU
(`FragmentHandler.fragmentThreshold`, exported as `defaultSendBytes`). At
that size one message *is* one packet, so message counts, delivery ratio and
wire bytes all read per-packet with nothing hidden. Above it the payload
fragments, and **each fragment re-pays the full 106-byte overhead** (60 packet
+ 25 Noise + 21 frame): a 184-byte message — the arbitrary default used
before 29 Jul 2026 — is silently *two* packets, 138 + 46, costing 396 wire
bytes to move 184. Measurements taken with it are valid but describe the
fragmented case; the cycle-check traces show ~1140 bytes on air per delivered
184-byte message (6.2x) under the old both-legs flood.

**Dead-radio watchdog.** A step with `bleOn: true` is checked 30 s in on two
signals, and the order matters:

1. **Transport usable** — the primary check, because it holds even when the
   radio is up *alone*. The ladder's `solo` steps do exactly that: one phone's
   radio on, the peer's deliberately off.
2. **Bytes moved** — checked only when a peer is currently known. `WireLedger`
   counts at the GATT send/receive choke points, so advertising and scanning
   are invisible to it and a healthy lone radio reads zero. Requiring bytes
   unconditionally would abort every `solo` segment of a *good* run.

Either failing aborts the run, logs a `runner/bleDead` record naming which
signal tripped, fires the same haptic the step boundaries use, and shows RUN
ABORTED in red instead of a green tick. This exists because a 2 h power ladder was recorded against a radio that
never came back up after the first `bleOn: false` — `setBleActiveForTestbed`
has several early returns that leave BLE down without throwing, so a
successful-looking await is not evidence the radio is running. Only bytes are.
Steps with `bleOn: false` are never watched (zero bytes is the point), nor are
steps whose dwell is shorter than the watchdog.

**Per-step buffer reset.** `resetDtnBuffer` (default **on**) empties the DTN
memory buffer at every step start, stamping a `custody-reset` marker. Without
it an overrun step's undelivered backlog survives in the buffer and drains into
the
next step's window via the sync exchange — steps contaminate each other and
`delivery_rate` never dips, because the buffer eventually heals everything.
Clearing makes each step's delivery its own verdict: an overrun now shows as
`delivery_rate < 1.0` at that step. The mesh experiments (3 and 4) set it
**off** in their plans — the buffer surviving across steps is the thing they
measure. Note the static device's store is NOT cleared (it runs no
plan); the confirmations it holds are few and the sync exchange only conveys
what the runner actually lacks.

**Power.** While recording, the fuel gauge is sampled every 10 s into
`power` records. `steps.csv` gains per-device columns (`power_mA_<dev>` =
median absolute discharge current, `energy_mAh_<dev>` = charge-counter drop
over the step) and the summary reports battery start→end per device.
Constraints: phones must run **unplugged** (a charging sample reports charge
current, not consumption — flagged `power_charging_<dev>` and excluded);
absolute draw is screen-dominated, so the honest numbers are differential —
per-phase, per-distance, per-message within one device; never compare across
devices.

**Path reconstruction.** `mesh_paths.csv` has one row per *sent* message, so
an undelivered message still yields its partial path — how far it travelled
before dying, with `carried` marking that it entered some node's buffer and
may yet arrive. Chains are built from `fromPeer` EDGES (each forwarder names
the neighbour that handed it the packet), so `A -> B -> C` is evidence, not
inference; `pathExact` is False when any hop had to fall back to time
ordering (unidentified path, or a forwarder whose parent was outside the
experiment) and empty when the message has no edges at all. Two limits worth
knowing: only devices *in the experiment* appear, so an outside forwarder is
invisible; and `fragmented: true` rows report `relayHops: 0` regardless of
reality, because each fragment carries a random packetId that cannot be
joined to the messageId (nothing fragments at the 138 B default).

**Power baseline (desk, unplugged) — method, no plan in the presets.** Nothing
in the dropdown builds this ladder; it is written down because the analysis
below still reads the traces it produced. A screen-constant condition ladder
runs on both phones simultaneously — same segment labels, complementary roles
(P1/P2): `base` (BLE down on both), `solo`/`solo2` (one phone up alone:
advertise+scan cost), `linked` (both up, session, silent: control-plane
upkeep), `light`/`light2` (one phone sends ~1 msg/s), `heavy`/`heavy2` (one
phone sends flat out — the measured capacity knee; radio + seal CPU
together). The runner toggles BLE itself per step ([FieldStep.bleOn], never
touching the settings switch); repeats interleave the ladder so
battery/thermal drift averages out.
One tap per phone; every condition gets the same window length. Note the
memory this implies: nothing is flushed mid-run (disk I/O inside a
measurement window costs power, and the buffer scales with traffic, so a
periodic write would bias the busiest condition), so a two-rep ladder with
600 s flat-out send segments holds roughly 240k records ~= 44 MB in the
recorder buffer until stop — comfortably within a phone's heap, and ~4.4 MB
gzipped on upload. Run UNPLUGGED at fixed minimum brightness; report deltas
between conditions per device (B−A = discovery standing cost, linked−base =
control-plane standing cost, light−linked = marginal send cost), never
absolute draw (screen-dominated) and never cross-device comparisons. `power_ladder.csv`
does the analysis: one row per (device, condition), repeats pooled, giving
median draw, SEM, and the delta against that condition's baseline with the
delta's own SEM. It drops charging samples and the first 60 s of every
segment (the phones tap seconds apart and a BLE bring-up lands in the head),
labels devices P1/P2 by who sends during `light` rather than by the generic
sender/receiver roles (both phones send, in their own segments), and flags
`resolved` false when a delta is under ~2 SEM — the honest form for an effect
the fuel gauge cannot separate from noise under screen-on load.

The manual Record / Mark / Stop / Upload controls remain for ad-hoc runs.

## Experiment 1 — control plane (static + moving device on a line)

Hard-won in the first field run (`cp-line-1`): phones **on the ground** lose
~20 dB to ground-plane absorption and pin every reading at the sensitivity
floor — put both devices on **stands ~1.5 m high**, screens facing each
other.

**Static + moving mode** (one experimenter):

1. The **static** device stays at the origin on its stand. It does not run
   the plan: just Testbed → **Record** with the same exp id. Its role is to
   receive, ACK, and record its own half of the trace.
2. The **moving** device runs the auto runner with per-step `sendCount`
   (no roster needed with two devices): at each step the runner drops
   sessions, stamps the marker, and sends its messages — the first
   send triggers the cold handshake, so the full
   discovered→connected→session→usable ladder lands inside every step.
   Reverse-direction delivery is measured by the static device's ACKs and
   read receipts arriving back.
3. Walk the sweep: near anchors first (`d=1`, `d=5` — these give the
   path-loss fit its slope), then out to the range edge and back
   (`d=… retreat`) for the hysteresis.
4. The runner stops and uploads by itself; on the static device, Stop +
   Upload manually.

Offline: `rssi` vs marker distance gives the path-loss fit — fit on the
near-anchor steps and treat far-step RSSI as floor-censored (received
samples cluster just above sensitivity regardless of distance). The
per-step `advPerMin`/`advCoverage` columns are the censoring-proof
discovery-visibility metrics (receiver-side; the TX interval is a known
constant — the controller broadcasts below the app, so there is nothing to
measure on the advertiser). Note advertising is suppressed while a link is
up on the legacy controllers, so `advCoverage` speaks for the discovery
phase, not connected steps. First
`discovered`/`connected`/`session`/`usable` timestamps per dwell give the
stage breakdown and establishment probability; per-step delivery ratio
falls out of the deterministic send ids; `drop` events on the retreat give
the hysteresis threshold; `wire` deltas between `connected` and steady
state give control-plane bytes to establish vs. to keep alive per unit time.

## Experiment 3 — multi-hop relay (3 devices)

The mesh claim: a message reaches a peer that is **not** a direct neighbour.

Place **A — B — C** in a line with B in range of both and **C out of A's
range** (verify: on A, C must not appear as a connected peer). B and C press
**Record** with the shared exp id and do nothing else. A runs a pasted plan
whose steps carry `"sendTo": "<C's pubkey prefix>"`, with `resetDtnBuffer`
off — every message addresses C alone, so a delivery can only have crossed B.

Offline (`mesh_paths.csv` + the `=== mesh ===` block in `summary.txt`):
each message's reconstructed path (`sender -> relay -> receiver`; the
relay-to-receiver leg is a sync conveyance — a carrier never writes at the
recipient), the
relay-hop histogram from the receiver's TTL view, per-path latency, and the
duplication factor. `MULTI-HOP deliveries: n/m` is the headline number.

## Experiment 4 — store-carry-forward (the mule, 3 devices)

The DTN claim: a message survives having **no path at all** and is carried.

A and C start far apart with **nothing in between** — sends have nowhere to
go and sit in A's buffer. A runs a pasted plan targeting C's prefix with
`resetDtnBuffer` off: a seed step fires the messages into the void, then a
long hold while you physically walk device **B** (recording, otherwise idle)
from A to C. B buffers the packets near A and delivers them near C.

Offline: `custody` buffer store→convey→end events, `carried: true` on the paths, and
carry→delivery latency (the time the message spent riding B). C's `recv`
records prove arrival without A and C ever being in range of each other.

## Experiment 2 — data plane (diluting clique)

The data-plane load is the *Diluting clique at the line load* preset: the line
sweep's moderate load — 100 messages of 138 B per destination in a 30 s trial
— swept across clique sizes N=2..7, ten trials each, which makes the pair
experiment this sweep's N=2 baseline by construction. The plan is
**role-free**: every phone loads the identical preset and derives its own
radio schedule from its nickname (radio on iff nickname <= N), so the join
order lives in the nickname alone instead of in which entry the operator
picked.

Growth is a join, not a reset. Each clique growth carries a 5 s gap
(`joinGapSec`) between the old N's drain and the new N's first dwell — every
device waits it together, which is when the operator brings the joining
phone's Bluetooth up. Only the test's first trial resets links and sessions;
after that the mesh stays warm, because this measures the data plane of a
standing mesh and establishment is Experiment 1's job. There are no warm-up
steps, so each N's first trial is a join trial and the analysis may treat it
separately.

The *Diluting clique smoke test* preset is the same steps at the same 30 s
dwell with a fifth of the repeats and desk-sized placement/alignment windows
(~13 min) — run it end to end on a fresh build before a field day.

Offline: `load_sweep_delivery.png` and the `N=<n> L=<level> t<rep>` rows of
`steps.csv` give arrival against the rate each node actually originated, per
clique size; latency comes from the `message` records' `appLatencyMs` and
per-link RSSI from the concurrent `rssi` records.

## Notes

- **Location must be ON** on every Android 8.x device and the framework key
  verified: `adb shell settings get secure location_providers_allowed` must
  not be empty — otherwise the scanner is silently blind (UI toggle can lie).
- The rotating-UUID slot boundary (15 min) drops and re-forms links by
  design; keep dwell windows inside a slot or note rotations via the `drop`
  reasons.
- Keep the app foregrounded on all devices; background BLE behaviour differs
  per platform and would confound the measurements.

---

## Session cap (future work — method built, not run)

Sessions are currently retained **without bound**, on purpose. This section is
the prepared method for capping them, not a description of shipped behaviour.

Sessions are keyed by peer identity and survive the link that formed them, so
the table grows with every peer the device has ever handshaked with, and
`trialDecrypt` walks it once per inbound sealed packet. That is affordable
today because the envelope keeps its recipient field: only packets addressed
to us reach the loop, ~1.75% of a core at 50 msg/s on a Nexus 5X. The
remaining exposure is memory, not CPU. Everything below is the method for
capping it when that becomes the binding constraint — or immediately, under
any design that routes transit packets through trial-decrypt.

**The two device constants.** *Crypto bench* on the testbed screen times one
failed AEAD open (`tFailUs`) and one Noise XX handshake (`tHandshakeUs`), and
writes a `bench` record into the experiment. Run it on the slowest phone in
the fleet — a development machine understates it by roughly 10×. Measured:
**Nexus 5X 350 µs per failed open and 84.1 ms per handshake** (so one
handshake costs ~240 failed opens); 2024 arm64 laptop 35 µs and 4.25 ms. The sweep should be flat across session counts;
a rising per-attempt cost means something other than the AEAD dominates and
the linear model below is wrong.

**The re-encounter distribution.** `session_cap()` in `analyze.py` builds each
device's encounter sequence from `link/discovered` sightings, splitting a new
encounter whenever a peer goes unseen for `ENCOUNTER_GAP_S` (60 s). It must
NOT be built from `link/session` records: those fire only when a handshake ran,
i.e. only on a cache miss, which would make the hit rate zero by construction.

From that sequence one pass of LRU stack distance gives the hit rate at *every*
cap at once — when a peer recurs, count the distinct other peers seen since its
last occurrence; LRU with cap N keeps it exactly when that distance is < N.
Verified against a brute-force LRU simulation on cyclic, Zipf and hot-plus-churn
sequences.

**The cost model.**

```
cost(N) = R_miss × min(N, peers) × t_fail        walk the table
        + encounters/s × (1 − hit(N)) × t_hs     re-handshake what was evicted
```

Holding a session is a standing cost; avoiding a handshake is a one-off saving.
They only compare per unit time, which is why `session_cap.csv` reports
`us_per_s` and `cpu_pct` rather than totals.

**The result is coupled to the envelope.** `R_miss` is the rate of inbound
sealed packets that open under no session. Today that is near zero: the
envelope's recipient field rejects other people's traffic on a header compare,
long before the trial-decrypt loop. The first term vanishes, and the cheapest
cap is simply the largest one memory allows. Drop the recipient field and every
transit packet becomes a miss, the first term dominates, and the cap must be
small — which means more evictions, more re-handshakes, and more airtime. That
second-order cost belongs in the recipient-field decision and does not show up
in a straight CPU comparison of the two arms.

A trace with one peer and one pairing (any two-phone run) cannot size anything;
`summary.txt` says so rather than reporting the largest cap as if it were a
finding.

**Power is reported in milliwatts, not milliamps.** The fuel gauge reports
current, but battery voltage sags ~150 mV over a 2 h run, so a constant draw
reads as a steadily rising current and every late condition is biased against
every early one. `power_ladder()` multiplies each sample by its own
`voltageMv`, which removes the drift and makes two phones comparable in
absolute terms rather than only in deltas.

**Battery level.** The two phones do NOT need matching levels — every
condition is compared against that device's own `base`, so the deltas are
within-device. What matters is that neither phone crosses the Android
battery-saver threshold (15–20%) mid-run, because that silently changes CPU
and radio behaviour partway through the ladder. At ~150 mA for ~2.75 h a run
consumes roughly 15% of a typical battery, so start both above 60% and
preferably above 90%. Charging samples are dropped rather than corrected, so
a phone left plugged in produces no data at all for those segments.

**The fuel gauge updates every ~20–30 s, not every 10 s.** Measured directly:
consecutive 10 s samples return byte-identical `currentNowUa`/`voltageMv`
pairs in runs of 2–3. Only 34% of recorded samples are independent readings
(276 → 96 on `bounce-1`, 1976 → 669 on `pw-base-1`). `power_ladder()` drops
consecutive repeats before computing anything; without that the SEM is
understated by 1.7× and deltas read as resolved that the rep-to-rep spread
says are not. Sampling faster would not help — the gauge is the limit.

**Ladder length.** Three presets:

| preset | shape | wall clock | independent readings / condition |
|---|---|---|---|
| full | 8 conditions × 2 reps × 600 s | 2 h 41 m | ~37 |
| short | 8 conditions × 3 reps × 240 s | 1 h 38 m | ~18 |
| minimal | 5 conditions × 3 reps × 240 s | 1 h 01 m | ~18 |

`short` keeps every measurement and moves samples from within-rep to
between-rep, which is where the uncertainty actually lives — the same
condition varied by up to 20 mA between its two reps in an early run, far
more than the within-rep SEM implied. Two reps give a difference; three give
a variance.

`minimal` drops the mirrored conditions (`solo2`, `light2`, `heavy2`). Those
exist so every quantity is measured on *both* devices: in `light`, P1 sends
while P2 receives simultaneously, and `light2` swaps them. Drop them and send
cost is known only for P1, receive cost only for P2, and discovery cost only
for P1 — `solo` leaves P2's radio off, so P2 measures nothing there. Any
within-device comparison of roles is then impossible. Take it only when wall
clock is the binding constraint.

**Location services must be ON, or BLE discovery silently produces nothing.**
On Android 6.0–11 (both Nexus 5X testbed phones are 8.1 / API 27),
`startScan()` succeeds and runs for minutes but never delivers a callback
unless location services are enabled at the *system* level. Granting
`ACCESS_FINE_LOCATION` is not sufficient — the permission only allows the app
to use location once someone turns it on, and the two survive
install/uninstall independently.

The failure is invisible from inside the app: peers advertise normally,
scans start normally, and no peer is ever found. Diagnose it with

    adb -s <serial> shell dumpsys location | grep -A3 "Enabled Providers"

An empty `Enabled Providers:` is the answer. The confirming half is
`dumpsys bluetooth_manager`, which will show LE scans started and running
while nothing arrives. `location_mode 2` (battery saving) satisfies the gate
without powering the GPS radio, which is what a power run wants; note that
`settings get secure location_mode` can return `null` on 8.1 even when the
setting is live, so trust `dumpsys location` over it.

This appeared after an uninstall/reinstall cycle — one more reason to use
`adb install -r`, which also preserves the Ed25519 identity and any
unuploaded recordings.

**New message dirs (ACK timing decomposition, all single-clock):**
`queued` (sealed but not aired: waits in the sender's custody buffer) → `sealed` (carries `packetIds`, the
messageId↔fragment join) → `sent` (`aired` true = on a live link now; false = the packet exists
only in the sender's custody buffer until a sync exchange asks, and
`transport` is meaningful only when `aired` is true; `t` is the dispatch
instant and `acceptedMs` the transport's write-acceptance, so
`acceptedMs - t` is the message's transmit-queue wait and
`deliveredAt - acceptedMs` the wire's own round trip) → recipient `recv`
(now carries `rxAt`/`procMs`) → recipient `ackTx` (ACK created, carries the
ACK's own `packetId`) → sender `ackRx` (ACK arrived, same `packetId`) →
`delivered` (deduplicated: one per messageId, later ACK copies are `dupAck`).
Read receipts mirror this as `receiptTx`/`receiptRx`/`read` (with
`readLatencyMs`). `failed` carries a reason (`preSealEvicted`,
`sealSendFailed`). `custody end` carries a reason (`ack`, `expired`,
`evictedTotal`, `evictedRecipients`) — a `store` with no `end` is no longer
ambiguous. `session` decrypt records carry `t`, `packetId` and
`decryptUs` for exact per-packet joins. `analyze.py` consumes `drop` and
`buf` into `drops.csv`/`buffers.csv` + summary, reads CryptoBench constants
from a `bench` record when present, and surfaces `runner` aborts in
`summary.txt`.

## Discharge runs (real curves, not projections)

The ladder measures a *rate*; the battery-life figures extrapolate it as a
straight line. That extrapolation is sound where it was measured — the
ladder's own 96→66% trajectory is linear to within 2 percentage points, and
its charge counter to 5% — but it runs straight through the bottom knee,
where voltage sags and draw stops being constant. A discharge run measures
that region instead of assuming it. No preset builds one today; what the
recorder still does for it is below.

**The floor is 5%, not 15%.** A discharge measurement on its own would stop
at 15%, where Android's battery saver engages and throttles CPU and radio. A
mesh run has the opposite priority: a phone that stops is a hole in the
topology for every remaining step — one phone leaving at `n=6` cost 26 of 60
steps their claimed mesh size — so a degraded phone limping to the end is
worth more than a clean exit. The cost is explicit: samples below ~15% are
taken under battery saver and are not comparable with the rest of the run.
`ExperimentRecorder.batteryFloorPct` fires once on the first discharging
sample at or below the floor; the field runner treats that as a *successful*
end (settle, stop, upload), stamps a `battery-floor`
marker, and the screen reports the level it stopped at. Charging samples
never trigger it — a phone on a cable is not approaching the floor.

**The buffer is flushed on state of charge, not on a timer.** A discharge run
has no clean stop, and the record buffer is memory-only, so without this the
run that matters most would lose everything. Pacing on SoC
(`flushEverySocDrop`, default 5 points → ~20 small writes across a full
discharge) keeps the write rate tied to the experiment's own progress rather
than to traffic, which is what made periodic flushing a confound in the first
place.

A discharge step's `dwellSec` should outlast any battery, so the run always
ends on state of charge and never on the clock.

## Range: `range.png`

`plot_range()` emits `range.png` for any experiment whose steps carry a
distance (the line sweep). Two stacked panels share the distance axis —
success fractions above, advertisement RSSI below — deliberately NOT one
chart with two y-scales, since a dual axis invites reading a crossing point
between a percentage and a dBm figure that means nothing.

Three series in the top panel, because "established" has three defensible
definitions and they diverge:

| series | criterion |
|---|---|
| Noise session formed | a session exists — the pairing completed |
| Link usable | first end-to-end ACK arrived |
| Message delivery rate | fraction of sent messages delivered |

The dashed marker is the largest distance at which **all three** are still
100%, computed from the data rather than written in, so the figure cannot
drift from the numbers.

Measured on `cp-line-1` (10 trials per distance, cold start each): sessions
formed 10/10 out to 50 m and 9/10 at 60-70 m, while delivery was only
perfect to 30 m and had collapsed to 13% by 70 m. **Establishment outlasts
throughput** — a pair keeps forming a session well past the range where it
can carry traffic, so quoting a single "range" number requires saying which
criterion it uses. Note also that 80-100 m is non-monotonic (2/10 at 80 m,
5/10 at 90 m): all are far past the usable limit, and the difference is
environmental, not a property of distance.

## TIER 2 — mesh scaling (3 → 8 devices)

The mesh-scaling plan runs one step per device count with **every device
sending** — an all-to-all load that grows with the mesh, not one source and
N-1 spectators. No target is set (`sendTo: all`), so each participating
device sends to every peer it knows. No preset builds it: paste the JSON,
labelling the steps `n=<k>`, which is what `mesh_scale.csv` segments on.

Run it on ALL phones at once, each phone knowing its own join order k — from
its nickname where the steps carry `cliqueN`, or from a per-phone `bleOn` in
the pasted plan. Devices 1-3 are present from the start; device k joins at
step `n=k`.

**Devices join by toggling their radio, not by being switched on.** Every
phone runs the identical timeline from t=0 and simply holds `bleOn: false`
until its step arrives. Two reasons this matters: a phone powered on midway
could not run a timeline that began before it, so its labels would be
offset; and because every device stamps its OWN markers on its OWN clock,
per-device segmentation survives the clock skew between phones (14.9 days on
one measured pair) with no cross-device time join anywhere in the analysis.

**Every phone starts on a shared wall-clock instant, not on a synchronized
tap** — which is what solves "tap N phones 50 m apart at once". `manualJoin`
anchors the run to the next `alignSec` boundary at least `placementSec` after
the tap, so taps spread over minutes — phones handed out across a field —
all resolve to the same start, and from there the timeline advances on each
phone's own timers. `placementSec` is the walk-out window: tap every phone at
one spot, carry them to their marks while it counts down, and the first
measured step opens at the anchor. Every screen must show the same "starts
at" instant before anyone walks away; the placement marker's `targetMs` is
the post-hoc proof. Sync the fleet's clocks first
(`tools/sync_phone_clocks.sh`) — a rendezvous instant is only as good as the
clocks computing it.

Under `manualJoin` the operator works the system Bluetooth toggle and `bleOn`
is pure intent: it drives the `joined` marker and the on-screen join prompts
while the app never touches the radio (Android 13+ ignores a programmatic
enable anyway, and the app-level toggle leaves the chip on — flipping
settings-BT is the only real radio silence). `scriptedRadio` hands the radio
back to the runner while keeping the same anchored start, for a desk plan
whose dark window has to open on every phone at once.

**Every N is repeated 10 times before the mesh grows.** One pass per size
gives one sample per point, and the power ladder showed that between-rep
spread — not within-rep scatter — is where the real uncertainty lives. The
analyzer aggregates the reps per N and reports `dup_spread` and
`delivery_min`/`delivery_max` beside the means, so the curve carries its own
error bar.

**Timing:** 60 steps × 120 s (+5 s gap) + 60 s settle = **2 h 5 m**, or 20
minutes per device count. Shorten `dwellSec` if that is too long — 90 s gives
1 h 35 m, 60 s gives 1 h 5 m — but check `degree_median` against the label
before trusting a short dwell: a device joining at `n=8` must discover and
handshake with up to 7 peers, and a step that ends before the mesh converges
measures a partial mesh under a full-mesh label.

**The buffer is written to disk at every step boundary** — between
measurement windows, never inside one — so a run that is killed loses at most
the step in progress. (State-of-charge flushing, which covers hours-long
discharge runs, does nothing here: a 2-hour stepped run barely moves the
battery, so nothing would reach disk until stop.)

**The same plan serves two experiments — only the placement differs**, since
the plan cannot see where the phones are.

**Density (recommended).** Fix source and target out of each other's range;
put every added phone NEAR THE MIDDLE. Every added node rebroadcasts, so this
is where managed flooding either stays bounded by TTL and dedup or does not.
Cheap: everything fits in a small area and one person can run it. The result
is two curves — delivery should hold flat while duplicate traffic climbs.

**Chain / reach.** Place each added phone to EXTEND a line at ~50 m spacing
(the measured distance where a hop still establishes 10/10 — see `range.png`;
30 m hops would put the endpoints only 60 m apart, where they discover each
other 9/10 and bypass the relay entirely). Delivery survives until the hop
count hits `GrassrootsPacket.defaultTtl` = 7, where a packet is dropped at
zero TTL regardless of who is listening. **With 8 devices that ceiling is
exactly reachable** — 7 hops — so the cliff is measurable rather than
inferred. Needs ~350 m of clear ground.

`mesh_scale.csv` per device count:

| column | meaning |
|---|---|
| `delivery_rate` | the reach half — does adding nodes still deliver |
| `dup_per_delivered` | **the cost half** — redundant arrivals per delivered message |
| `relays`, `relays_per_device`, `relaying_devices` | is load spread or concentrated on one node |
| `wire_B_per_delivered` | end-to-end efficiency |
| `hops_median`, `hops_max` | do paths lengthen as density rises |
| `degree_median` | measured degree, to cross-check the `n=` label |

Segments are matched on the plan's `n=<k>` labels, not on `degreeAtEvent`:
the label is what the plan scripted, while degree is a snapshot that moves
as links form and drop mid-step. A large gap between the two means devices
were not actually joining when their step said they would — most likely a
radio that failed to come up, which the dead-radio watchdog also catches —
and the run should be read with that in mind.

The DTN buffer deliberately survives across steps — a packet held while the
mesh was too sparse may deliver once density rises, and clearing between
steps would erase exactly that effect.

## Analysing a multi-GB trace without being OOM-killed

`load_db` builds one pandas DataFrame over the records it loads, so a
saturating multi-hour run (millions of records) will get the process killed
if it loads everything. Both filters are now pushed into SQL rather than
applied in pandas, so unmatched rows are never read:

    python3 analyze.py traces.db --exp discharge-1 --types power,marker

`--types` is the big lever. `message`/`custody`/`session` are routinely 99.5%
of a trace, while a power ladder reads only `power` and `marker` — a
thousandfold reduction. Which types each analysis needs:

| analysis | types |
|---|---|
| power ladder / discharge curve | `power,marker` |
| range (`range.png`), steps | `marker,link,rssi,message,wire` |
| mesh scaling | `marker,message,packetDup,relay,wire` |
| drops, buffers | `marker,drop,buf` |

Omit `--types` to load everything, which is fine for small runs.

### `power_series.csv`

Every other power output aggregates — a median per condition, a delta per
step. A discharge run's whole point is the SHAPE over time: where the knee
is, whether draw holds as voltage sags. `power_series()` emits the samples
themselves (charging excluded, consecutive duplicate gauge readings
collapsed, same rules as `power_ladder` so the two cannot disagree). It is
kilobytes even for a five-hour run, since the gauge only updates every ~30s.

Get it with the same lean invocation:

    python3 analyze.py traces.db --exp discharge-1 --types power,marker

### Staging checklist before a shared field run

In order of what it would cost to discover in the field:

1. **Clocks.** Run `tools/sync_phone_clocks.sh` first. The Android-8.1
   Nexus 5X refuse the direct write and take the NTP fallback; never reboot
   a phone that has `auto_time=0`.
2. **Settings -> Bluetooth toggle ON, on every phone.** The scripted radio
   drives the BLE service, not the settings toggle; with the toggle off the
   service refuses to start and the phone records the entire plan against a
   dark radio without a single error on screen. Check for a `bt-on` marker
   from every phone right after launch.
3. **Wi-Fi OFF on every phone (Internet transport dark).** A send writes
   UDX-direct whenever a live UDX link exists, and the sync exchange answers
   over UDX too — phones sharing a LAN would carry "mesh" traffic over the
   Internet. `transport: udp` on a sent record betrays it post-hoc; the
   checklist prevents it. (Wireless-adb phones that must keep Wi-Fi are the
   wrong phones for a BLE run.)
4. **One preset, nicknames = join order.** Every phone loads the identical
   plan; the nickname (1..N, unique) is the phone's only role. A duplicate
   nickname is undetectable at runtime and poisons two phones' schedules.
5. **Launch every phone inside one alignment window.** All screens must
   show the same "starts at" instant before anyone walks away; a phone that
   missed the window runs a full boundary late with no resync. The
   placement marker's `targetMs` is the post-hoc proof of alignment.
6. **Fresh experiment id.** A reused id is refused by suffixing, which
   splits the fleet's uploads across file names and breaks run discovery.

### A run that looks stuck on `SETTLING 00:00`

It is not stuck — it is wrapping up. The phase only becomes `finished` after
`stopExperiment()` has written the whole buffered run to disk AND the upload
has returned, and a large trace uploads in chunks over minutes. Until then
the phase is still `settling` with the countdown at zero, which is
indistinguishable from wedged.

The screen now shows **WRAPPING UP** with what it is doing (writing to disk /
uploading), and both that screen and the settle countdown carry a **Finish
now** button. It abandons only the WAIT: the recording is already on disk, so
the files stay on the device and can be uploaded or shared from the testbed
screen afterwards. Anything in flight completes in the background and its
result is discarded.
