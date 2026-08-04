#!/usr/bin/env bash
#
# Run a docker compose command against a stack with the real secret values
# injected, for the few commands that actually need them.
#
#   ./scripts/compose.sh caddy config          # resolved config, values filled in
#   ./scripts/compose.sh immich run --rm ...    # a one-off container that needs creds
#
# WHEN YOU DO NOT NEED THIS
#
# Most of the time. `down`, `logs`, `ps`, `stop`, `start` and `restart` all work
# as plain `docker compose` in the stack directory, because no compose file in
# this repo carries `${VAR:?}` guards any more - the required-variable check
# lives in scripts/deploy.sh instead. See
# docs/decisions.md#required-variables-are-checked-in-deploysh.
#
# (It used to be the other way round: the guards were in the compose files, and
# compose parses the whole file for EVERY subcommand, so `docker compose down`
# died on "required variable MONGO_PASS is missing a value" - an error that
# reads like the command needs an argument. That is what this script was
# originally written to work around.)
#
# WHAT THIS IS NOT FOR
#
# Deploys. Use scripts/deploy.sh, which is the only path that verifies the
# secrets actually arrived. `./scripts/compose.sh <stack> up -d` will inject
# values but will not check them, and plain `docker compose up -d` in a stack
# directory will now start containers with blank passwords rather than refusing.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

usage() {
  echo "usage: $0 <stack> <compose command> [args...]"
  echo
  echo "examples:"
  echo "  $0 frigate down"
  echo "  $0 frigate logs -f"
  echo "  $0 immich ps"
  echo
  echo "available stacks:"
  for d in "$REPO_ROOT"/stacks/*/; do
    name="$(basename "$d")"
    [[ "$name" == "infisical" ]] && continue
    echo "  $name"
  done
  echo
  echo "infisical uses plain compose - it holds the secrets, so it cannot"
  echo "fetch its own. cd stacks/infisical && docker compose <command>"
  exit 1
}

STACK="${1:-}"
[[ -z "$STACK" ]] && usage
shift
[[ $# -eq 0 ]] && usage

# `compose.sh down frigate` reads more naturally than `compose.sh frigate down` and
# is the wrong way round. Say so, rather than "no such stack: down".
if [[ ! -d "$REPO_ROOT/stacks/$STACK" && -d "$REPO_ROOT/stacks/${1:-}" ]]; then
  echo "arguments are the other way round - the stack comes first:" >&2
  echo "  $0 $1 $STACK ${*:2}" >&2
  exit 1
fi

STACK_DIR="$REPO_ROOT/stacks/$STACK"
[[ -d "$STACK_DIR" ]] || { echo "no such stack: $STACK"; usage; }

if [[ "$STACK" == "infisical" ]]; then
  echo "infisical cannot fetch its own secrets. Use plain compose:"
  echo "  cd stacks/infisical && docker compose $*"
  exit 1
fi

command -v infisical >/dev/null || {
  echo "infisical cli not found. See docs/secrets.md" >&2
  exit 1
}

if [[ -z "${INFISICAL_PROJECT_ID:-}" ]]; then
  echo "ERROR: INFISICAL_PROJECT_ID is not set." >&2
  echo "Add it to ~/.infisical-identity - see docs/secrets.md" >&2
  exit 1
fi

cd "$STACK_DIR"

exec infisical run --projectId="$INFISICAL_PROJECT_ID" \
  --env="$INFISICAL_ENV" --path="/$STACK" -- \
  docker compose "$@"
