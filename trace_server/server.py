#!/usr/bin/env python3
"""
Grassroots trace-upload server.

Accepts opt-in trace data uploaded by the Grassroots Networking mobile app.
One POST /v1/traces == one *upload*: an envelope describing the device plus a
batch of trace records accumulated since the device's last successful upload
(the app prompts the user to upload, at most once per day, on first open).

Design goals
------------
* **Idempotent.** Uploads are keyed by `uploadId`; a client that retries after a
  flaky connection never double-counts. Re-sending the same `uploadId` is a
  no-op that returns 200.
* **Lossless + queryable.** Every accepted upload is appended verbatim to a
  newline-delimited JSON archive (nothing is ever mutated or dropped), AND each
  record is indexed into SQLite with a few indexed columns (device, type,
  timestamp) plus the full record JSON, so researchers can `SELECT` without
  re-parsing the archive.
* **Schema-tolerant.** The set of record `type`s the client sends is still being
  finalized (it depends on product decisions about geolocation, anonymization,
  etc.). The server validates only the *envelope*; record bodies are stored
  as-is. Adding/removing fields on the client needs no server change.
* **Privacy-respecting.** The server never requires a real identity. `deviceId`
  is an opaque string (a salted pseudonym, in the recommended client config).

Auth
----
A single shared bearer token (env `TRACE_UPLOAD_TOKEN`). This is deliberately
simple; swap for per-device keys or mTLS at the reverse proxy if a study needs
stronger guarantees. The server refuses to start without a token unless
`ALLOW_NO_AUTH=1` is set (local development only).

Run
---
    pip install -r requirements.txt
    export TRACE_UPLOAD_TOKEN=$(openssl rand -hex 32)
    uvicorn server:app --host 0.0.0.0 --port 8443

Behind TLS (recommended) terminate HTTPS at a reverse proxy (nginx/caddy) or run
uvicorn with --ssl-keyfile/--ssl-certfile.
"""
from __future__ import annotations

import gzip
import hmac
import json
import os
import sqlite3
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, Field

# --------------------------------------------------------------------------- #
# Configuration (all via environment)
# --------------------------------------------------------------------------- #
DATA_DIR = Path(os.environ.get("TRACE_DATA_DIR", "./data")).resolve()
AUTH_TOKEN = os.environ.get("TRACE_UPLOAD_TOKEN", "")
ALLOW_NO_AUTH = os.environ.get("ALLOW_NO_AUTH") == "1"
# NO upload limits. An experiment must never be shaped around the collector,
# and a run that took hours to produce must never be refused for being large
# — that trade is always the wrong way round.
#
# The one thing still enforced is a decompression-ratio check, and it is a
# different thing from a size cap: it rejects a body whose gzip expands
# beyond ZIP_BOMB_RATIO, which is an attack signature rather than a big
# experiment (real traces compress ~10x, nowhere near the bound). A legitimate
# upload of any size passes it.
#
# The cost of having no cap is that this process reads the body whole,
# gunzips it whole and json.loads it whole, so a request needs several times
# its decompressed size in RAM. The client keeps requests small by streaming
# its file and POSTing in bounded chunks, which is the right place to solve
# it: the collector should accept whatever it is sent, and the sender should
# not need to know the collector's memory to choose a chunk size.
ZIP_BOMB_RATIO = int(os.environ.get("TRACE_ZIP_BOMB_RATIO", "200"))
SCHEMA_VERSION = 1

if not AUTH_TOKEN and not ALLOW_NO_AUTH:
    raise SystemExit(
        "Refusing to start: set TRACE_UPLOAD_TOKEN, or ALLOW_NO_AUTH=1 for local dev."
    )

DATA_DIR.mkdir(parents=True, exist_ok=True)
ARCHIVE_DIR = DATA_DIR / "uploads"
ARCHIVE_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = DATA_DIR / "traces.db"

_START_TIME = time.time()


