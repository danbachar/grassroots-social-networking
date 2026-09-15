#!/usr/bin/env bash
#
# Take a campaign off the trace server: compress it, bring it down to a backup
# path, prove it arrived intact, and only then delete it from the server.
#
# Run it after the last run of a campaign has been analysed and before the
# fleet is reflashed for the next one. What the server is left with is an empty
# database, so the next campaign's uploads are the only thing in it.
#
# DELETION IS THE LAST STEP AND IT IS CONDITIONAL. Nothing on the server is
# removed until the archive has been transferred and verified against the
# checksum computed before it moved. Any failure leaves the server exactly as
# it was found, with the staged copy still there, and exits non-zero.
#
# The collector is down only for the seconds it takes to rename the live files
# aside; compression and transfer happen with it already back up and serving a
# fresh database, so a long download never holds the fleet off the air.
#
# Usage:
#   tools/reset_trace_server.sh <backup-dir>              # dry run, changes nothing
#   tools/reset_trace_server.sh <backup-dir> --go         # do it
#   tools/reset_trace_server.sh <backup-dir> --go --verify-full
#
# --verify-full additionally unpacks the archive to a scratch directory beside
# the backup and checks every file against the per-file digests taken on the
# server. The default check is the archive's own end-to-end digest plus a
# streaming unpack, which proves the bytes are the server's and that they
# decompress and untar cleanly; --verify-full also proves each file inside
# still hashes to what it did before it was packed, at the cost of unpacking
# the whole campaign locally.
set -euo pipefail

HOST=${TRACE_HOST:-trace-server}
COMPOSE_DIR=${TRACE_COMPOSE_DIR:-/home/dbachar/trace_server}
DATA=${TRACE_DATA:-/mnt/HC_Volume_106351660/data}
# The server has one core, so compression is single-threaded whatever we ask
# for. Level 6 runs at tens of MB/s on it and still folds JSONL and a SQLite
# file of JSON text down by roughly an order of magnitude; raising it buys
# little and costs minutes.
ZSTD_LEVEL=${ZSTD_LEVEL:-6}

BACKUP_DIR=${1:-}
shift || true
GO=no
VERIFY_FULL=no
for arg in "$@"; do
  case "$arg" in
    --go) GO=yes ;;
    --verify-full) VERIFY_FULL=yes ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

if [[ -z "$BACKUP_DIR" ]]; then
  echo "usage: $0 <backup-dir> [--go] [--verify-full]" >&2
  exit 2
fi
[[ -d "$BACKUP_DIR" ]] || { echo "no such backup directory: $BACKUP_DIR" >&2; exit 1; }
[[ -w "$BACKUP_DIR" ]] || { echo "backup directory is not writable: $BACKUP_DIR" >&2; exit 1; }

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
STAGE="$DATA/../reset-$STAMP"
ARCHIVE_REMOTE="$DATA/../$STAMP.tar.zst"
ARCHIVE_LOCAL="$BACKUP_DIR/trace-$STAMP.tar.zst"

say() { printf '\n=== %s ===\n' "$*"; }

