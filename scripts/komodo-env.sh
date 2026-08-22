#!/usr/bin/env bash
#
# Render one stack's secrets from Infisical for a Komodo deploy, then take them
# away again.
#
#   scripts/komodo-env.sh render beszel     # Komodo Stack -> pre_deploy
#   scripts/komodo-env.sh clean  beszel     # Komodo Stack -> post_deploy
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS
# ---------------------------------------------------------------------------
#
# scripts/deploy.sh injects secrets as process environment via `infisical run`
# and never writes them anywhere. Komodo cannot do that: its Periphery agent
# runs `docker compose up -d` itself, unwrapped, so the values have to reach
# compose through a file.
#
# This script is the smallest thing that makes Komodo a CONSUMER of Infisical
# rather than a competitor to it. Komodo's own `environment` field stays empty,
# its Variables/Secrets store stays unused, and Infisical remains the only
# place a value is stored. See docs/komodo.md.
#
# ---------------------------------------------------------------------------
# WHERE THE FILE LIVES, AND WHY IT IS NOT A REAL FILE IN THE STACK DIRECTORY
# ---------------------------------------------------------------------------
#
# The rendered file lives in tmpfs (/dev/shm). The stack directory gets a
# SYMLINK to it named `.env`, which compose picks up automatically.
#
# Komodo runs post_deploy only `if res.deployed` - a compose up that FAILS
# skips cleanup entirely (bin/periphery/src/api/compose.rs). So cleanup cannot
# be the only thing standing between a broken deploy and plaintext at rest.
# On tmpfs, a skipped cleanup is bounded by the next deploy or the next reboot,
# and nothing is ever written to the NVMe.
#
# `clean` removes the tmpfs file and leaves the symlink dangling. That state
# was tested rather than assumed:
#
#   - `docker compose config`, `ps`, `logs`, `down` all still work in the stack
#     directory. A dangling .env resolves every variable to empty and exits 0,
#     which is harmless here because every injected variable carries a
#     `${VAR:-}` default (docs/decisions.md#required-variables...).
#   - deploy.sh's `[[ -f "$STACK_DIR/.env" ]]` guard reads a dangling symlink
#     as ABSENT, because -f follows symlinks. The guard therefore stays quiet
#     in normal operation and fires loudly on exactly the case worth catching:
#     a LIVE leftover from a Komodo deploy that failed.
#
# So the existing guard rail becomes the leftover detector for free. Do not
# "fix" it to use -e.
#
# ---------------------------------------------------------------------------
# QUOTING - THE PART THAT WILL BITE IF IT IS CHANGED
# ---------------------------------------------------------------------------
#
# Compose interpolates the .env file. A bcrypt hash written unquoted -
#
#     AUTH_PASSWORD_HASH=$2b$12$KIXQ0abcdef...
#
# - silently loses everything from the third `$` onward, because `$KIXQ0abcdef`
# is read as an unset variable and expands to nothing. Tested: the value
# arrives as `$2b$12` with no warning and no error. That is the homelable
# lockout reached by a different road - the "no $$ escaping needed" note in
# docs/homelable.md is true for `infisical run` and FALSE the moment a file is
# in the path.
#
# Values are therefore rendered here, from `infisical export --format=json`,
# double-quoted with \ " and $ backslash-escaped. The CLI's own dotenv writer
# is deliberately not trusted with this.
#
# Single quotes were rejected: dotenv single-quoting has no escape sequence, so
# a value containing an apostrophe cannot be represented at all. Double quotes
# with backslash escapes round-trip $, ', ", \, backticks, #, =, leading and
# trailing spaces, and embedded newlines - all verified against
# `docker compose config`.
#
# ---------------------------------------------------------------------------
# WHAT THIS SCRIPT NEEDS TO EXIST ON THE HOST
# ---------------------------------------------------------------------------
#
# It runs as the Komodo Periphery user, NOT as brent, so `~/.infisical-identity`
# and `.bashrc` are not in the picture. Periphery must be the systemd binary
# install rather than the container, because a containerised agent would run
# this inside its own filesystem where the infisical CLI does not exist.
#
# Credentials come from $KOMODO_INFISICAL_IDENTITY (default
# /etc/komodo/infisical-identity, 0600, root-owned) - same three variables as
# ~/.infisical-identity, but a SEPARATE machine identity so it can be revoked
# without locking you out of deploy.sh. See docs/komodo.md#periphery.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFISICAL_ENV="${INFISICAL_ENV:-prod}"

# tmpfs. /dev/shm is tmpfs on Ubuntu by default and is not persisted.
TMPFS_DIR="${KOMODO_ENV_DIR:-/dev/shm/komodo-env}"
IDENTITY_FILE="${KOMODO_INFISICAL_IDENTITY:-/etc/komodo/infisical-identity}"

usage() {
  echo "usage: $0 {render|clean} <stack>"
  echo
  echo "  render   fetch /<stack> from infisical into tmpfs and link it in"
  echo "  clean    remove the tmpfs file, leaving the symlink dangling"
  echo
  echo "Wired into a Komodo Stack as pre_deploy / post_deploy."
  echo "Manual deploys do not use this - see scripts/deploy.sh."
  exit 1
}

MODE="${1:-}"
STACK="${2:-}"
[[ "$MODE" =~ ^(render|clean)$ ]] || usage
[[ -n "$STACK" ]] || usage

STACK_DIR="$REPO_ROOT/stacks/$STACK"
[[ -d "$STACK_DIR" ]] || { echo "ERROR: no such stack: $STACK" >&2; exit 1; }

if [[ "$STACK" == "infisical" ]]; then
  echo "ERROR: infisical cannot fetch its own secrets. It is not a Komodo stack." >&2
  exit 1
