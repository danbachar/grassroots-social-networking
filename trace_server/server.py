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
        self._conn_path = str(db_path)     # for the index build's own connection
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
            -- One row per SIGHTING of a packet: the route index. Derived
            -- entirely from `records` and rebuildable from it, so it is a
            -- cache, not data — but a necessary one. Reconstructing a route
            -- by scanning `records` for one id is a full scan of tens of
            -- millions of rows per packet; here it is an index seek.
            CREATE TABLE IF NOT EXISTS packet_events (
                exp        TEXT    NOT NULL,
                packet_id  TEXT    NOT NULL,
                t          INTEGER,
                device_id  TEXT    NOT NULL,  -- node that recorded it (= its pubkey)
                event      TEXT    NOT NULL,  -- mint|aired|relay|dup|packetDup|
                                              -- store|convey|end|deliver|ackRx|drop
                from_peer  TEXT,              -- neighbour that handed it over
                to_device  TEXT,              -- BLE device a convey was sent on
                ttl_in     INTEGER,
                ttl_out    INTEGER,
                hop        INTEGER,
                dwell_ms   INTEGER,
                carried    INTEGER,
                message_id TEXT,
                recipient  TEXT,
                kind       TEXT,              -- data|ack, known at the originator
                reason     TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_pev_route ON packet_events(exp, packet_id, t);
            CREATE INDEX IF NOT EXISTS idx_pev_event ON packet_events(exp, event);
            -- One row per PACKET, rolled up at build time. The same numbers
            -- are a GROUP BY over packet_events, and that is how they were
            -- read at first — 198 s per request on the collector's disk, past
            -- the proxy's patience, so every list load 502'd. Aggregating a
            -- million rows is a build-time job, not a per-request one.
            CREATE TABLE IF NOT EXISTS packet_summary (
                exp        TEXT    NOT NULL,
                packet_id  TEXT    NOT NULL,
                t0         INTEGER,
                t1         INTEGER,
                kind       TEXT,
                origin     TEXT,
                message_id TEXT,
                recipient  TEXT,
                nodes      INTEGER,
                relays     INTEGER,
                delivers   INTEGER,
                acked      INTEGER,
                conveys    INTEGER,
                drops      INTEGER,
                ttl_min    INTEGER,
                PRIMARY KEY (exp, packet_id)
            );
            CREATE INDEX IF NOT EXISTS idx_psum ON packet_summary(exp, nodes DESC, t0);
            CREATE TABLE IF NOT EXISTS packet_index_meta (
                exp      TEXT PRIMARY KEY,
                built_at TEXT NOT NULL,
                events   INTEGER NOT NULL,
                packets  INTEGER NOT NULL
            );
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

    # ----------------------------------------------------------------- routes
    # A packet's route is reconstructable offline even though the wire is
    # deliberately uninformative — the outer envelope names no sender, and a
    # relay cannot tell a data packet from an ack. What makes the join work is
    # that the packetId survives relaying unchanged (it IS the dedup key), so
    # the id the originator minted is the id every hop records. Each node
    # reports its own sighting; `fromPeer` on a relay/deliver record names the
    # neighbour that handed the packet over, which is a real directed edge, not
    # an inference from timing.
    #
    # Two things are structurally invisible and the UI must say so rather than
    # guess: sync frames (traced on neither side, TTL 1, so a conveyance shows
    # only as the holder's `convey` and the receiver's later sighting), and any
    # hop over a link that was not yet authenticated (`fromPeer` is then null).

    def packet_index_state(self, exp: str) -> Optional[Dict[str, Any]]:
        with self._lock:
            row = self._conn.execute(
                "SELECT built_at, events, packets FROM packet_index_meta WHERE exp = ?",
                (exp,),
            ).fetchone()
        if not row:
            return None
        return {"exp": exp, "builtAt": row[0], "events": row[1], "packets": row[2]}

    def build_packet_index(self, exp: str) -> Dict[str, Any]:
        """Scan one experiment's records once and materialise every sighting.

        Read on a private connection and streamed: the source can be tens of
        millions of rows and the server has under 2 GB of memory, so nothing
        here may fetchall.
        """
        like = exp + "%"

        # Pass A — `message` records. These are the only ones that know a
        # packet's KIND (data vs ack) and its messageId; a relay's record knows
        # neither. Deliveries name a messageId only, so they are held back and
        # expanded once the sender's `sealed` record has supplied the mapping.
        msg_to_packets: Dict[str, List[str]] = {}
        pending_recv: List[tuple] = []
        conn = sqlite3.connect(self._conn_path, timeout=60)
        # Written on THIS connection, in batches, and never accumulated: a
        # multi-million-row experiment produced ~1.5M sightings, and holding
        # them as Python tuples to insert at the end was ~1 GB — which the
        # collector does not have, so the process was OOM-killed mid-request
        # and the caller saw a 502.
        wconn = sqlite3.connect(self._conn_path, timeout=120)
        wconn.execute("PRAGMA busy_timeout=120000")
        pending: List[tuple] = []
        total = 0

        def emit(row: tuple) -> None:
            nonlocal total
            pending.append(row)
            total += 1
            if len(pending) >= 20000:
                flush()

        def flush() -> None:
            if not pending:
                return
            wconn.executemany(
                "INSERT INTO packet_events VALUES (" + ",".join("?" * 16) + ")",
                pending)
            wconn.commit()
            pending.clear()

        try:
            wconn.execute("DELETE FROM packet_events WHERE exp = ?", (exp,))
            wconn.execute("DELETE FROM packet_summary WHERE exp = ?", (exp,))
            wconn.commit()
            cur = conn.execute(
                "SELECT device_id, t, body FROM records "
                " WHERE upload_id LIKE ? AND type = 'message'", (like,))
            while True:
                batch = cur.fetchmany(20000)
                if not batch:
                    break
                for device_id, t, body in batch:
                    try:
                        r = json.loads(body)
                    except json.JSONDecodeError:
                        continue
                    d = r.get("dir")
                    mid = r.get("messageId")
                    if d == "sealed":
                        ids = [str(i) for i in (r.get("packetIds") or [])]
                        if mid:
                            msg_to_packets[str(mid)] = ids
                        for pid in ids:
                            emit((exp, pid, t, device_id, "mint", None, None,
                                  None, None, None, None, None, mid,
                                  r.get("peer"), "data", None))
                    elif d == "ackTx":
                        pid = r.get("packetId")
                        if pid:
                            emit((exp, str(pid), t, device_id, "mint", None,
                                  None, None, None, None, None, None, mid,
                                  r.get("peer"), "ack", None))
                    elif d == "ackRx":
                        pid = r.get("packetId")
                        if pid:
                            emit((exp, str(pid), t, device_id, "ackRx",
                                  r.get("fromPeer"), None, None, None, None,
                                  None, None, mid, None, "ack", None))
                    elif d == "recv" and mid:
                        pending_recv.append((device_id, t, str(mid), r.get("fromPeer"),
                                             r.get("relayHops")))
            for device_id, t, mid, from_peer, hops in pending_recv:
                for pid in msg_to_packets.get(mid, ()):
                    emit((exp, pid, t, device_id, "deliver", from_peer, None,
                          None, None, hops, None, None, mid, None, "data", None))

            # Pass B — everything a node records about someone else's packet.
            cur = conn.execute(
                "SELECT device_id, type, t, body FROM records "
                " WHERE upload_id LIKE ? AND type IN ('relay','custody','packetDup','drop')",
                (like,))
            while True:
                batch = cur.fetchmany(20000)
                if not batch:
                    break
                for device_id, rtype, t, body in batch:
                    try:
                        r = json.loads(body)
                    except json.JSONDecodeError:
                        continue
                    pid = r.get("packetId")
                    if not pid:
                        continue           # a drop with no id joins to nothing
                    pid = str(pid)
                    ev = r.get("event")
                    if rtype == "relay":
                        name = {"aired": "aired", "dup": "dup"}.get(ev, "relay")
                        emit((exp, pid, t, device_id, name, r.get("fromPeer"),
                              None, r.get("ttlIn"), r.get("ttlOut"), r.get("hop"),
                              r.get("dwellMs"), 1 if r.get("carried") else 0,
                              None, None, None, None))
                    elif rtype == "custody":
                        emit((exp, pid, t, device_id, ev or "custody", None,
                              r.get("toDevice"), None, None, None, None, None,
                              None, r.get("recipient"), None, r.get("reason")))
                    elif rtype == "packetDup":
                        emit((exp, pid, t, device_id, "packetDup", None, None,
                              None, None, None, None, None, None, None, None,
                              r.get("transport")))
                    else:                                        # drop
                        emit((exp, pid, t, device_id, "drop", r.get("fromPeer"),
                              None, None, None, None, None, None,
                              r.get("messageId"), None, None,
                              f"{r.get('where')}/{r.get('reason')}"))
            flush()
            # `nodes` counts DISTINCT devices, which is the honest measure of
            # reach: a packet sighted twice on one node travelled no further
            # than one sighted once.
            wconn.execute(
                """
                INSERT INTO packet_summary
                SELECT exp, packet_id, MIN(t), MAX(t), MAX(kind),
                       MAX(CASE WHEN event='mint' THEN device_id END),
                       MAX(CASE WHEN event='mint' THEN message_id END),
                       MAX(CASE WHEN event='mint' THEN recipient END),
                       COUNT(DISTINCT device_id),
                       SUM(event='relay'), SUM(event='deliver'),
                       SUM(event='ackRx'), SUM(event='convey'),
                       SUM(event='drop'),
                       MIN(CASE WHEN event='relay' THEN ttl_out END)
                  FROM packet_events WHERE exp = ? GROUP BY packet_id
                """, (exp,))
            packets = wconn.execute(
                "SELECT COUNT(*) FROM packet_summary WHERE exp = ?",
                (exp,)).fetchone()[0]
            wconn.execute(
                "INSERT INTO packet_index_meta (exp, built_at, events, packets) "
                "VALUES (?,?,?,?) ON CONFLICT(exp) DO UPDATE SET "
                "built_at=excluded.built_at, events=excluded.events, "
                "packets=excluded.packets",
                (exp, _utc_now_iso(), total, packets))
            wconn.commit()
        except BaseException:
            # A half-written index reads as a complete one and silently answers
            # "this packet was never seen again". Leave nothing behind instead.
            try:
                wconn.execute("DELETE FROM packet_events WHERE exp = ?", (exp,))
                wconn.execute("DELETE FROM packet_summary WHERE exp = ?", (exp,))
                wconn.commit()
            except sqlite3.Error:
                pass
            raise
        finally:
            conn.close()
            wconn.close()
        return {"exp": exp, "events": total, "packets": packets,
                "builtAt": _utc_now_iso()}

    def packets(self, exp: str, kind: Optional[str] = None,
                outcome: Optional[str] = None, q: Optional[str] = None,
                min_hops: int = 0, limit: int = 300) -> List[Dict[str, Any]]:
        """One row per packet: who minted it, how far it got, how it ended."""
        sql = ("SELECT packet_id, t0, t1, kind, origin, message_id, recipient, "
               "       nodes, relays, delivers, acked, conveys, drops, ttl_min "
               "  FROM packet_summary WHERE exp = ?")
        params: List[Any] = [exp]
        if q:
            sql += " AND (packet_id LIKE ? OR message_id LIKE ?)"
            params += [f"%{q}%", f"%{q}%"]
        if kind in ("data", "ack"):
            sql += " AND kind = ?"
            params.append(kind)
        if outcome == "delivered":
            sql += " AND (delivers > 0 OR acked > 0)"
        elif outcome == "undelivered":
            sql += " AND delivers = 0 AND acked = 0"
        elif outcome == "multihop":
            sql += " AND relays > 0"
        if min_hops:
            sql += " AND nodes >= ?"
            params.append(min_hops + 1)
        sql += " ORDER BY nodes DESC, t0 ASC LIMIT ?"
        params.append(max(1, min(limit, 2000)))
        with self._lock:
            rows = self._conn.execute(sql, params).fetchall()
        return [
            {"packetId": r[0], "t0": r[1], "t1": r[2], "kind": r[3], "origin": r[4],
             "messageId": r[5], "recipient": r[6], "nodes": r[7], "relays": r[8],
             "delivered": bool(r[9]) or bool(r[10]), "conveys": r[11],
             "drops": r[12], "ttlMin": r[13]}
            for r in rows
        ]

    def route(self, exp: str, packet_id: str) -> Dict[str, Any]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT t, device_id, event, from_peer, to_device, ttl_in, ttl_out, "
                "       hop, dwell_ms, carried, message_id, recipient, kind, reason "
                "  FROM packet_events WHERE exp = ? AND packet_id = ? ORDER BY t",
                (exp, packet_id),
            ).fetchall()
        return {
            "exp": exp, "packetId": packet_id,
            "events": [
                {"t": r[0], "device": r[1], "event": r[2], "fromPeer": r[3],
                 "toDevice": r[4], "ttlIn": r[5], "ttlOut": r[6], "hop": r[7],
                 "dwellMs": r[8], "carried": bool(r[9]), "messageId": r[10],
                 "recipient": r[11], "kind": r[12], "reason": r[13]}
                for r in rows
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


@app.get("/v1/packets")
def packets(exp: str, kind: Optional[str] = None, outcome: Optional[str] = None,
            q: Optional[str] = None, minHops: int = 0, limit: int = 300,
            authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    """Packets of one experiment, summarised — the pick-list for a route view.

    Returns `index: null` when the route index has not been built for this
    experiment yet; the caller then POSTs to /v1/packets/index. The build is
    explicit rather than lazy because it is a full scan of the experiment,
    which is minutes on a multi-million-record run — not something to trigger
    by accident from a dropdown.
    """
    _check_auth(authorization)
    if not exp:
        raise HTTPException(status_code=400, detail="exp is required")
    state = STORE.packet_index_state(exp)
    if not state:
        return {"exp": exp, "index": None, "packets": []}
    return {"exp": exp, "index": state,
            "packets": STORE.packets(exp, kind=kind, outcome=outcome, q=q,
                                     min_hops=minHops, limit=limit)}


@app.post("/v1/packets/index")
def build_packet_index(exp: str,
                       authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    _check_auth(authorization)
    if not exp:
        raise HTTPException(status_code=400, detail="exp is required")
    return STORE.build_packet_index(exp)


@app.get("/v1/route")
def route(exp: str, pid: str,
          authorization: Optional[str] = Header(default=None)) -> Dict[str, Any]:
    _check_auth(authorization)
    if not exp or not pid:
        raise HTTPException(status_code=400, detail="exp and pid are required")
    return STORE.route(exp, pid)


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