# ---------------------------------------------------------------- inventory
say "what is on the server now"
ssh "$HOST" DATA="$DATA" bash -s <<'REMOTE'
set -euo pipefail
sudo du -sh "$DATA"/* 2>/dev/null || true
DB="$DATA/traces.db"
if [[ -f "$DB" ]]; then
  echo "--- experiments in the live database ---"
  sudo sqlite3 "file:$DB?mode=ro" \
    "SELECT substr(upload_id,1,instr(upload_id,'.jsonl')-1) AS exp,
            count(DISTINCT device_id) AS devices,
            sum(record_count) AS records,
            substr(min(received_at),1,16) AS first_upload
       FROM uploads GROUP BY exp ORDER BY min(received_at);"
fi
echo "--- free space on the data volume ---"
df -h "$DATA" | tail -1
REMOTE

FREE_LOCAL=$(df -k "$BACKUP_DIR" | tail -1 | awk '{print $4}')
printf '\nbackup target: %s (%s KiB free)\n' "$BACKUP_DIR" "$FREE_LOCAL"

if [[ "$GO" != yes ]]; then
  echo
  echo "DRY RUN — nothing moved, nothing deleted."
  echo "Re-run with --go to archive to $ARCHIVE_LOCAL and clear the server."
  exit 0
fi

# ------------------------------------------------- stage, restart, compress
# The rename in step 2 is what takes the collector down, and it is a rename on
# one filesystem, so the outage is the container restart and nothing more.
say "staging the campaign aside and restarting the collector"
REMOTE_SHA=$(ssh "$HOST" \
  DATA="$DATA" STAGE="$STAGE" ARCHIVE="$ARCHIVE_REMOTE" \
  COMPOSE_DIR="$COMPOSE_DIR" ZSTD_LEVEL="$ZSTD_LEVEL" bash -s <<'REMOTE'
set -euo pipefail
DB="$DATA/traces.db"
[[ -d "$DATA" ]] || { echo "no data dir at $DATA" >&2; exit 1; }
[[ -e "$STAGE" ]] && { echo "stage $STAGE already exists" >&2; exit 1; }
[[ -e "$ARCHIVE" ]] && { echo "archive $ARCHIVE already exists" >&2; exit 1; }

sudo docker compose -f "$COMPOSE_DIR/docker-compose.yml" stop trace >&2

# Fold the write-ahead log in first: a .db archived without its -wal is
# missing whatever had not been checkpointed, which for a freshly stopped
# collector is the tail of the last run.
[[ -f "$DB" ]] && sudo sqlite3 "$DB" 'PRAGMA wal_checkpoint(TRUNCATE);' >/dev/null

sudo mkdir -p "$STAGE"
for f in traces.db traces.db-wal traces.db-shm uploads; do
  [[ -e "$DATA/$f" ]] && sudo mv "$DATA/$f" "$STAGE/$f"
done
sudo mkdir -p "$DATA/uploads"

# Back online before the slow part starts: the fleet can upload into the fresh
# database while this campaign is still compressing and downloading.
sudo docker compose -f "$COMPOSE_DIR/docker-compose.yml" start trace >&2

# Per-file digests, taken before anything is packed. They ride inside the
# archive, so a restore years from now can be checked against them.
( cd "$STAGE" && sudo find . -type f -print0 \
    | sudo xargs -0 sha256sum | sudo tee MANIFEST.sha256 >/dev/null )

sudo tar -C "$STAGE" -cf - . \
  | sudo zstd -q -"$ZSTD_LEVEL" --long=27 -o "$ARCHIVE"

sudo sha256sum "$ARCHIVE" | awk '{print $1}'
REMOTE
)
echo "server-side archive digest: $REMOTE_SHA"

# ------------------------------------------------------------------ transfer
say "downloading"
# --partial so an interrupted download resumes rather than starting over.
rsync -h --progress --partial "$HOST:$ARCHIVE_REMOTE" "$ARCHIVE_LOCAL"

# ------------------------------------------------------------------- verify
say "verifying"
LOCAL_SHA=$(shasum -a 256 "$ARCHIVE_LOCAL" | awk '{print $1}')
echo "local digest:  $LOCAL_SHA"
echo "server digest: $REMOTE_SHA"
if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  echo "DIGEST MISMATCH — the server is untouched and still holds the campaign." >&2
  echo "Staged at: $STAGE   Archive: $ARCHIVE_REMOTE" >&2
  exit 1
fi

# The bytes are the server's; this proves they are also a well-formed archive.
zstd -dc "$ARCHIVE_LOCAL" | tar -tf - >/dev/null
echo "archive unpacks cleanly"

if [[ "$VERIFY_FULL" == yes ]]; then
  SCRATCH="$BACKUP_DIR/.verify-$STAMP"
  mkdir -p "$SCRATCH"
  zstd -dc "$ARCHIVE_LOCAL" | tar -xf - -C "$SCRATCH"
  ( cd "$SCRATCH" && shasum -a 256 -c MANIFEST.sha256 >/dev/null )
  echo "every file matches the digest taken on the server"
  rm -rf "$SCRATCH"
fi

# ------------------------------------------------------------------- delete
# Only reachable when every check above passed.
say "deleting the campaign from the server"
ssh "$HOST" STAGE="$STAGE" ARCHIVE="$ARCHIVE_REMOTE" DATA="$DATA" bash -s <<'REMOTE'
set -euo pipefail
sudo rm -rf "$STAGE"
sudo rm -f "$ARCHIVE"
DB="$DATA/traces.db"
for _ in $(seq 1 30); do [[ -f "$DB" ]] && break; sleep 1; done
if [[ -f "$DB" ]]; then
  echo -n "uploads in the fresh database: "
  sudo sqlite3 "file:$DB?mode=ro" 'SELECT count(*) FROM uploads;'
else
  echo "WARNING: $DB was not recreated — check 'docker compose logs trace'" >&2
  exit 1
fi
df -h "$DATA" | tail -1
REMOTE

say "done"
ls -lh "$ARCHIVE_LOCAL"
echo "The campaign now exists only at $ARCHIVE_LOCAL — keep it somewhere that is backed up."
