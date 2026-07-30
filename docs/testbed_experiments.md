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
| `wire` | every 10 s while traffic moved | per-outer-type tx/rx `{bytes,packets}` deltas: `announce`, `handshake`, `secure`, `syncOffer`, `syncRequest` — control plane = everything except `secure` |
| `message` | send / recv / delivered / dup | `messageId`, `peer`, `payloadSize`, `e2eLatencyMs`, `relayHops`, … |
| `flow` | bulk driver start/stop | `flow` (`A>B`), `payloadBytes`, `inFlight`, final `sent`/`acked`/`ackedBytes` |

## Experiment 1 — control plane (two nodes on a line)

1. Both devices: Testbed → **Record** (ids e.g. `cp-line-1-A`, `cp-line-1-B`).
2. Start beyond radio range (~120 m). At each distance step, type the ground
   truth into the marker field — `d=120 approach` — and press **Mark**
   (both devices), then dwell several minutes.
3. Walk the sweep in, step by step, down to 10 m; then reverse (`d=… retreat`)
   to capture the establishment-vs-drop hysteresis.
4. Stop recording, **Share files** from both devices.

Offline: `rssi` vs marker distance gives the path-loss fit; first
`discovered`/`connected`/`session`/`usable` timestamps per dwell give the
stage breakdown and establishment probability; `drop` events on the retreat
give the hysteresis threshold; `wire` deltas between `connected` and steady
state give control-plane bytes to establish vs. to keep alive per unit time.

## Experiment 2 — data plane (dilating triangle)

Same recording ritual (ids e.g. `dp-tri-20m-…`), plus the **Bulk flows**
driver. One JSON, identical on all three devices; each runs only the flows
where it is the source:

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

Per side length: first the single-flow baseline (one pair, as above), then the
contended all-to-all run — same JSON with all six ordered pairs in `flows`.
Load config → **Start** on every device (start order doesn't matter; each
window is `durationMs` from its own Start). Mark the side length before each
run (`side=20 baseline` / `side=20 contended`).

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