# --------------------------------------------------------------------------- #
# Storage
# --------------------------------------------------------------------------- #
class Store:
    """SQLite index + NDJSON archive. Thread-safe via a single guarded conn."""

    def __init__(self, db_path: Path):
        self._lock = threading.Lock()
        self._conn = sqlite3.connect(db_path, check_same_thread=False)
        self._conn.execute("PRAGMA journal_mode=WAL;")
        self._conn.executescript(
            """
            CREATE TABLE IF NOT EXISTS uploads (
                upload_id      TEXT PRIMARY KEY,
                device_id      TEXT NOT NULL,
                received_at    TEXT NOT NULL,   -- server wall-clock, ISO-8601 UTC
                generated_at   TEXT,            -- client-reported, ISO-8601
                record_count   INTEGER NOT NULL,
                schema_version INTEGER,
                app_version    TEXT,
                platform       TEXT,
                remote_addr    TEXT,
                archive_path   TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS records (
                id        INTEGER PRIMARY KEY AUTOINCREMENT,
                upload_id TEXT NOT NULL REFERENCES uploads(upload_id),
                device_id TEXT NOT NULL,
                type      TEXT,                  -- 'message' | 'contact' | 'density' | ...
                t         INTEGER,               -- event time, epoch ms (if present)
                body      TEXT NOT NULL          -- full record JSON
            );
            CREATE INDEX IF NOT EXISTS idx_records_device ON records(device_id);
            CREATE INDEX IF NOT EXISTS idx_records_type   ON records(type);
            CREATE INDEX IF NOT EXISTS idx_records_t      ON records(t);
            CREATE INDEX IF NOT EXISTS idx_records_upload ON records(upload_id);
            -- Hand-measured pairwise distances for an experiment's layout.
            -- Kept server-side, not in a browser: the measurement is a fact
            -- about the deployment, and it must not be lost with a cache or
            -- be invisible from a different machine.
            CREATE TABLE IF NOT EXISTS geometry (
                exp        TEXT PRIMARY KEY,
                devices    INTEGER NOT NULL,
                pairs      TEXT NOT NULL,   -- {"1-2": 30.0, ...} metres
                updated_at TEXT NOT NULL
            );
            """
        )
        self._conn.commit()

    def upload_exists(self, upload_id: str) -> bool:
        with self._lock:
            cur = self._conn.execute(
                "SELECT 1 FROM uploads WHERE upload_id = ? LIMIT 1", (upload_id,)
            )
            return cur.fetchone() is not None

    def persist(self, meta: Dict[str, Any], records: List[Dict[str, Any]], archive_path: str) -> None:
        with self._lock:
            self._conn.execute(
                """INSERT INTO uploads
                   (upload_id, device_id, received_at, generated_at, record_count,
                    schema_version, app_version, platform, remote_addr, archive_path)
                   VALUES (?,?,?,?,?,?,?,?,?,?)""",
                (
                    meta["upload_id"], meta["device_id"], meta["received_at"],
                    meta.get("generated_at"), len(records), meta.get("schema_version"),
                    meta.get("app_version"), meta.get("platform"),
                    meta.get("remote_addr"), archive_path,
                ),
            )
            self._conn.executemany(
                "INSERT INTO records (upload_id, device_id, type, t, body) VALUES (?,?,?,?,?)",
                [
                    (
                        meta["upload_id"], meta["device_id"],
                        r.get("type"), _coerce_epoch_ms(r.get("t")),
                        json.dumps(r, separators=(",", ":"), ensure_ascii=False),
                    )
                    for r in records
                ],
            )
            self._conn.commit()

    def experiments(self) -> List[Dict[str, Any]]:
        """One row per recorded experiment, newest first.

        The experiment name is the upload_id up to `.jsonl` — chunked uploads
        append `:length:index` to it, so the prefix is the only stable handle.
        """
        # Grouped over `uploads`, not `records`: one row per upload rather than
        # per record. The same query against records is a full scan of tens of
        # millions of rows and took ~2 minutes on the 14 GB database, which is
        # far too slow for something that only fills a dropdown.
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT substr(upload_id, 1, instr(upload_id, '.jsonl') + 5) AS exp,
                       SUM(record_count), COUNT(DISTINCT device_id), MAX(received_at)
                  FROM uploads
                 WHERE instr(upload_id, '.jsonl') > 0
                 GROUP BY exp
                 ORDER BY MAX(received_at) DESC
                """
            ).fetchall()
        out = []
        for exp, n, devices, last in rows:
            name = exp[4:-6] if exp.startswith("exp_") else exp
            out.append({"id": exp, "name": name, "records": n or 0,
                        "devices": devices, "lastUpload": last})
        return out

    def topology(self, exp: str) -> Dict[str, Any]:
        """The link and marker records for one experiment, grouped by device.

        These two types are all the topology view needs and are a tiny slice of
        a recording — a few thousand rows out of tens of millions — so the
        filtering belongs here rather than in the browser.
        """
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT device_id, type, body
                  FROM records
                 WHERE upload_id LIKE ? AND type IN ('marker', 'link', 'location')
                 ORDER BY t
                """,
                (exp + "%",),
            ).fetchall()
        devices: Dict[str, Dict[str, List[Any]]] = {}
        for device_id, rtype, body in rows:
            try:
                rec = json.loads(body)
            except json.JSONDecodeError:
                continue
            d = devices.setdefault(
                device_id, {"markers": [], "links": [], "locations": []}
            )
            if rtype == "marker":
                d["markers"].append(rec)
            elif rtype == "location":
                d["locations"].append(rec)
            elif rec.get("event") in ("connected", "drop"):
                d["links"].append(rec)
        return {
            "exp": exp,
            "devices": [
                {"deviceId": k, "markers": v["markers"], "links": v["links"],
                 "locations": v["locations"]}
                for k, v in devices.items()
            ],
        }

    def get_geometry(self, exp: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._conn.execute(
                "SELECT devices, pairs, updated_at FROM geometry WHERE exp = ?",
                (exp,),
            ).fetchone()
        if not row:
            return None
        return {"exp": exp, "devices": row[0], "pairs": json.loads(row[1]),
                "updatedAt": row[2]}

    def put_geometry(self, exp: str, devices: int, pairs: Dict[str, float]) -> None:
        with self._lock:
            self._conn.execute(
                "INSERT INTO geometry (exp, devices, pairs, updated_at) "
                "VALUES (?,?,?,?) ON CONFLICT(exp) DO UPDATE SET "
                "devices=excluded.devices, pairs=excluded.pairs, "
                "updated_at=excluded.updated_at",
                (exp, devices, json.dumps(pairs), _utc_now_iso()),
            )
            self._conn.commit()

    def stats(self) -> Dict[str, Any]:
        with self._lock:
            uploads = self._conn.execute("SELECT COUNT(*) FROM uploads").fetchone()[0]
            devices = self._conn.execute("SELECT COUNT(DISTINCT device_id) FROM records").fetchone()[0]
            total_records = self._conn.execute("SELECT COUNT(*) FROM records").fetchone()[0]
            by_type = dict(
                self._conn.execute(
                    "SELECT COALESCE(type,'(none)'), COUNT(*) FROM records GROUP BY type ORDER BY 2 DESC"
                ).fetchall()
            )
        return {
            "uploads": uploads,
            "devices": devices,
            "records": total_records,
            "records_by_type": by_type,
        }


def _coerce_epoch_ms(v: Any) -> Optional[int]:
    """Accept epoch-ms ints or ISO-8601 strings for the indexed `t` column."""
    if v is None:
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, str):
        try:
            return int(datetime.fromisoformat(v.replace("Z", "+00:00")).timestamp() * 1000)
        except ValueError:
            return None
    return None


