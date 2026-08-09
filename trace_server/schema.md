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

Records are opaque to the server: it stores each one verbatim and indexes only
`type` and `t`. The catalogue of record types the app emits — `marker`, `rssi`,
`link`, `wire`, `message`, `packetDup`, `relay`, `custody`, `power`, `flow` —
and their fields live with the experiments that produce them, in
[`docs/testbed_experiments.md`](../docs/testbed_experiments.md). That is the
single source of truth; duplicating it here is what let this file drift a
whole subsystem out of date (it previously documented `contact`, `density`,
`visit`, `device` and `buffer` records, none of which the app has emitted since
the consent-based telemetry was deleted).

The only shape the SERVER depends on:

```jsonc
{ "type": "<string>",   // required, indexed
  "t":    1750233671000 // required, epoch ms, indexed
  /* everything else is free-form and stored as-is */ }
```

## Notes for the client implementer

* **Records are append-only**; the client never rewrites a line, so join
  `message` records by `messageId` and pair `visit`/`contact` opens with closes.
* **Foreground sampling only** today — the density/buffer/device sampler is a
  foreground timer; continuous background sampling (esp. for `visit` records) is
  a follow-up that would drive the sampler from the transport foreground service.
* Records are batched and the body **gzipped**; traces compress ~10×.
