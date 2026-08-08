# Grassroots trace server

A small FastAPI service that collects **testbed experiment recordings** from
the Grassroots Networking mobile app. The app records experiment traces
locally (`exp_<id>.jsonl`, see `docs/testbed_experiments.md`); the
experimenter uploads them with the manual "Upload files" action on the
testbed screen — one envelope per experiment file, `deviceId` = the device's
pubkey hex, `experiment` = the file name. There is no automatic or
consent-prompted upload path.

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
| `TRACE_ZIP_BOMB_RATIO` | `200` | Max gzip expansion ratio. NOT a size cap — real traces expand ~10x, so this only rejects decompression bombs. |
| `HOST` / `PORT` | `0.0.0.0` / `8443` | Bind address. |

## Upload size

**There is no upload size limit.** An experiment must never be shaped around
the collector, and a run that took hours to produce must never be refused for
being large — that trade is always the wrong way round.

The only thing enforced is a decompression *ratio*, which is a different
thing: it rejects a body whose gzip expands past `TRACE_ZIP_BOMB_RATIO`,
an attack signature rather than a big experiment. Legitimate traces compress
about 10x, nowhere near the bound, so an upload of any size passes.

The cost is that this process reads, gunzips and parses each body whole, so a
request needs several times its decompressed size in RAM. The client keeps
requests small by streaming its file and POSTing in bounded chunks — the
right place to solve it, since the sender should not have to know the
collector's memory to pick a chunk size, and the collector should accept
whatever it is sent.

## Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `GET`  | `/v1/health` | none | Liveness + schema version. |
| `POST` | `/v1/traces` | Bearer | Upload a batch. `201` stored / `200` duplicate. |
| `GET`  | `/v1/stats`  | Bearer | Upload/record counts per type. |
| `GET`  | `/` | none | Redirects to the viewer. |
| `GET`  | `/dashboard` | none | Mesh topology viewer (carries no data itself). |
| `GET`  | `/v1/experiments` | Bearer | One row per experiment, for the viewer's picker. |
| `GET`  | `/v1/topology?exp=` | Bearer | `link` + `marker` records for one experiment. |

## Mesh topology viewer

Open the server's host in a browser -- phone included -- and it lands on
`/dashboard`. Pick an experiment and it reconstructs, for every moment of the
run, which phones held a BLE link to which, and checks the mesh size that was
actually up against the size each step claimed.

Reads:

- **the join order** stamped into every step marker, which is how a recording
  says which phone wrote it (nothing else in the file does);
- **`joined`** on the same marker -- whether that phone meant to have its radio
  up for that step;
- **`link` connected/drop** events, whose MAC paths are resolved to peer
  pubkeys, then to join orders by elimination: the one key absent from a
  phone's own peer set but present in another's is its own;
- **`battery-floor`**, so a phone that stopped itself on the floor is drawn as
  that rather than inferred from a recording that just ends.

The page is served without auth because it holds no data. The endpoints it
calls do check the token, which the page keeps in `localStorage` after one
prompt -- not in a URL. With `ALLOW_NO_AUTH=1` there is no prompt at all.

`/v1/experiments` groups over `uploads` rather than `records`: the same query
against `records` is a full scan and measured ~115 s on a 14 GB database, versus
0.12 s here. `/v1/topology` returns only the two record types the view needs --
810 KB for a 19.3 M-record run.

A run that has not been uploaded yet can still be inspected: the picker has a
"load recordings from disk" fallback that parses the JSONL in the browser.

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
