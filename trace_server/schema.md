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

### `message` — one per sent or received message
Covers: *Message timestamp at sending/receiving, End-to-end latency, Message
size, Delivery success, Transport method, Message type, Hop count, Delivery
method, Message duplication count, DTN row.*

```jsonc
{
  "type": "message",
  "t": 1750233671000,
  "dir": "sent",                  // 'sent' | 'recv'
  "messageId": "uuid",
  "peer": "h:…",                  // counterpart pseudonym
  "transport": "ble",            // ✅ 'ble' | 'udp'  (the real delivery axis)
  "msgClass": "data",            // ✅ 'data' | 'control'  (data=text/picture, control=friendship/ack/read-receipt)
  "blockType": "text",           // ✅ text|picture|friendshipOffer|friendshipAccept|friendshipRevoke
  "payloadSize": 184,            // ✅ application payload bytes
  "controlBytes": 282,           // ➕ on-wire framing+sig+AEAD overhead for this msg (header 154B/fragment + 64B sig + AEAD)
  "sentAt": 1750233671000,       // ✅ sender wall-clock (dir=sent)
  "receivedAt": 1750233671220,   // ✅ receiver wall-clock (dir=recv); cross-device one-way latency is COARSE (wire ts is whole-seconds, no clock sync)
  "deliveredAt": 1750233671940,  // ✅ ack arrival (dir=sent); same-clock
  "e2eLatencyMs": 940,           // ✅ deliveredAt - sentAt (RELIABLE round-trip; the only trustworthy latency)
  "deliverySuccess": true,       // ✅ ack received before ack-timeout watchdog fired
  "degreeAtEvent": 3,            // ✅ temporal node degree: reachable-peer count at this instant
  "queueDepthAtSend": 0,         // ✅ sender-local outbound queue depth when this was sent (absolute, not a %)
  "attempts": 1,                 // ✅ (re)send attempts for this messageId (ack-timeout / path-drop requeues)
  "dupCount": 0,                 // ➕ duplicate copies of this messageId seen (REAL counter at the dedup point)
  "hopCount": 1,                 // ⚪ always 1 — relaying/multi-hop is architecturally forbidden (direct-delivery is inviolable), so deliberately NOT built
  "deliveryMethod": "direct",    // ⚪ always 'direct' — message payloads are never relayed (only signaling metadata is)
  "dtnHop": 0,                   // ⚪ no store-carry-forward of other peers' traffic
  "dtnTimeStoredMs": 0           // ✅ for dir=sent, time this msg sat in the sender's own outbound queue
}
```

### `contact` — one per contact session close
Covers: *Inter-contact time, Contact duration, Link throughput, RSSI.*

```jsonc
{
  "type": "contact",
  "peer": "h:…",                 // pseudonym once known; else null (pre-ANNOUNCE)
  "transport": "ble",            // ✅ 'ble' | 'udp'
  "leg": "central",              // ✅ 'central'|'peripheral' (BLE); a pair may have two legs
  "isIncoming": false,           // ✅ who dialed
  "startedAt": 1750233600000,    // ➕ synthesized (no connectedAt is stored; tracer captures on open)
  "endedAt":   1750233780000,    // ➕ on close event
  "durationMs": 180000,          // ➕ Contact duration
  "interContactMs": 540000,      // ➕ since previous session with same (peer,transport); tracer-maintained
  "bytesSent": 4096,             // ➕ accumulated from send hooks
  "bytesRecv": 8192,             // ➕ accumulated from dataStream (UDP excludes UDX overhead/retransmits)
  "throughputBps": 553,          // ➕ 8*(bytesSent+bytesRecv)/durationSec
  "rssi": -67                    // ✅ BLE; often null on the peripheral leg
}
```

### `density` — periodic "user density" sample
Covers the *User Density* row: *Timestamp | Lat | Lon | Device ID | RSSI |
#Relations Established | Advertisements.*

```jsonc
{
  "type": "density",
  "t": 1750233671000,
  "lat": 32.7766,                // 🔌 coarse fix from background GPS (geolocator), rounded to cell resolution
  "lon": 35.0233,               // 🔌
  "geocell": "sv8wr",           // 🔌 geohash (coarse zone tag) derived from the fix
  "rssi": -67,                  // ✅ median/last RSSI of currently-connected BLE peers
  "relationsEstablished": 12,   // ➕ cumulative distinct peers ever connected (tracer-accumulated counter)
  "peersConnectedNow": 3,       // ✅ current reachable-peer count
  "advertisements": 47          // ✅/➕ BLE advertisement/scan-result count in the window (needs discovery-event hook)
}
```

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

### `device` — periodic device-constraint sample
Covers: *Battery drain rate, OS throttling flag.*

```jsonc
{
  "type": "device",
  "t": 1750233671000,
  "batteryPct": 73,             // 🔌 needs battery_plus
  "batteryDrainPctPerHr": 4.2,  // 🔌 derived from sampled batteryPct (mAh/hr not portably available — dropped)
  "lifecycleState": "paused",   // ✅ resumed|inactive|paused|hidden|detached (WidgetsBindingObserver)
  "osThrottled": true,          // ⚪ APPROXIMATION: "left foreground" (paused/hidden), NOT true Doze/standby (no native API in scope)
  "bgDurationMs": 120000,       // ✅ time since app left foreground
  "networkType": "wifi"         // ✅ connectivity_plus (already wired): wifi|mobile|none|…
}
```

### `buffer` — sender-local outbound-queue sample / drop event
Covers: *Buffer occupancy rate, Buffer drop count.* (locked: build the machinery)
A bounded outbound queue is introduced (cap + eviction). Occupancy is sampled on
enqueue/drain; a record with `event:"drop"` is emitted whenever a message is
evicted before delivery.

```jsonc
{
  "type": "buffer",
  "t": 1750233671000,
  "event": "sample",            // 'sample' | 'drop'
  "depth": 7,                    // ➕ messages currently queued
  "capacity": 64,                // ➕ configured queue cap (the new denominator)
  "occupancyRate": 0.109,        // ➕ depth / capacity
  "dropCountCumulative": 3       // ➕ total messages dropped due to exhaustion since launch (event='drop' increments it)
}
```

## Notes for the client implementer

* **Control overhead** (the field) = aggregate `controlBytes` / aggregate
  `payloadSize`; computed server-side or in analysis from `message` records, not
  uploaded as a separate field.
* Records should be batched and the body **gzipped**; traces compress ~10×.
