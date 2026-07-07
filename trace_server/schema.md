# Trace upload contract (v1)

This is the agreement between the Grassroots mobile client and the trace server.
The server validates only the **envelope**; record bodies are stored as-is, so
fields can be added/removed on the client without a server change. This document
is the source of truth for what the client emits.

> Status legend for fields below:
> ✅ capturable today · ➕ needs a new counter/hook (cheap) · 🔌 needs a new
> dependency/permission · ⚪ architecturally constant in this direct-delivery
> transport · ❓ blocked on a product decision (see `README.md` → Open decisions).

## Envelope

One HTTP `POST /v1/traces` carries one upload (all not-yet-uploaded records since
the last success). Body is JSON, optionally `Content-Encoding: gzip`.

```jsonc
{
  "schemaVersion": 1,
  "uploadId":   "9f3c…",          // UUID; idempotency key. Required.
  "deviceId":   "h:4a8e…",        // opaque pseudonym (see ID scheme). Required.
  "platform":   "android",        // 'android' | 'ios'
  "appVersion": "1.4.0+57",
  "generatedAt":"2026-06-18T08:01:11Z",
  "consent":    true,             // client asserts opt-in consent was active
  "records": [ /* TraceRecord[] */ ]   // Required.
}
```

## Device & peer IDs (locked: rotating per-upload UUID)

`deviceId` is a **fresh random UUID generated for each upload** (max privacy: a
device is not linkable across uploads or to its on-air identity). It is fixed for
the life of one `uploadId` so retries stay idempotent.

`peer` values are **per-upload aliases**: within a single upload, each distinct
peer public key maps to a stable random alias (e.g. `p0`, `p1`), so node pairs
stay correlatable *within that upload*. They are **not** stable across uploads or
across devices.

> Consequence for analysis: all longitudinal series that need same-identity
> linkage across days (inter-contact time, return time, visit frequency,
> per-pair throughput) are computed **on-device** against the real public key and
> uploaded as already-derived values. The server cannot re-link a device or match
> the two sides of a contact across uploads. (If you later want cross-day
> trajectories server-side, switch to the salted-pseudonym scheme.)

## Record shape

Every record has a `type` and (where it makes sense) an event time `t` in epoch
**milliseconds**. All other keys are type-specific.

### `message` — one record per message event
Covers: *Message timestamp at sending/receiving, End-to-end latency, Message
size, Delivery success, Transport method, Hop count, Delivery method, Message
duplication count.*

Records are **append-only per event** (the client can't mutate a written line),
so one logical message produces several records joined by `messageId`:

```jsonc
// dir=sent (originator, at flood time)
{ "type": "message", "t": 1750233671000, "dir": "sent", "messageId": "uuid",
  "peer": "p0", "transport": "ble", "payloadSize": 184,
  "degreeAtEvent": 3,           // temporal node degree: reachable-peer count now
  "queueDepthAtSend": 0,        // sender-local outbound queue depth (absolute)
  "sentAt": 1750233671000 }

// dir=recv (recipient, first delivery) — the mesh UNLOCKED hops/method
{ "type": "message", "t": 1750233671220, "dir": "recv", "messageId": "uuid",
  "peer": "p0", "transport": "ble", "payloadSize": 184, "receivedAt": 1750233671220,
  "relayHops": 2,               // REAL: defaultTtl - ttl-at-receipt = relays traversed
  "deliveryMethod": "relayed",  // REAL: 'direct' (0 relays) | 'relayed' (mesh flood)
  "degreeAtEvent": 4 }

// dir=delivered (originator, on ACK) — trustworthy round-trip latency
{ "type": "message", "t": 1750233671940, "dir": "delivered", "messageId": "uuid",
  "deliveredAt": 1750233671940, "e2eLatencyMs": 940, "deliverySuccess": true }

// dir=ack_timeout (originator watchdog fired, message re-queued)
{ "type": "message", "t": ..., "dir": "ack_timeout", "messageId": "uuid",
  "deliverySuccess": false }

// dir=dup (recipient saw a duplicate flooded copy of a message addressed to it)
{ "type": "message", "t": ..., "dir": "dup", "messageId": "uuid", "transport": "ble" }
```

The migration to the opportunistic mesh made `relayHops` / `deliveryMethod` /
duplication genuinely vary (in the old direct-delivery design they were constant).
Deferred (not yet emitted): `msgClass`/`blockType` (data-vs-control typing),
`controlBytes` (on-wire overhead ratio), per-message `attempts`.

### `contact` — one per contact session close
Covers: *Inter-contact time, Contact duration, Link throughput, RSSI.*

Emitted on a peer's consolidated-reachability close (a whole session, across
transports — not per BLE leg):