STORE = Store(DB_PATH)


# --------------------------------------------------------------------------- #
# Request / response models  (envelope only — record bodies are free-form)
# --------------------------------------------------------------------------- #
class TraceUpload(BaseModel):
    # Required envelope fields.
    uploadId: str = Field(..., min_length=1, max_length=128)
    deviceId: str = Field(..., min_length=1, max_length=256)
    records: List[Dict[str, Any]]
    # Optional metadata.
    schemaVersion: Optional[int] = None
    generatedAt: Optional[str] = None     # ISO-8601 on the client
    appVersion: Optional[str] = None
    platform: Optional[str] = None        # 'android' | 'ios'
    consent: Optional[bool] = None        # client asserts consent was given

    model_config = {"extra": "allow"}     # tolerate unknown envelope fields


# --------------------------------------------------------------------------- #
# App
# --------------------------------------------------------------------------- #
app = FastAPI(title="Grassroots Trace Server", version=str(SCHEMA_VERSION))


def _check_auth(authorization: Optional[str]) -> None:
    if ALLOW_NO_AUTH and not AUTH_TOKEN:
        return
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    presented = authorization[len("Bearer "):]
    # Constant-time compare to avoid token-timing oracles.
    if not hmac.compare_digest(presented, AUTH_TOKEN):
        raise HTTPException(status_code=403, detail="invalid token")


def _utc_now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


@app.get("/v1/health")
def health() -> Dict[str, Any]:
    return {
        "status": "ok",
        "schemaVersion": SCHEMA_VERSION,
        "uptimeSeconds": round(time.time() - _START_TIME, 1),
    }


