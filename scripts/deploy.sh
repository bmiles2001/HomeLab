#!/usr/bin/env bash
#
# Deploy a stack with its secrets injected from Infisical.
#
#   ./scripts/deploy.sh caddy
#   ./scripts/deploy.sh immich
#   ./scripts/deploy.sh immich --dry-run     # print resolved config, change nothing
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

# Guard rail: a .env here means someone fell back to the old workflow and the
# repo has quietly stopped being the source of truth. Fail loudly.
if [[ -f "$STACK_DIR/.env" ]]; then
  echo "ERROR: $STACK_DIR/.env exists." >&2
  echo "Secrets belong in Infisical, not on disk. Move them there and delete the file." >&2
  exit 1
fi

cd "$STACK_DIR"

if $DRY_RUN; then
  echo "--- resolved config for '$STACK' (secrets redacted by compose) ---"
  exec infisical run --env="$INFISICAL_ENV" --path="/$STACK" -- docker compose config
fi

echo "deploying '$STACK' with secrets from infisical:$INFISICAL_ENV/$STACK"
infisical run --env="$INFISICAL_ENV" --path="/$STACK" -- \
  docker compose up -d --remove-orphans "$@"

echo
docker compose ps
