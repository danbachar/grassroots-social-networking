# BLE link throughput on two Nexus 5X — implementation handover

You are implementing and then running a two-phone desk experiment that
measures how many bytes per second one warm BLE link between two Nexus 5X
actually carries through this app's protocol stack. Read `CLAUDE.md` at the
repo root first; its rules (no legacy shims, Redux-only state, no
compatibility decoders) bind everything you write. Dan asked for this on
2026-09-06; the design below is settled with him — do not relitigate it.

## Why this experiment exists

The thesis's simulation (grassroots-simulations, `REACH-EXPERIMENT.md`)
takes its BLE link rate from `BluetoothInterface.java`: the measured
path-loss fit `RSSI(d) = -43.5 - 18.8 log10(d)` is turned into an SNR
against an ASSUMED noise floor (-85 dBm, the code says "TODO: measure
this") and scaled by Shannon capacity to the 1 Mbit/s PHY. That gives 125
kB/s per link at 1 m, 42 kB/s at 30 m, 30 kB/s at 50 m. Nothing in the
thesis dataset measures a saturated link: every line-sweep step ran at the
offered 1 kB/s and delivered all of it, and the diluting clique at N=7
carried about 4.5 kB/s in aggregate where the model would allow tens. The
model is therefore optimistic about BLE capacity by an unknown factor, in
the direction that flatters flooding. This experiment measures the ceiling
the model is missing, so the thesis can either state the gap with a number
or the simulator can take the measured ceiling as one constant.

The app once had exactly this instrument — commit `4d19173` ("throughput:
one-packet default, payload arm, concurrent senders, bounds") — and it was
deleted from the app later (`198cfad` dropped its docs). Restore it from that
commit; do not reinvent it. The analyzer still understands its markers and
records: `p=<n>B` and `lanes=<n>` labels segment steps (`MARKER_PAYLOAD_RE`,
`MARKER_LANES_RE` in `trace_server/analyze.py`), `saturate-start` is a
control marker, and `summary.txt` reads `flow` records with
`sent`/`acked`/`ackedBytes`.

## Design (settled with Dan — do not relitigate)

**Two phones, desk, one direction.** Sender S and receiver R are two of the
connected Nexus 5X (`00d98aa1795bc454`, `00de4b24f89021e4`,
`00f8380a3668adb1` are attached; use two of them, leave the Pixel 2 out).
About one metre apart, line of sight, chargers on. This measures the
stack-limited ceiling at strong signal, which is the number the calculator's
PHY cap stands in for. Distance dependence stays with the model's Shannon
shape; an attenuated point is optional (below).

**Warm links and sessions; nothing is reset between steps except the DTN
buffer.** `resetSessions: false`, `resetLinks: false` at plan level, exactly
as `throughput()` had them in `4d19173`. Set `resetDtnBuffer: true` on every
step: a write refused or timed out in one step otherwise sits in the buffer
and is conveyed by the next sync round inside the following step, and counts
there. Clearing the buffer touches neither links nor sessions
(`FieldStep.resetDtnBuffer` doc).

**Saturating, closed-loop, never ACK-gated.** A step with `saturate: true`
ignores `sendCount` and runs `sendLanes` lanes, each looping "fire one, await
it, fire the next" (`_pushLane`/`_fireSaturating` in `4d19173`). The await is
now a real write completion, verified 2026-09-06 along the whole path:
`GrassrootsNetwork.send` awaits `_fragmentHandler.send`, which awaits
`MessageRouter.dispatchOutbound` → `directSend` → `ble.sendToPeer` →
`_writeLeg`, which awaits the plugin's write acknowledgement under
`_writeAckTimeout`; the plugin holds ONE GATT op in flight per path
(`ble_transport_service.dart` ~1735). So with one lane the loop runs at
exactly the rate the pipe drains. An ACK only counts (`onAck`); it never
clocks a send — clocking on ACKs caps the rate at `lanes / RTT` and measures
the window instead of the link.

**Which pipe is measured.** Data rides the pair's notify leg by default
(`_bleDataLegFor` → `getPeerIdForPubkey`; commit `8736876`), written
`withoutResponse`. A second lane's write meets the plugin's single op slot,
is refused `write-busy`, and is retried on the pair's other leg
(`otherLegFor`, the central `withResponse` leg). Two lanes therefore ask
whether a converged pair's two legs are two usable pipes. Do NOT run more
lanes than two: with one op slot per path, lanes 4/16/64 only manufacture
`writeBusy` drops. The old ceiling sweep is obsolete under the current
plugin.

**Arms.** Payload 138 B is one sealed packet (`FragmentHandler.fragmentThreshold`
= 247 − 3 − 106); anything larger is fragmented and paced by
`FragmentHandler.fragmentDelay` = 20 ms between fragments, which bounds a
fragmented message to about 247 B per 20 ms on the air regardless of the
radio. That is why the primary arm is single-packet.

| arm | label | payload | lanes | what it measures |
|---|---|---|---|---|
| A (primary) | `p=138B lanes=1 tK` | 138 B | 1 | the pipe: carried bytes/s of one leg, no pacing |
| B | `p=138B lanes=2 tK` | 138 B | 2 | whether the second leg adds capacity or only `writeBusy` |
| C | `p=1380B lanes=1 tK` | 1380 B (10 fragments) | 1 | what a real multi-packet message costs, pacing included |
| D | `p=138B lanes=1 prio=high tK` | 138 B | 1 | arm A with `CONNECTION_PRIORITY_HIGH` on both phones |

Five trials per arm, 60 s dwell, 30 s drain (`settleSec: 30` /
`gapAfterSec` as the old builder had). A, B and C run in one launch as five
interleaved randomised sweeps (each sweep visits A, B, C once in a random
order, seed logged), so thermal drift is spread across arms, not confounded
with them — the same reason the ring sweep interleaves. D is a second launch,
because connection priority is applied to the fleet at launch and moving it
mid-plan would blur the boundary. Budget: 15 steps ≈ 23 min, then 5 steps ≈
8 min. Under 35 minutes total.

**Optional arm E (only if the first two launches were clean):** arm A with
the phones far enough apart or shielded to read about −70 dBm on
advertisement RSSI (another room, a drawer), 5 trials, label
`p=138B lanes=1 att tK`. One check point on the model's distance shape. Not
required for the thesis.

## Verified facts (2026-09-06; do not re-derive, do check the line numbers)

- `GrassrootsNetwork.send(recipient, payload, {messageId})` returns after
  every fragment's write completed, was refused, or timed out
  (`grassroots_network.dart` ~1473–1660; the router's `directSend` at ~4028).
- `_writeLeg` outcomes: `null` (landed), `'writeBusy'` (plugin slot taken;
  never counts toward the failing-leg streak), `'writeTimeout'` (no
  other-leg retry), other refusals (retried on the other leg, count toward
  the streak). Each is a `drop` record with `reason` and `error`.
- The plugin holds one GATT op per path and no longer queues writes
  (plugin commit `690f770`). The "megabytes still draining after the dwell"
  hazard the 2026-07 write-up describes came from the old unbounded queue and
  no longer applies; what survives a dwell now is the DTN buffer, hence
  `resetDtnBuffer: true` per step and send-windowed attribution.
- Connection priority: `GrassrootsNetwork.setConnectionPriorityForTestbed(high)`
  → `BleTransportService.setConnectionPriority` → plugin
  `requestConnectionPriority(HIGH|BALANCED)` on every central path, existing
  links included. Android lets only the central request it, and each phone
  is central on one leg, so BOTH phones must set it. Today it is a UI switch
  (`main.dart` ~2589); the plan needs a field.
- Rosterless two-device default: a step's sends target every known peer
  (`FieldPlan` doc), so the receiver must load a plan whose steps send
  nothing; the sender's plan carries the saturating steps. Same `expId`, same
  labels and dwells, so the markers line up on the server.
- Trace records available without new code: `message` (`sent`/`sealed` with
  `fragments`, `recv`, `delivered`/ACK with `latencyMs` and `appLatencyMs`),
  `drop` (with `reason`/`error`), `wire` (`txBytes`/`rxBytes` per packet
  class; testbed payloads carry `testbedPayloadMarker` 0xFF as byte 0 so they
  are classed apart from real blocks), `rssi` (`adv`/`conn`), `link`
  (`mtu` on the identified stage, read by the analyzer at ~3846). Check the
  `wire` record cadence in the smoke run: per-step sums need several records
  per 60 s dwell.
- `FieldStep.fromJson` rejects unknown keys (`_rejectUnknownKeys`), so every
  new field goes into the allow-list and `toJson`.

## What to build

1. **Restore the saturating step** from `4d19173`: `FieldStep.saturate`,
   `FieldStep.sendLanes` (JSON, equality, allow-list); runner
   `_scheduleSaturating`, `_pushLane`, `_fireSaturating`, the ACK counter
   (`onAck`, `_outstanding`, `_ackedCount`) and the `flow` record at dwell
   end. Two changes to the old code: log a `flow` record with
   `event: 'start'` when the lanes begin (the analyzer measures the window
   from `start` to `stop`, `analyze.py` ~2343; the old code only stamped the
   `saturate-start` marker), and keep the zero-duration `Future.delayed`
   yield in `_pushLane` — it is what keeps the dwell countdown alive.
   Wire the ACK feed from the coordinator's delivered callback if the
   current runner no longer receives it (`_sentCount` survived; `onAck` did
   not).
2. **Plan-level `connectionPriorityHigh: bool?`** applied at launch through
   `setConnectionPriorityForTestbed` on every phone that loads the plan
   (null = leave as is). Put `prio=high` in the step labels of that plan so
   `steps.csv` carries it; the marker regexes ignore tokens they do not know.
3. **Presets**, in `field_plan_presets.dart` and the `presets` map:
   `bleThroughputSender()` (arms A/B/C interleaved as above, `expId`
   `ble-tp-1`), `bleThroughputReceiver()` (same labels and timing,
   `sendCount: 0`, no saturate), and the `prio=high` pair (`ble-tp-hi-1`).
   Randomised sweep order seeded and logged as in `ringSweep()`.
4. **Analyzer**: one added column in `steps.csv`, `air_Bps` = total sealed
   bytes both devices put on the air in the step divided by `active_s`
   (the pieces exist at ~942–1078); and a `prio` segment variable parsed
   from the label. Nothing else — `goodput_Bps`, `airB_per_msg`,
   `air_overhead`, `msg_per_s`, `rtt_median_ms`, `arrival_rate`,
   `delivery_rate`, `rssi_adv_mean`, `rssi_conn_mean` are already there.
5. **Tests**: restore and adapt the runner and preset tests from `4d19173`
   (`test/testbed_field_runner_test.dart`, `test/testbed_field_plan_presets_test.dart`):
   one lane fires again only after the awaited send resolves; two lanes hold
   two sends outstanding; the `flow` start/stop pair is logged; the receiver
   preset sends nothing; the priority field round-trips through JSON.
6. **Smoke run** on the two Nexus: one sweep of A only, 20 s dwells. Confirm
   `steps.csv` segments `p=138B lanes=1 t1`, `flow` start/stop appear,
   `delivery_rate` is 1.0 at one lane, and the `wire` records give a per-step
   sum. Then the real run.

## Analysis and deliverables

Report per arm (median and range over the five trials), send-windowed:

- `air_Bps` at the receiver and at the sender, and `goodput_Bps` (ACKed
  payload bytes/s). The receiver-side `air_Bps` of arm A is **C_link**, the
  number the simulator needs: sealed bytes per second one leg carries at
  strong signal.
- `msg_per_s`, `rtt_median_ms`, `arrival_rate`, `delivery_rate`.
- Drop counts per step by `reason`/`error` (`writeBusy`, `writeTimeout`,
  `writeFailed` causes). Arm A must show delivery at or near 1.0; if one lane
  overruns the pipe, stop and say so before running anything else.
- Advertisement RSSI mean per step (the comparable measure; connection RSSI
  is not comparable across legs) and the negotiated ATT MTU per leg.
- Arm B against A: about double means two pipes; about equal with
  `writeBusy` drops means one.
- Arm D against A: the connection-interval lever, as a ratio.

Hand SIMULATION (rssi-link-establishment session) C_link with RSSI and MTU,
and the A/B/C/D table. In the calculator, C_link × 8 replaces the 1 Mbit/s
`BLE_PHY_CAP` as the ceiling the Shannon shape is scaled to; whether the
grid is then re-run is Dan's decision. Hand THESIS the same table for the
limitation sentence in §5.5 and, if Dan wants it, a five-row appendix table.

## Known hazards

- **The DTN buffer conveys leftovers.** Refused and timed-out packets are
  buffered and leave on the 10 s sync cadence, possibly in the next step.
  `resetDtnBuffer: true` per step, 30 s drain, and window the SEND and count
  the receive wherever it lands (`_clique_sent_ids` convention).
- **Fragment pacing is a constant, not the radio.** Arm C's ceiling is
  `fragmentDelay`; say so in the report rather than reading it as capacity.
- **One op slot per path.** Lanes beyond two measure refusals, not the link.
- **Write timeouts.** `_writeAckTimeout` bounds a write the stack never
  answers; a timed-out write is not a refusal and gets no other-leg retry.
  Count them separately; a run of them is a dying leg, one is a collision.
- **Thermal.** The Nexus 5X drain 18–25 %/h and reach 48 °C in long runs;
  this run is short, but chargers stay on and the interleaving is what
  protects the arm comparison.
- **Nexus `00d98aa1` is the known reset-cost outlier.** Irrelevant here (no
  resets), but make it the receiver, not the sender.
- **Clocks.** RTT is sender-side (send → ACK), so the 8.1 phones' refusal of
  `tools/sync_phone_clocks.sh` does not matter for this experiment.

## Fleet and logistics (Dan's standing rules)

- The two Nexus must be free: do not run while a ring session is using them.
- One agent per phone when driving the testbed; never a single serial loop.
- Chargers on. Commit locally on a branch; never push and never launch the
  real run without Dan's explicit go. Scope ends at: code + tests + presets +
  the smoke run + the two real launches + the report.

## Deliverables checklist

- [ ] `saturate`/`sendLanes` restored, `connectionPriorityHigh` added, tests green
- [ ] Sender/receiver presets for `ble-tp-1` and `ble-tp-hi-1`, randomised sweeps logged
- [ ] `analyze.py`: `air_Bps` column, `prio` segment variable
- [ ] Smoke run: segments parse, `flow` start/stop present, one lane delivers 1.0
- [ ] Real runs A/B/C then D; optional E
- [ ] Report: the arm table, C_link with RSSI and MTU, drop causes, what surprised you
