# Testbed experiment kit

Instrumentation and drivers for the two physical-layer baseline experiments in
the evaluation chapter: **control plane** (RSSI & link establishment on a
line) and **data plane** (throughput of a dilating clique). Everything lives
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
| `message` | send / recv / delivered / dup | `messageId`, `peer`, `payloadSize`, `e2eLatencyMs`, `relayHops`, … |
| `flow` | bulk driver start/stop | `flow` (`A>B`), `payloadBytes`, `inFlight`, final `sent`/`acked`/`ackedBytes` |

## Auto runner (scripted, hands-free)

Instead of driving the markers/dwell/upload by hand, load a **plan** and let
the app run it. Testbed → **Auto runner**: pick a **preset** from the
dropdown (Home soak / Line sweep / Data-plane clique), run the **Wizard** to
build one from a few answers, or paste JSON directly — then **Launch**. The
full-screen runner then, per step: shows the target label, waits for your
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
NTP-synced). The wizard's "This device moves during the test" switch picks
which side you are configuring. Bulk steps run the flow driver during the
dwell. After the last step the runner stamps `end`, settles, stops recording,
and uploads — no further taps. (On 3+ devices load the same JSON on each; two
devices need nothing shared — plans are rosterless.)

```json
{
  "expId": "cp-line-2",
  "settleSec": 30,
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
to come back), drops all Noise sessions (`resetSessions`, so the
establishment ladder re-runs from a cold handshake every step), stamps the
marker, and — when `sendCount` > 0 — sends that many `sendBytes`-sized
messages (default 184). Sends are **gated on the link being settled**
(authenticated session + converged dual-leg pair; a `link-settled` marker
stamps the moment) and then spread across the remaining dwell — data never
races a re-forming link, and a step where no peer settles sends nothing
(the correct zero at an out-of-range distance). Sessionless peers
re-handshake eagerly on ANNOUNCE from either side, so settling needs no
data-send trigger. Targets: with **no
`roster`** (the two-device default) every identified peer, labeled by 8-hex
pubkey prefix — no manual pubkey entry; with a `roster`, every other roster
row (roster labels name the ids), and a device not in the roster sends
nothing — that's the static receiver on 3+ device campaigns. Ids are the
reproducible UUIDv5 set `field|expId|src|dst|step|seq`, so the offered
count is computable offline.

**Throughput (saturate).** A step with `"saturate": true` ignores `sendCount`
and instead keeps `inFlight` messages outstanding for the whole dwell, firing
the next the moment one is ACKed — as many messages as the link carries, no
pacing and no cap. Wizard: *Throughput (saturate)* (60s dwell, 184-byte
messages, 8 in flight by default; sessions and links stay warm). The step
stamps `saturate-start` and, at dwell end, a `flow` record with
sent/acked/ackedBytes — messages/sec and goodput come straight from it, and
RTT under saturation from the usual `message` records.

For the data-plane sweep, set `"bulk": true` on the steps that should run the
loaded bulk-flow config during their dwell (load that config in the Bulk
flows section first). The manual Record / Mark / Stop / Upload controls
remain for ad-hoc runs.

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
**Record** with the shared exp id and do nothing else. A runs the wizard's
*Mesh: multi-hop relay*, with **C's pubkey prefix** as the target — every
message addresses C alone, so a delivery can only have crossed B.

Offline (`mesh_paths.csv` + the `=== mesh ===` block in `summary.txt`):
each message's reconstructed path (`sender -> relay -> receiver`), the
relay-hop histogram from the receiver's TTL view, per-path latency, and the
duplication factor. `MULTI-HOP deliveries: n/m` is the headline number.

## Experiment 4 — store-carry-forward (the mule, 3 devices)

The DTN claim: a message survives having **no path at all** and is carried.

A and C start far apart with **nothing in between** — sends have nowhere to
go and enter custody. A runs *Mesh: store-carry-forward* (target = C's
prefix): a seed step fires the messages into the void, then a long hold
while you physically walk device **B** (recording, otherwise idle) from A to
C. B picks the packets up in custody near A and delivers them near C.

Offline: `custody` store→convey→end events, `carried: true` on the paths, and
carry→delivery latency (the time the message spent riding B). C's `recv`
records prove arrival without A and C ever being in range of each other.

## Experiment 2 — data plane (dilating triangle)

Load the **Bulk flows** config first (identical on all three devices; each
executes only the flows where it is the source):

```json
{
  "roster": [
    {"label": "A", "pubkeyHex": "<dev-A>"},
    {"label": "B", "pubkeyHex": "<dev-B>"},
    {"label": "C", "pubkeyHex": "<dev-C>"}
  ],
  "flows": [{"src": "A", "dst": "B"}],
  "payloadBytes": 16384,
  "durationMs": 120000,
  "inFlight": 2
}
```

Then run a plan whose steps are the side lengths, with `"bulk": true` so
each dwell runs the loaded flows (dwell a little longer than `durationMs`):

```json
{
  "expId": "dp-tri-baseline",
  "resetSessions": false,
  "steps": [
    {"label": "side=10", "dwellSec": 150, "bulk": true},
    {"label": "side=20", "dwellSec": 150, "bulk": true},
    {"label": "side=40", "dwellSec": 150, "bulk": true}
  ]
}
```

Two runs per campaign: the single-flow **baseline** (one pair in `flows`),
then the contended **all-to-all** (all six ordered pairs) — same plan, new
exp id, reload the bulk config in between. `resetSessions: false` here:
throughput wants warm sessions; establishment is Experiment 1's job.

The driver keeps `inFlight` messages outstanding per flow and sends the next
only on an end-to-end ACK — it **never re-sends**; a lost message just leaves
the window (visible offline as a missing/late ACK). Goodput = acked bytes per
window from the `message` records (deterministic UUIDv5 ids,
`bulk|src|dst|seq`, reproducible offline); latency from `e2eLatencyMs`;
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
