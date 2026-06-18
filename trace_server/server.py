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
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

# --------------------------------------------------------------------------- #
# Configuration (all via environment)
# --------------------------------------------------------------------------- #
DATA_DIR = Path(os.environ.get("TRACE_DATA_DIR", "./data")).resolve()
AUTH_TOKEN = os.environ.get("TRACE_UPLOAD_TOKEN", "")
ALLOW_NO_AUTH = os.environ.get("ALLOW_NO_AUTH") == "1"
# Hard limits to bound abuse / accidental megabatches.
MAX_BODY_BYTES = int(os.environ.get("TRACE_MAX_BODY_BYTES", str(16 * 1024 * 1024)))  # 16 MiB
MAX_RECORDS_PER_UPLOAD = int(os.environ.get("TRACE_MAX_RECORDS", "200000"))
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


@app.post("/v1/traces")
async def upload_traces(
    request: Request,
    authorization: Optional[str] = Header(default=None),
    content_encoding: Optional[str] = Header(default=None),
) -> JSONResponse:
    _check_auth(authorization)

    raw = await request.body()
    if len(raw) > MAX_BODY_BYTES:
        raise HTTPException(status_code=413, detail="upload too large")

    # The mobile client SHOULD gzip the body (traces compress ~10x).
    if content_encoding and "gzip" in content_encoding.lower():
        try:
            raw = gzip.decompress(raw)
        except OSError:
            raise HTTPException(status_code=400, detail="invalid gzip body")
        if len(raw) > MAX_BODY_BYTES * 4:  # guard against zip bombs
            raise HTTPException(status_code=413, detail="decompressed body too large")

    try:
        payload = json.loads(raw)
    except json.JSONDecodeError as e:
        raise HTTPException(status_code=400, detail=f"invalid JSON: {e}")

    try:
        upload = TraceUpload.model_validate(payload)
    except Exception as e:  # pydantic ValidationError
        raise HTTPException(status_code=422, detail=f"invalid envelope: {e}")

    if len(upload.records) > MAX_RECORDS_PER_UPLOAD:
        raise HTTPException(status_code=413, detail="too many records in one upload")

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
