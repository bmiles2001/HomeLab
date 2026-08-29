#!/usr/bin/env bash
#
# Point latest/latest.sav at the newest save the dedicated server has written,
# so the Interactive Map has one stable URL to load.
#
# THIS IS NOT A HOST SCRIPT. It runs inside the satisfactory stack as the
# `saves-updater` container and everything it needs is two directories the
# stack already mounts. An earlier version was a systemd timer on forge, which
# bought a `sudo install` and a `daemon-reload` on every edit and nothing else -
# see docs/decisions.md#amendment-the-updater-belongs-in-the-stack.
#
# NOTHING HERE WRITES INTO THE SAVE DIRECTORY. saved/ is mounted read-only, and
# the only thing this creates is a symlink inside latest/, a directory of its
# own.
#
# Usage:
#   bash latest-save.sh            # one pass, then exit
#   bash latest-save.sh --loop     # a pass every INTERVAL seconds, forever
#   bash latest-save.sh --dry-run  # change nothing, print the decision
#
# Invoked as `bash <path>` rather than executed directly, on purpose: the repo
# is authored on Windows, where git has core.filemode=false, so a new file is
# committed 100644 no matter what mode it has locally. Depending on the execute
# bit here would work on the machine it was written on and nowhere else.

set -euo pipefail

# ---------------------------------------------------------------- config ---
# Container paths. These are mounted as SIBLINGS deliberately - see the volumes
# block in ../compose.yml for why the link has to be relative.
SAVE_ROOT="${SAVE_ROOT:-/saves/saved}"
LATEST_DIR="${LATEST_DIR:-/saves/latest}"
LINK_NAME="${LINK_NAME:-latest.sav}"

# Not every .sav under there is a save. The server keeps its own settings
# beside them as ServerSettings.<port>.sav and rewrites that file whenever a
# setting changes, which would periodically make it the newest .sav in the tree
# and hand the map something it cannot parse.
#
# <Session>_continue.sav and <Session>_autosave_N_continue.sav ARE real saves
# and are deliberately left in.
EXCLUDE_GLOB="${EXCLUDE_GLOB:-ServerSettings*.sav}"

# Ignore a save younger than this. Belt-and-braces rather than the main
# protection: autosaves rotate across AUTOSAVENUM slots - five by default - so
# the newest file is the one that will not be rewritten for another four
# intervals, roughly 25 minutes at the 5-minute default.
SETTLE_SECONDS="${SETTLE_SECONDS:-15}"

INTERVAL="${INTERVAL:-60}"

# Touched only after a pass that actually succeeded, which is what makes
# healthcheck.sh able to tell a stuck loop from a working one. A loop that dies
# quietly inside an otherwise healthy container is the failure mode that made
# this a separate container instead of a background job inside the web server.
HEARTBEAT="${HEARTBEAT:-/tmp/heartbeat}"
# ---------------------------------------------------------------------------

DRY=false
LOOP=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=true ;;
    --loop)    LOOP=true ;;
    *) printf 'unknown argument: %s\n' "$arg" >&2; exit 2 ;;
  esac
done

log() { printf '%s  %s\n' "$(date -Is)" "$*"; }

update_once() {
  local newest age link current tmp

  [[ -d "$SAVE_ROOT" ]] || { log "ERROR: save directory not found: $SAVE_ROOT"; return 1; }

  # `sort -n | tail -1` rather than `sort -nr | head -1`: head closes the pipe
  # early, sort takes SIGPIPE, and under `set -o pipefail` that is a non-zero
  # exit for a command that did nothing wrong. tail reads to the end.
  #
  # -printf '%T@' is the mtime as a float, so this still orders correctly for
  # two saves written in the same second - which rotation does do.
  newest="$(find "$SAVE_ROOT" -type f -name '*.sav' ! -name "$EXCLUDE_GLOB" \
                 -printf '%T@\t%p\n' 2>/dev/null | sort -n | tail -1 | cut -f2-)"

  if [[ -z "$newest" ]]; then
    # Not an error. A freshly claimed server has no save until the first
    # autosave fires, and failing here would fill the log every minute.
    log "no .sav files under $SAVE_ROOT yet - nothing to do"
    return 0
  fi

  # `age >= 0` matters. A save with an mtime in the FUTURE - a clock that
  # stepped backwards, a file restored from elsewhere - gives a negative age,
  # and without this guard it would look permanently mid-write and never be
  # published at all.
  age=$(( $(date +%s) - $(stat -c %Y "$newest") ))
  if (( age >= 0 && age < SETTLE_SECONDS )); then
    log "newest save is ${age}s old, still settling - will pick it up next pass"
    return 0
  fi

  link="$LATEST_DIR/$LINK_NAME"
  current="$(readlink -f "$link" 2>/dev/null || true)"
  [[ "$current" == "$newest" ]] && return 0   # already right; stay quiet

  if $DRY; then
    log "(dry run) would point $link at $newest"
    return 0
  fi

  mkdir -p "$LATEST_DIR"

  # The link is RELATIVE on purpose, and the payoff is that it is valid in two
  # namespaces at once: ../saved/<...> resolves under /saves in this container
  # AND under /srv/satisfactory on the host, because latest/ and saved/ are
  # siblings in both. An absolute target would be correct in exactly one.
  tmp="$LATEST_DIR/.$LINK_NAME.tmp"
  ln -sfr "$newest" "$tmp" || return 1

  # mv -T over the existing symlink is the atomic swap. WITHOUT -T, mv would
  # follow the existing link and try to write THROUGH it into the save
  # directory, which is the one thing this must never do.
  mv -Tf "$tmp" "$link" || return 1

  log "latest.sav -> $newest"
}

if ! $LOOP; then
  update_once
  exit $?
fi

# `sleep &` plus `wait` rather than a bare `sleep`: bash runs a trap only
# between commands, so a plain sleep would swallow SIGTERM for up to INTERVAL
# seconds and every `docker stop` would end in a 10-second SIGKILL.
trap 'log "stopping"; exit 0' TERM INT

log "watching $SAVE_ROOT every ${INTERVAL}s"
while true; do
  if update_once; then
    touch "$HEARTBEAT"
  fi
  sleep "$INTERVAL" &
  wait $!
done