```jsonc
{
  "type": "contact",
  "t": 1750233780000,
  "peer": "p0",                 // per-upload alias
  "startedAt": 1750233600000,   // reachability true (session open)
  "endedAt":   1750233780000,   // reachability false (session close)
  "durationMs": 180000,         // contact duration
  "interContactMs": 540000,     // gap since the previous session with this peer (omitted on first)
  "rssi": -67                   // last RSSI, if known
}
```

Deferred: per-leg detail, who-dialed, and byte counts / throughput (need
per-connection data-stream accounting).

### `density` — periodic "user density" sample
Covers the *User Density* row: *Timestamp | Lat | Lon | Device ID | RSSI |
#Relations Established | Advertisements.*

```jsonc
{
  "type": "density",
  "t": 1750233671000,
  "peersConnectedNow": 3,       // reachable-peer count (temporal node degree)
  "friends": 12,                // current accepted-friend count (proxy for #relations)
  "rssi": -67,                  // mean RSSI of reachable BLE peers (omitted if none)
  "lat": 32.776,                // coarse GPS fix, rounded ~3dp (present only with a fix + permission)
  "lon": 35.023,
  "geocell": "sv8wr"           // geohash-6 (~1 km) cell of the fix
}
```

Deferred: cumulative distinct-peers-ever (`relationsEstablished`) and
advertisement/scan-result counts (need a discovery-event hook).

### `visit` — a stay at a "place"  (locked: background coarse GPS)
Covers: *Return time, Frequency of visits, Visiting time, Coarse geolocation.*
A "place" is a **geo cell** (geohash of the coarse fix). A visit opens when the
device dwells in a cell beyond a threshold and closes when it leaves; return
time and visit count are accumulated on-device against the real geocell history.

```jsonc
{
  "type": "visit",
  "placeId": "sv8wr",           // geocell (geohash prefix)
  "arrivedAt": 1750200000000,
  "leftAt":    1750210800000,
  "visitMs":   10800000,        // Visiting time
  "returnTimeMs": 86400000,     // since the previous visit to this place (null on first visit)
  "visitCount": 5               // Frequency of visits to this place to date
}
```

### `device` — device-constraint sample
Covers: *Battery drain rate, OS throttling flag.* Two emit points:

```jsonc
// periodic sampler (foreground): battery + network
{ "type": "device", "t": 1750233671000,
  "batteryPct": 73,             // battery_plus level
  "batteryDrainPctPerHr": 4.2,  // derived from successive samples (mAh not portable)
  "lifecycleState": "resumed",  // the sampler only runs in the foreground
  "networkType": "wifi" }       // connectivity_plus: wifi|mobile|ethernet|none

// on app resume: how long we were backgrounded
{ "type": "device", "t": ..., "lifecycleState": "resumed",
  "bgDurationMs": 120000,       // time since the app left the foreground
  "osThrottled": true }         // APPROXIMATION: bgDurationMs > 60s (a long gap
                                // suggests OS suspension; true Doze/App-Standby
                                // needs native APIs not in scope)
```

### `buffer` — mesh buffer-occupancy sample
Covers: *Buffer occupancy rate, Buffer drop count.* Sampled by the periodic
timer. Occupancy is reported as absolute counts of the two bounded mesh buffers:

```jsonc
{
  "type": "buffer",
  "t": 1750233671000,
  "event": "sample",
  "outboundQueued": 2,          // sender-local outbound queue depth (un-flooded messages)
  "dtnBuffered": 7              // sealed packets held in the DTN store-carry-forward cache (bounded)
}
```

Deferred: an `event:"drop"` record on DTN/queue eviction, and an `occupancyRate`
(the DTN store cap is the natural denominator).

## Notes for the client implementer

* **Records are append-only**; the client never rewrites a line, so join
  `message` records by `messageId` and pair `visit`/`contact` opens with closes.
* **Foreground sampling only** today — the density/buffer/device sampler is a
  foreground timer; continuous background sampling (esp. for `visit` records) is
  a follow-up that would drive the sampler from the transport foreground service.
* Records are batched and the body **gzipped**; traces compress ~10×.
