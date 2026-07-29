#!/usr/bin/env bash
#
# One-way mirror: Immich library on the NVMe  ->  OneDrive.
#
# Anything that lands in Immich (iPhone auto-backup or a web upload) ends up
# in OneDrive on the next run. Nothing flows back the other way.
#
# Deliberately NOT synced: thumbs/ and encoded-video/. Both are derived data
# that Immich regenerates from the originals, and together they can easily
# double your storage footprint for no recovery value.
#
# Usage:  ./immich-onedrive-sync.sh [--dry-run]

set -euo pipefail

# ---------------------------------------------------------------- config ---
UPLOAD_LOCATION="${UPLOAD_LOCATION:-/srv/immich/data}"
RCLONE_REMOTE="${RCLONE_REMOTE:-onedrive}"
REMOTE_PATH="${REMOTE_PATH:-Immich}"

# Dump Postgres before syncing. Immich also writes its own scheduled dumps to
# backups/ if enabled in the admin UI; this is belt-and-braces and costs little.
DUMP_DATABASE="${DUMP_DATABASE:-true}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-immich_postgres}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"

LOG_FILE="${LOG_FILE:-/var/log/immich-onedrive-sync.log}"
# ---------------------------------------------------------------------------

DRY_RUN=()
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=(--dry-run)

log() { printf '%s  %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

command -v rclone >/dev/null || die "rclone not installed"
[[ -d "$UPLOAD_LOCATION" ]] || die "UPLOAD_LOCATION not found: $UPLOAD_LOCATION"
rclone lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1 \
  || die "rclone remote '${RCLONE_REMOTE}' unreachable — run: rclone config reconnect ${RCLONE_REMOTE}:"

log "=== sync start ==="

# --- 1. database dump ------------------------------------------------------
if [[ "$DUMP_DATABASE" == "true" ]]; then
  if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
    dump_dir="${UPLOAD_LOCATION}/backups"
    mkdir -p "$dump_dir"
    dump_file="${dump_dir}/manual-dump-$(date +%Y%m%d).sql.gz"
    log "dumping database -> $(basename "$dump_file")"
    docker exec -t "$POSTGRES_CONTAINER" \
      pg_dumpall --clean --if-exists --username="$POSTGRES_USER" \
      | gzip > "${dump_file}.tmp"
    mv "${dump_file}.tmp" "$dump_file"
    # Keep a week of manual dumps locally; OneDrive keeps whatever we push.
    find "$dump_dir" -name 'manual-dump-*.sql.gz' -mtime +7 -delete
  else
    log "WARN: container '${POSTGRES_CONTAINER}' not running — skipping dump"
  fi
fi

# --- 2. mirror to OneDrive -------------------------------------------------
# --backup-dir means a file deleted in Immich is moved aside on OneDrive
# rather than destroyed, so a bad delete is recoverable for 30 days.
BACKUP_DIR="${RCLONE_REMOTE}:${REMOTE_PATH}-deleted/$(date +%Y-%m-%d)"

rclone sync "$UPLOAD_LOCATION" "${RCLONE_REMOTE}:${REMOTE_PATH}" \
  "${DRY_RUN[@]}" \
  --backup-dir "$BACKUP_DIR" \
  --exclude '/thumbs/**' \
  --exclude '/encoded-video/**' \
  --exclude '.immich' \
  --exclude '**/*.tmp' \
  --transfers 4 \
  --checkers 8 \
  --tpslimit 10 \
  --retries 3 \
  --low-level-retries 10 \
  --track-renames \
  --stats 5m \
  --stats-one-line \
  --log-file "$LOG_FILE" \
  --log-level INFO

log "=== sync complete ==="
