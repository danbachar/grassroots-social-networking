# Grassroots trace server

A small FastAPI service that accepts **opt-in** trace uploads from the Grassroots
Networking mobile app. The app collects a set of mobility / messaging / device
metrics locally and, on the first open of each day, asks the user to upload all
not-yet-uploaded data here.

* One `POST /v1/traces` = one upload (an envelope + a batch of records).
* Uploads are **idempotent** (keyed by `uploadId`) — safe to retry.
* Storage is two-tier: a lossless NDJSON archive plus a SQLite index.
* The upload contract is documented in [`schema.md`](schema.md).

## Run

```bash
cd trace_server
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

export TRACE_UPLOAD_TOKEN=$(openssl rand -hex 32)   # share this with the app
uvicorn server:app --host 0.0.0.0 --port 8443
```

For local development without a token: `ALLOW_NO_AUTH=1 uvicorn server:app ...`.

**Always terminate TLS in production** (uploads carry location/behavioral data).
Either run behind nginx/caddy, or pass `--ssl-keyfile`/`--ssl-certfile` to
uvicorn.

### Configuration (environment)

| Var | Default | Meaning |
|-----|---------|---------|
| `TRACE_UPLOAD_TOKEN` | — | Shared bearer token. Required unless `ALLOW_NO_AUTH=1`. |
| `TRACE_DATA_DIR` | `./data` | Where the archive + SQLite DB live. |
| `TRACE_MAX_BODY_BYTES` | `16777216` | Max (compressed) request body. |
| `TRACE_MAX_RECORDS` | `200000` | Max records per upload. |
| `HOST` / `PORT` | `0.0.0.0` / `8443` | Bind address. |

## Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `GET`  | `/v1/health` | none | Liveness + schema version. |
| `POST` | `/v1/traces` | Bearer | Upload a batch. `201` stored / `200` duplicate. |
| `GET`  | `/v1/stats`  | Bearer | Upload/record counts per type. |

### Example

```bash
TOKEN=...   # the TRACE_UPLOAD_TOKEN value

# plain JSON
curl -sS -X POST http://localhost:8443/v1/traces \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary @sample_upload.json

# gzipped (what the app does)
gzip -c sample_upload.json | curl -sS -X POST http://localhost:8443/v1/traces \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Content-Encoding: gzip" \
  --data-binary @-

curl -sS http://localhost:8443/v1/stats -H "Authorization: Bearer $TOKEN"
```

Interactive API docs at `http://localhost:8443/docs`.

## Storage layout

```
data/
  uploads/2026-06-18.ndjson   # lossless archive, one line per upload (verbatim envelope + receipt metadata)
  traces.db                   # SQLite: uploads + records tables, indexed by device/type/time
```

Query example:

```bash
sqlite3 data/traces.db \
  "SELECT type, COUNT(*) FROM records GROUP BY type;"
sqlite3 data/traces.db \
  "SELECT json_extract(body,'$.e2eLatencyMs') FROM records
   WHERE type='message' AND json_extract(body,'$.dir')='sent';"
```

## Docker

```bash
docker build -t grassroots-trace-server .
docker run -p 8443:8443 \
  -e TRACE_UPLOAD_TOKEN=$TRACE_UPLOAD_TOKEN \
  -v "$PWD/data:/app/data" \
  grassroots-trace-server
```

## Decisions (locked)

The server accepts everything in `schema.md` regardless; these decisions govern
what the **client** collects:

1. **Geolocation → background coarse GPS.** Add `geolocator` + background-location
   permissions (Android `ACCESS_COARSE_LOCATION` + `ACCESS_BACKGROUND_LOCATION`;
   iOS `NSLocationWhenInUse`/`Always` + `UIBackgroundModes: location`). Populates
   `density.lat/lon/geocell` and the `visit` record type.
2. **Constant fields → build the machinery (within direct-delivery limits).**
   Introduce a *bounded* outbound queue → real `buffer` occupancy + drop records,
   and a real per-`messageId` `dupCount`. `hopCount`/`deliveryMethod`/`dtnHop`
   remain logged constants — relaying/multi-hop is **not** built (it would violate
   the inviolable direct-delivery principle).
3. **Device-ID → rotating per-upload UUID.** Fresh random `deviceId` per upload;
   `peer` values are per-upload aliases. Longitudinal series are computed
   on-device (see `schema.md` → Device & peer IDs).
4. **Upload network → any network.** Upload over any connection once the user
   accepts the daily prompt.

Auth uses a single shared bearer token; switch to per-device keys if a study
needs to attribute or revoke individual devices.
