#!/usr/bin/env bash
#
# Back up the Infisical database.
#
# This is not optional. Once secrets live in Infisical, losing this Postgres
# means losing every credential for every stack at once. Set the timer up
# BEFORE you migrate anything real into it.
#
#   ./scripts/infisical-backup.sh
#
# Restore:
#   gunzip -c infisical-YYYYMMDD.sql.gz | docker exec -i infisical_postgres \
#     psql -U infisical -d infisical

set -euo pipefail

CONTAINER="${CONTAINER:-infisical_postgres}"
DB_USER="${DB_USER:-infisical}"
DB_NAME="${DB_NAME:-infisical}"
DEST="${DEST:-/srv/backups/infisical}"
KEEP_DAYS="${KEEP_DAYS:-30}"

mkdir -p "$DEST"

docker ps --format '{{.Names}}' | grep -qx "$CONTAINER" || {
  echo "ERROR: $CONTAINER is not running" >&2
  exit 1
}

out="$DEST/infisical-$(date +%Y%m%d-%H%M).sql.gz"
docker exec -t "$CONTAINER" \
  pg_dump --clean --if-exists -U "$DB_USER" "$DB_NAME" \
  | gzip > "$out.tmp"
mv "$out.tmp" "$out"

# A dump that restores is the only kind that counts. This catches truncation
# and gzip corruption, not logical corruption - test a real restore quarterly.
gunzip -t "$out"
size=$(stat -c%s "$out")
[[ "$size" -gt 1024 ]] || { echo "ERROR: dump is suspiciously small ($size bytes)" >&2; exit 1; }

find "$DEST" -name 'infisical-*.sql.gz' -mtime "+$KEEP_DAYS" -delete

echo "ok: $out ($size bytes)"

# The ENCRYPTION_KEY in stacks/infisical/.env is NOT in this dump, and the
# dump is useless without it. Keep that key in your password manager.
