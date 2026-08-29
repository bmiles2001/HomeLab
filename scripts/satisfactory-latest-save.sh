#!/usr/bin/env bash
#
# Point /srv/satisfactory/latest/latest.sav at the newest save the dedicated
# server has written, so the Interactive Map has one stable URL to load.
#
# NOTHING HERE WRITES INTO SaveGames/. The only thing this creates is a symlink,
# in a directory of its own, alongside it. The saves are the one irreplaceable
# thing on that stack and this script is read-only with respect to them.
#
# Usage:
#   ./satisfactory-latest-save.sh            # real run
#   ./satisfactory-latest-save.sh --dry-run  # change nothing, print the decision
#
# Installed to /usr/local/bin and driven by a 60s timer - see
# docs/satisfactory.md#viewing-the-save-on-the-interactive-map for why a timer
# rather than a systemd .path unit.

set -euo pipefail

# ---------------------------------------------------------------- config ---
# Searched RECURSIVELY. Upstream's own nginx example puts saves in
# .../SaveGames/server/, this repo's runbook has historically written
# .../SaveGames/, and the server creates a directory per session under there.
# Recursing means the script does not care which of those is true on the day,
# and keeps working when a new session directory appears.
SAVE_ROOT="${SAVE_ROOT:-/srv/satisfactory/saved/SaveGames}"

LATEST_DIR="${LATEST_DIR:-/srv/satisfactory/latest}"
LINK_NAME="${LINK_NAME:-latest.sav}"

# Ignore a save younger than this. The game writes the file and the next timer
# tick is at most 60s away, so the cost of skipping a half-written save is one
# tick of staleness and the benefit is never publishing a truncated file.
#
# This is belt-and-braces rather than the main protection: autosaves rotate
# across three slots, so the newest file is the one that will NOT be rewritten
# for another two intervals - roughly 15 minutes at the 5-minute default.
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"
# ---------------------------------------------------------------------------

DRY=false
[[ "${1:-}" == "--dry-run" ]] && DRY=true

log() { printf '%s\n' "$*"; }   # stdout; systemd puts it in the journal
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -d "$SAVE_ROOT" ]] || die "save directory not found: $SAVE_ROOT"

# -printf '%T@' is the mtime as a float, so this sorts correctly for saves
# written in the same second - which autosave rotation does do.
newest="$(find "$SAVE_ROOT" -type f -name '*.sav' -printf '%T@\t%p\n' 2>/dev/null \
          | sort -nr | head -1 | cut -f2-)"

if [[ -z "$newest" ]]; then
  # Not an error. A freshly claimed server has no save until the first autosave
  # fires, and failing here would just fill the journal every minute.
  log "no .sav files under $SAVE_ROOT yet - nothing to do"
  exit 0
fi

age=$(( $(date +%s) - $(stat -c %Y "$newest") ))

# `age >= 0` matters. A save with an mtime in the FUTURE - a clock that stepped
# backwards, a file restored from elsewhere - produces a negative age, and
# without this guard it would look like it is permanently still being written
# and would never be published at all.
if (( age >= 0 && age < SETTLE_SECONDS )); then
  log "newest save is ${age}s old, still settling - will pick it up next tick"
  exit 0
fi

link="$LATEST_DIR/$LINK_NAME"
current="$(readlink -f "$link" 2>/dev/null || true)"
if [[ "$current" == "$newest" ]]; then
  exit 0   # already correct; stay quiet so the journal only shows real changes
fi

if $DRY; then
  log "(dry run) would point $link at $newest"
  exit 0
fi

mkdir -p "$LATEST_DIR"

# The link is RELATIVE on purpose. The container that serves it mounts
# latest/ and saved/ as siblings under /saves, at paths that are not the
# host's - an absolute /srv/... target would dangle inside it. `ln -sr`
# computes the target relative to the link's directory, and the temp file
# lives in that same directory, so the path stays right across the rename.
tmp="$LATEST_DIR/.$LINK_NAME.tmp"
ln -sfr "$newest" "$tmp"

# mv -T over the existing symlink is the atomic swap. Without -T, mv would
# follow the existing link and try to write THROUGH it into SaveGames/, which
# is the one thing this script must never do.
mv -Tf "$tmp" "$link"

log "latest.sav -> $newest"
