#!/usr/bin/env bash
#
# Deploy a stack with its secrets injected from Infisical.
#
#   ./scripts/deploy.sh caddy
#   ./scripts/deploy.sh immich
#   ./scripts/deploy.sh immich --dry-run     # print resolved config, change nothing
#
# Required secrets are checked HERE, in required_vars() below, and not by
# `${VAR:?}` guards inside the compose files. Compose parses the whole file for
# every subcommand, so guards in the file made `docker compose down` - and
# `logs`, and `ps` - fail in a stack directory with "required variable X is
# missing a value", which reads like the command needs an argument. Keeping the
# check in the script keeps the fail-fast deploy and gives back plain compose.
#
# The tradeoff: `docker compose up -d` run by hand in a stack directory will now
# start containers with blank secrets instead of refusing. Deploy through this
# script. See docs/decisions.md#required-variables-are-checked-in-deploysh.
#
# Secrets arrive as environment variables and are interpolated by compose.
# Nothing is written to disk, so there is no .env to leak, stale, or forget.
#
# Infisical must be up. It is not needed for a plain reboot - running
# containers keep their environment - only for a deploy.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

usage() {
  echo "usage: $0 <stack> [--dry-run] [-- extra compose args]"
  echo
  echo "available stacks:"
  for d in "$REPO_ROOT"/stacks/*/; do
    name="$(basename "$d")"
    [[ "$name" == "infisical" ]] && continue
    echo "  $name"
  done
  echo
  echo "infisical is deployed with plain compose - see stacks/infisical/compose.yml"
  exit 1
}

# Every variable a stack cannot start correctly without. Values with a sensible
# `${VAR:-default}` in the compose file do not belong here - only the ones where
# an empty value is silently wrong, which in practice means the secrets.
#
# A stack with no secrets gets an explicit empty entry rather than being left
# out, so that a missing case is a mistake rather than a blank cheque.
# bootstrap.sh check 6c fails if a stack directory has no case here.
required_vars() {
  case "$1" in
    # DOMAIN is duplicated from /caddy - deploy.sh reads one Infisical path
    # per stack. KEY and TOKEN are minted by the hub itself, so they cannot
    # exist before its first run: the hub is started once without this script,
    # on purpose. See docs/beszel.md#first-deploy.
    #
    # Named KEY and TOKEN, not BESZEL_*, so that bootstrap.sh check 6d can
    # match them against the agent's environment - it compares these names
    # verbatim and skips what it cannot find.
    beszel)        echo "DOMAIN KEY TOKEN" ;;
    caddy)         echo "CF_API_TOKEN ACME_EMAIL DOMAIN" ;;
    frigate)       echo "FRIGATE_RTSP_USER FRIGATE_RTSP_PASSWORD FRIGATE_MQTT_USER FRIGATE_MQTT_PASSWORD" ;;
    homeassistant) echo "" ;;   # no secrets - HA keeps its own in .storage
    immich)        echo "DB_USERNAME DB_PASSWORD" ;;
    mosquitto)     echo "MQTT_USER MQTT_PASSWORD" ;;
    *)             echo "__NO_ENTRY__" ;;
  esac
}

# bootstrap.sh reads the table above through this, rather than keeping a second
# copy of it. Prints the list and exits; deploys nothing.
if [[ "${1:-}" == "--required-vars" ]]; then
  [[ -n "${2:-}" ]] || { echo "usage: $0 --required-vars <stack>" >&2; exit 1; }
  out="$(required_vars "$2")"
  [[ "$out" == "__NO_ENTRY__" ]] && exit 2
  echo "$out"
  exit 0
fi

STACK="${1:-}"
[[ -z "$STACK" ]] && usage
shift

STACK_DIR="$REPO_ROOT/stacks/$STACK"
[[ -d "$STACK_DIR" ]] || { echo "no such stack: $STACK"; usage; }

if [[ "$STACK" == "infisical" ]]; then
  echo "infisical cannot fetch its own secrets. Deploy it directly:"
  echo "  cd stacks/infisical && docker compose up -d"
  exit 1
fi

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=true; shift; fi
[[ "${1:-}" == "--" ]] && shift

command -v infisical >/dev/null || {
  echo "infisical cli not found. See docs/secrets.md" >&2
  exit 1
}

# The CLI needs to know which project to read. Passed explicitly rather than
# relying on a .infisical.json, because we cd into the stack directory below
# and cwd-based project discovery is one more thing that can silently drift.
if [[ -z "${INFISICAL_PROJECT_ID:-}" ]]; then
  echo "ERROR: INFISICAL_PROJECT_ID is not set." >&2
  echo "Add it to ~/.infisical-identity - see docs/secrets.md" >&2
  exit 1
fi

# Guard rail: a .env here means someone fell back to the old workflow and the
# repo has quietly stopped being the source of truth. Fail loudly.
if [[ -f "$STACK_DIR/.env" ]]; then
  echo "ERROR: $STACK_DIR/.env exists." >&2
  echo "Secrets belong in Infisical, not on disk. Move them there and delete the file." >&2
  exit 1
fi

DEPLOY_REQUIRED_VARS="$(required_vars "$STACK")"
if [[ "$DEPLOY_REQUIRED_VARS" == "__NO_ENTRY__" ]]; then
  echo "ERROR: stack '$STACK' has no case in required_vars() in this script." >&2
  echo "Add one. An empty list is correct for a stack with no secrets." >&2
  exit 1
fi
export DEPLOY_REQUIRED_VARS STACK INFISICAL_ENV

# The check has to run inside `infisical run`, because that is the only process
# that ever sees the values - they are never written to disk. `${!v}` is an
# indirect expansion: the name is in $v, so this reads the variable it names.
CHECK_VARS='
  missing=()
  for v in $DEPLOY_REQUIRED_VARS; do
    [[ -n "${!v:-}" ]] || missing+=("$v")
  done
  if (( ${#missing[@]} )); then
    echo "ERROR: infisical returned no value for: ${missing[*]}" >&2
    echo "Looked in infisical:$INFISICAL_ENV at path /$STACK." >&2
    echo "Either the key is missing there or the machine identity cannot read it." >&2
    exit 1
  fi
'

cd "$STACK_DIR"

if $DRY_RUN; then
  echo "--- resolved config for '$STACK' (secrets redacted by compose) ---"
  exec infisical run --projectId="$INFISICAL_PROJECT_ID" \
    --env="$INFISICAL_ENV" --path="/$STACK" -- \
    bash -c "set -euo pipefail; $CHECK_VARS"' exec docker compose config'
fi

echo "deploying '$STACK' with secrets from infisical:$INFISICAL_ENV/$STACK"
infisical run --projectId="$INFISICAL_PROJECT_ID" \
  --env="$INFISICAL_ENV" --path="/$STACK" -- \
  bash -c "set -euo pipefail; $CHECK_VARS"' exec docker compose "$@"' \
  _ up -d --remove-orphans "$@"

# Plain compose from here on. With the guards out of the compose files this no
# longer needs the injected environment - it was previously wrapped in
# `infisical run` only so that parsing the file would not fail.
echo
docker compose ps
