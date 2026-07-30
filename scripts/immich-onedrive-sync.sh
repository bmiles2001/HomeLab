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
# Usage:
#   ./immich-onedrive-sync.sh            # real run
#   ./immich-onedrive-sync.sh --dry-run  # change nothing, print what would happen
#
# Setup and restore: docs/onedrive-mirror.md

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

# Safety rail. `rclone sync` deletes anything on the destination that is absent
# from the source. If /srv/immich/data were ever empty, unmounted, or pointed
# somewhere wrong, an unguarded sync would clear the whole OneDrive copy in one
# run. Abort instead if a single run wants to remove more than this many files.
# Raise it deliberately after a real mass deletion; don't remove it.
MAX_DELETE="${MAX_DELETE:-200}"

# Files deleted in Immich are moved into Immich-deleted/<date>/ rather than
# erased, then aged out after this many days by step 4.
#
# This is stage 3 of four. Immich's own trash holds a deleted photo for 30 days
# before the file leaves the NVMe at all, and after step 4 purges it here it
# lands in OneDrive's recycle bin for another 30 - rclone cannot empty that,
# because Microsoft exposes no permanent-delete API for consumer OneDrive.
# So ~90 days end to end, and offsite space is not reclaimed until the last
# stage. docs/onedrive-mirror.md has the table.
DELETED_RETAIN_DAYS="${DELETED_RETAIN_DAYS:-30}"

# Warn when OneDrive is this full. M365 Personal/Family is 1TB, and a mirror
# that silently starts failing on quota is worse than no mirror, because you
# believe you have a backup.
QUOTA_WARN_PCT="${QUOTA_WARN_PCT:-85}"

LOG_FILE="${LOG_FILE:-/var/log/immich-onedrive-sync.log}"
# ---------------------------------------------------------------------------

DRY_RUN=()
DRY=false
LABEL=""
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=(--dry-run); DRY=true; LABEL="(DRY RUN) "; fi
# Note: LABEL exists because ${DRY:+...} would expand for the string "false"
# too - it tests for non-empty, not for truth - and every run would be labelled
# a dry run. Cheap mistake to make, confusing one to read in a log six months
# later when you're trying to work out whether a sync actually happened.

log() { printf '%s  %s\n' "$(date -Is)" "$*" | tee -a "$LOG_FILE"; }
die() { log "ERROR: $*"; exit 1; }

# Overlapping runs would fight over the same destination. The nightly timer
# allows 6h, and a first full upload of a large library can exceed that.
exec 9>/var/lock/immich-onedrive-sync.lock
flock -n 9 || die "another sync is already running"

command -v rclone >/dev/null || die "rclone not installed"
command -v flock  >/dev/null || die "flock not found (util-linux)"
[[ -d "$UPLOAD_LOCATION" ]] || die "UPLOAD_LOCATION not found: $UPLOAD_LOCATION"

# A present-but-empty library is the dangerous case: it looks fine to `-d` and
# would sync a deletion of everything. --max-delete catches it, but failing
# here gives a clearer message than an aborted transfer.
[[ -d "$UPLOAD_LOCATION/library" ]] \
  || die "$UPLOAD_LOCATION/library does not exist - is Immich actually running?"

rclone lsd "${RCLONE_REMOTE}:" >/dev/null 2>&1 \
  || die "rclone remote '${RCLONE_REMOTE}' unreachable. If it has been >90 days since the last run, the OneDrive refresh token has expired: rclone config reconnect ${RCLONE_REMOTE}:"

log "=== sync start ${LABEL}==="