fi

ENV_LINK="$STACK_DIR/.env"
ENV_FILE="$TMPFS_DIR/$STACK.env"

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
#
# rm, not shred. The file is on tmpfs, which has no stable backing store to
# overwrite - shred here would be theatre, and on a copy-on-write or compressed
# filesystem it would be theatre with a performance cost. The symlink is left
# in place on purpose; see the header.

if [[ "$MODE" == "clean" ]]; then
  rm -f "$ENV_FILE"
  echo "komodo-env: cleared $ENV_FILE (symlink left dangling by design)"
  exit 0
fi

# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------

# Refuse to touch a REAL .env. If one exists, someone has fallen back to the
# old workflow and deploy.sh would already be refusing to run - clobbering it
# here would hide that rather than fix it.
if [[ -f "$ENV_LINK" && ! -L "$ENV_LINK" ]]; then
  echo "ERROR: $ENV_LINK is a real file, not this script's symlink." >&2
  echo "Secrets belong in Infisical. Move it there and delete the file." >&2
  exit 1
fi

command -v infisical >/dev/null || {
  echo "ERROR: infisical CLI not found in PATH for the periphery user." >&2
  echo "Periphery must be the systemd install, not the container. See docs/komodo.md" >&2
  exit 1
}

# Credentials. Already-exported values win, so an EnvironmentFile= on the
# periphery unit is equally valid and this file becomes optional.
if [[ -z "${INFISICAL_PROJECT_ID:-}" && -r "$IDENTITY_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$IDENTITY_FILE"
fi

if [[ -z "${INFISICAL_PROJECT_ID:-}" ]]; then
  echo "ERROR: INFISICAL_PROJECT_ID is not set and $IDENTITY_FILE is unreadable." >&2
  echo "See docs/komodo.md#periphery" >&2
  exit 1
fi

# The same required-variable table deploy.sh enforces, read through the flag
# bootstrap.sh already uses. Deliberately NOT a second copy: a Komodo deploy
# that skipped this check would start containers with blank secrets and no
# complaint, which is the exact failure deploy.sh exists to prevent.
set +e
REQUIRED="$("$REPO_ROOT/scripts/deploy.sh" --required-vars "$STACK")"
rc=$?
set -e
if (( rc == 2 )); then
  echo "ERROR: stack '$STACK' has no case in required_vars() in scripts/deploy.sh." >&2
  echo "Add one. An empty list is correct for a stack with no secrets." >&2
  exit 1
elif (( rc != 0 )); then
  echo "ERROR: could not read required vars for '$STACK' from deploy.sh." >&2
  exit 1
fi

mkdir -p "$TMPFS_DIR"
chmod 700 "$TMPFS_DIR"
umask 077

# Fetch and render in one pipeline: the JSON never touches a filesystem, and
# the values never appear in argv (where `ps` would show them). Only the NAMES
# of missing variables are ever printed.
tmp="$(mktemp "$TMPFS_DIR/.$STACK.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

if ! infisical export \
      --projectId="$INFISICAL_PROJECT_ID" \
      --env="$INFISICAL_ENV" \
      --path="/$STACK" \
      --format=json \
    | REQUIRED="$REQUIRED" STACK="$STACK" INFISICAL_ENV="$INFISICAL_ENV" \
      python3 -c '
import json, os, sys

raw = json.load(sys.stdin)

# Two shapes have shipped: a flat {"KEY": "value"} object, and a list of
# {"key": ..., "value": ...} records. Accept either rather than pinning a CLI
# version this repo does not otherwise care about.
if isinstance(raw, dict):
    secrets = {str(k): "" if v is None else str(v) for k, v in raw.items()}
elif isinstance(raw, list):
    secrets = {}
    for item in raw:
        k = item.get("key") or item.get("secretKey")
        v = item.get("value") or item.get("secretValue") or ""
        if k:
            secrets[str(k)] = str(v)
else:
    sys.exit("komodo-env: unrecognised JSON from infisical export")

required = os.environ["REQUIRED"].split()
missing = [k for k in required if not secrets.get(k)]
if missing:
    sys.stderr.write(
        "ERROR: infisical returned no value for: %s\n"
        "Looked in infisical:%s at path /%s.\n"
        "Either the key is missing there or the machine identity cannot read it.\n"
        % (" ".join(missing), os.environ["INFISICAL_ENV"], os.environ["STACK"])
    )
    sys.exit(1)


def q(v):
    # Order matters: backslash first, or the escapes we add get re-escaped.
    return v.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$")


out = ["# Rendered by scripts/komodo-env.sh. Ephemeral, tmpfs, do not edit.\n"]
for k in sorted(secrets):
    out.append("%s=\"%s\"\n" % (k, q(secrets[k])))
sys.stdout.write("".join(out))
' > "$tmp"
then
  echo "ERROR: rendering secrets for '$STACK' failed - nothing was written." >&2
  exit 1
fi

chmod 600 "$tmp"
mv -f "$tmp" "$ENV_FILE"
trap - EXIT

# Replace whatever is at .env with our symlink. Komodo writes its own (empty)
# env file into the run directory at step 2 of the deploy, BEFORE pre_deploy at
# step 5, so this runs second and wins - but it may have replaced the symlink
# with a regular file in the process, hence rm -f rather than a test.
rm -f "$ENV_LINK"
ln -s "$ENV_FILE" "$ENV_LINK"

echo "komodo-env: rendered $(grep -c '^[A-Za-z_]' "$ENV_FILE") value(s) for '$STACK'" \
     "from infisical:$INFISICAL_ENV/$STACK -> $ENV_FILE"
