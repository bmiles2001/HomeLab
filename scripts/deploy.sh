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
    # No secrets. Audiobookshelf's root account is created through its own web
    # UI on first launch, and every other value in that compose file is a path
    # or a version with a `${VAR:-default}`. Entered explicitly rather than left
    # out, so bootstrap.sh check 6c reads this as "considered and empty".
    #
    # An Infisical path /audiobookshelf still has to EXIST, holding TZ, even
    # though nothing here is required. That is not for this script - it is for
    # scripts/komodo-env.sh, whose `render` needs a path to export. See
    # docs/audiobookshelf.md#why-a-stack-with-no-secrets-still-gets-the-hooks.
    audiobookshelf) echo "" ;;
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
    # AUTH_* are listed even though the image has working defaults, and that is
    # exactly why: the default is admin/admin, so a blank value here does not
    # fail to start - it publishes a map of the network behind a credential
    # everybody already knows. DOMAIN is duplicated from /caddy to build
    # CORS_ORIGINS, the same way /beszel duplicates it for APP_URL.
    homelable)     echo "SECRET_KEY AUTH_USERNAME AUTH_PASSWORD_HASH DOMAIN" ;;
    immich)        echo "DB_USERNAME DB_PASSWORD" ;;
    # Komodo is deployed BY this script and never by itself - the same
    # bootstrapping reason infisical is excluded above, one layer up: a tool
    # cannot be the thing that redeploys itself while it is down.
    #
    # JWT_SECRET is listed because a blank one does not fail to start: Komodo
    # generates a random secret per boot instead, which silently signs out
    # every session on every restart and reads as a login bug.
    # INIT_ADMIN_* only take effect on the very first launch against an empty
    # database, but they are checked every time because the case where they
    # matter is the case where you cannot get in to fix them.
    #
    # scripts/komodo-env.sh reads this same list through --required-vars, so a
    # name added here is enforced on the Komodo deploy path too.
    komodo)        echo "KOMODO_DATABASE_USERNAME KOMODO_DATABASE_PASSWORD KOMODO_JWT_SECRET KOMODO_WEBHOOK_SECRET KOMODO_INIT_ADMIN_USERNAME KOMODO_INIT_ADMIN_PASSWORD DOMAIN" ;;
    mosquitto)     echo "MQTT_USER MQTT_PASSWORD" ;;
    # Only the two variables every gluetun provider needs. The credentials are
    # deliberately NOT listed, and that is not an oversight:
    #
    #   - which ones apply depends on VPN_TYPE. A wireguard setup has no
    #     OPENVPN_USER and an openvpn setup has no WIREGUARD_PRIVATE_KEY, so
    #     any fixed list here fails one of the two configurations.
    #   - the bar for this table is "an empty value is SILENTLY wrong". A
    #     blank wireguard key is not silent: gluetun refuses to start, says
    #     which variable is missing, and the kill switch means nothing leaks
    #     while it is down. That is the failure mode this check exists to
    #     manufacture, already provided by the app.
    #
    # VPN_SERVICE_PROVIDER and VPN_TYPE are here because a blank VPN_TYPE
    # defaults to wireguard in the compose file and a blank provider produces
    # an error naming neither.
    shelfarr)      echo "VPN_SERVICE_PROVIDER VPN_TYPE" ;;
    # No secrets. The server's admin and claim passwords are set through the
    # in-game Server Manager and stored in the game's own config under
    # /srv/satisfactory/saved - there is nothing for compose to interpolate.
    # Entered explicitly rather than left out, so bootstrap.sh check 6c reads
    # this as "considered and empty" instead of "someone forgot".
    satisfactory)  echo "" ;;
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