# --- 1. quota check --------------------------------------------------------
# Cheap, and it turns "the backup quietly stopped working three months ago"
# into a line in the log you will actually see.
if quota_json=$(rclone about "${RCLONE_REMOTE}:" --json 2>/dev/null); then
  q_total=$(printf '%s' "$quota_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("total",0))' 2>/dev/null || echo 0)
  q_used=$(printf '%s' "$quota_json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("used",0))' 2>/dev/null || echo 0)
  if [[ "${q_total:-0}" -gt 0 ]]; then
    pct=$(( q_used * 100 / q_total ))
    hu() { numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1"; }
    log "onedrive: $(hu "$q_used") of $(hu "$q_total") used (${pct}%)"
    if [[ "$pct" -ge "$QUOTA_WARN_PCT" ]]; then
      log "WARN: OneDrive is ${pct}% full. Once it fills, this mirror fails and there is no offsite copy."
    fi
  fi
else
  log "WARN: could not read OneDrive quota - continuing"
fi

# Local side, for comparison. Divergence between these two over time is the
# signal that something is being silently skipped.
log "local:    $(du -sh --exclude=thumbs --exclude=encoded-video "$UPLOAD_LOCATION" 2>/dev/null | cut -f1) (excluding derived data)"

# --- 2. database dump ------------------------------------------------------
# The files give you back your photos. This gives you back albums, faces,
# shared links and users. Without it, a restore is a folder of pictures.
if [[ "$DUMP_DATABASE" == "true" ]] && ! $DRY; then
  if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -qx "$POSTGRES_CONTAINER"; then
    dump_dir="${UPLOAD_LOCATION}/backups"
    mkdir -p "$dump_dir"
    dump_file="${dump_dir}/manual-dump-$(date +%Y%m%d).sql.gz"
    log "dumping database -> $(basename "$dump_file")"
    docker exec -t "$POSTGRES_CONTAINER" \
      pg_dumpall --clean --if-exists --username="$POSTGRES_USER" \
      | gzip > "${dump_file}.tmp"

    # A dump that does not decompress is not a backup. Same check as
    # scripts/infisical-backup.sh, for the same reason.
    gunzip -t "${dump_file}.tmp" || die "dump failed gzip integrity check"
    size=$(stat -c%s "${dump_file}.tmp")
    [[ "$size" -gt 10240 ]] || die "dump is suspiciously small (${size} bytes) - is POSTGRES_USER right?"
    mv "${dump_file}.tmp" "$dump_file"
    log "dump ok (${size} bytes)"

    # Keep a week of dumps locally; OneDrive holds them for
    # DELETED_RETAIN_DAYS more after they age out here.
    find "$dump_dir" -name 'manual-dump-*.sql.gz' -mtime +7 -delete
  else
    log "WARN: container '${POSTGRES_CONTAINER}' not running - skipping dump"
  fi
elif $DRY; then
  log "(dry run) skipping database dump"
fi

# --- 3. mirror to OneDrive -------------------------------------------------
# --backup-dir means a file deleted in Immich is moved aside on OneDrive
# rather than destroyed, so a bad delete stays recoverable.
BACKUP_DIR="${RCLONE_REMOTE}:${REMOTE_PATH}-deleted/$(date +%Y-%m-%d)"

# --track-renames-strategy modtime,leaf is load-bearing, not decoration. The
# default strategy is `hash`, and local (MD5/SHA1) and OneDrive (QuickXorHash)
# share no hash algorithm, so rclone silently logs "--track-renames ignored ...
# no common hash" and tracks nothing. That matters exactly once: the day you
# change Immich's storage template and every file in the library gets a new
# path. With rename tracking those become server-side moves inside OneDrive.
# Without it, rclone re-uploads the entire library.
rclone sync "$UPLOAD_LOCATION" "${RCLONE_REMOTE}:${REMOTE_PATH}" \
  "${DRY_RUN[@]}" \
  --backup-dir "$BACKUP_DIR" \
  --exclude '/thumbs/**' \
  --exclude '/encoded-video/**' \
  --exclude '.immich' \
  --exclude '**/*.tmp' \
  --max-delete "$MAX_DELETE" \
  --transfers 4 \
  --checkers 8 \
  --tpslimit 10 \
  --retries 3 \
  --low-level-retries 10 \
  --track-renames \
  --track-renames-strategy modtime,leaf \
  --stats 5m \
  --stats-one-line \
  --log-file "$LOG_FILE" \
  --log-level INFO

# --- 4. age out the deleted-files holding area -----------------------------
# Without this, Immich-deleted/ grows forever and eventually eats the quota the
# photos need - which is how a backup system becomes the thing that breaks the
# backup.
if ! $DRY; then
  cutoff=$(date -d "${DELETED_RETAIN_DAYS} days ago" +%Y-%m-%d)
  while read -r d; do
    d="${d%/}"
    [[ "$d" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || continue
    # Lexicographic compare is correct for ISO-8601 dates, and only for those -
    # hence the regex guard above.
    if [[ "$d" < "$cutoff" ]]; then
      # NB: this moves the files to OneDrive's recycle bin, it does not free
      # quota. Empty that by hand at onedrive.com if you need space back now.
      log "pruning deleted-files holding area: $d (older than ${DELETED_RETAIN_DAYS}d, -> OneDrive recycle bin)"
      rclone purge "${RCLONE_REMOTE}:${REMOTE_PATH}-deleted/${d}" --tpslimit 10 \
        || log "WARN: could not purge $d"
    fi
  done < <(rclone lsf --dirs-only "${RCLONE_REMOTE}:${REMOTE_PATH}-deleted" 2>/dev/null || true)
else
  log "(dry run) skipping deleted-files pruning"
fi

log "=== sync complete ${LABEL}==="