@app.get("/v1/stats")
def stats(authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    _check_auth(authorization)
    return STORE.stats()


@app.get("/")
def root() -> RedirectResponse:
    """Bare domain opens the viewer — the point is to reach it from a phone
    by typing the host and nothing else."""
    return RedirectResponse(url="/dashboard")


@app.get("/dashboard")
def dashboard() -> HTMLResponse:
    """The mesh topology viewer.

    Served without auth because it carries no data — it fetches everything
    from the endpoints below, which do check the token. Keeping the page
    itself open avoids putting a bearer token in a URL to load it.
    """
    page = Path(__file__).with_name("mesh_dashboard.html")
    if not page.exists():
        raise HTTPException(status_code=404, detail="mesh_dashboard.html not found")
    return HTMLResponse(
        "<!doctype html><html><head><meta charset='utf-8'>"
        "<meta name='viewport' content='width=device-width,initial-scale=1'>"
        "</head><body>" + page.read_text(encoding="utf-8") + "</body></html>"
    )


@app.get("/v1/experiments")
def experiments(authorization: Optional[str] = Header(default=None)) -> List[Dict[str, Any]]:
    _check_auth(authorization)
    return STORE.experiments()


@app.get("/v1/topology")
def topology(exp: str, authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    _check_auth(authorization)
    if not exp:
        raise HTTPException(status_code=400, detail="exp is required")
    return STORE.topology(exp)


class GeometryIn(BaseModel):
    exp: str
    devices: int = Field(ge=2, le=64)
    # {"1-2": 30.0} in metres. A pair may be omitted (not measured); it is
    # NOT stored as zero, because "we did not measure this" and "these two
    # phones were in the same place" are different facts.
    pairs: Dict[str, float]


@app.get("/v1/geometry")
def get_geometry(exp: str, authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    return STORE.get_geometry(exp) or {"exp": exp, "devices": 0, "pairs": {}}


@app.put("/v1/geometry")
def put_geometry(body: GeometryIn,
                 authorization: Optional[str] = Header(default=None)):
    _check_auth(authorization)
    clean = {}
    for k, v in body.pairs.items():
        a, _, b = k.partition("-")
        if not (a.isdigit() and b.isdigit()):
            raise HTTPException(status_code=400, detail=f"bad pair key {k!r}")
        if v < 0:
            raise HTTPException(status_code=400, detail=f"negative distance {k}")
        # Canonical low-high, so "2-1" and "1-2" can never both be stored.
        lo, hi = sorted((int(a), int(b)))
        clean[f"{lo}-{hi}"] = float(v)
    STORE.put_geometry(body.exp, body.devices, clean)
    return {"stored": len(clean)}


@app.post("/v1/traces")
async def upload_traces(
    request: Request,
    authorization: Optional[str] = Header(default=None),
    content_encoding: Optional[str] = Header(default=None),
) -> JSONResponse:
    _check_auth(authorization)

    raw = await request.body()

    # The mobile client SHOULD gzip the body (traces compress ~10x).
    if content_encoding and "gzip" in content_encoding.lower():
        compressed_len = len(raw)
        try:
            raw = gzip.decompress(raw)
        except OSError:
            raise HTTPException(status_code=400, detail="invalid gzip body")
        # Ratio, not size: a real trace expands ~10x, so anything past 200x is
        # a decompression bomb rather than a large experiment. Size alone is
        # never a reason to refuse an upload.
        if compressed_len and len(raw) > compressed_len * ZIP_BOMB_RATIO:
            raise HTTPException(
                status_code=413,
                detail=f"decompression ratio {len(raw) // compressed_len}x "
                       f"exceeds {ZIP_BOMB_RATIO}x — refusing a likely bomb",
            )

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"invalid JSON: {e}")

    try:
        upload = TraceUpload.model_validate(payload)
    except Exception as e:  # pydantic ValidationError
        raise HTTPException(status_code=422, detail=f"invalid envelope: {e}")

    # Idempotency: a repeated uploadId is a successful no-op.
    if STORE.upload_exists(upload.uploadId):
        return JSONResponse(
            status_code=200,
            content={"status": "duplicate", "uploadId": upload.uploadId, "stored": 0},
        )

    received_at = _utc_now_iso()
    meta = {
        "upload_id": upload.uploadId,
        "device_id": upload.deviceId,
        "received_at": received_at,
        "generated_at": upload.generatedAt,
        "schema_version": upload.schemaVersion,
        "app_version": upload.appVersion,
        "platform": upload.platform,
        "remote_addr": request.client.host if request.client else None,
    }

    # 1) Lossless archive: one line per upload, with the server's receipt metadata.
    archive_path = ARCHIVE_DIR / f"{received_at[:10]}.ndjson"
    archive_line = {
        "_received_at": received_at,
        "_remote_addr": meta["remote_addr"],
        "envelope": payload,
    }
    with open(archive_path, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(archive_line, ensure_ascii=False, separators=(",", ":")) + "\n")

    # 2) Queryable index.
    STORE.persist(meta, upload.records, str(archive_path))

    return JSONResponse(
        status_code=201,
        content={
            "status": "ok",
            "uploadId": upload.uploadId,
            "stored": len(upload.records),
            "receivedAt": received_at,
        },
    )


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("HOST", "0.0.0.0"),
        port=int(os.environ.get("PORT", "8443")),
    )
