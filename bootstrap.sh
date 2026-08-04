#!/usr/bin/env bash
#
# Run once on a fresh box, then again any time you're unsure.
# Everything here is idempotent.
#
#   ./bootstrap.sh
#
# What it does NOT do: deploy anything, or touch secrets. See scripts/deploy.sh.

set -euo pipefail

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
fail() { printf '  \033[31mfail\033[0m  %s\n' "$*"; exit 1; }

echo
echo "home containers - bootstrap (forge / ubuntu / docker)"
echo

# --- 1. docker present ------------------------------------------------------
command -v docker >/dev/null || fail "docker not found. See docs/forge-session-runbook.md phase 2."
ok "docker $(docker --version | awk '{print $3}' | tr -d ,)"

docker info >/dev/null 2>&1 \
  || fail "cannot talk to the docker daemon. Are you in the 'docker' group? Try: newgrp docker"
ok "docker daemon reachable as $(id -un)"

# --- 2. compose v2 ----------------------------------------------------------
if docker compose version >/dev/null 2>&1; then
  ok "docker compose $(docker compose version --short 2>/dev/null)"
else
  fail "docker compose v2 missing. Install docker-compose-plugin from Docker's own repo."
fi

# --- 3. the shared proxy network -------------------------------------------
# Created out of band and declared `external: true` in every stack, so no
# single stack owns it and tearing one down cannot delete it.
#
# The subnet is pinned rather than left to Docker's address pool, because
# IMMICH_TRUSTED_PROXIES has to name it exactly - and Immich's login rate
# limiting silently stops working if the two disagree. Docker allocates from
# 172.17.0.0/16 upward in creation order, so a rebuild that happens to create
# networks in a different order would hand `proxy` a different range and
# nothing would announce it.
#
# 172.18.0.0/16 is what this network already has; pinning it makes a future
# rebuild match rather than drift. See docs/public-access.md.
PROXY_SUBNET="172.18.0.0/16"

if docker network inspect proxy >/dev/null 2>&1; then
  actual="$(docker network inspect proxy -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}')"
  if [[ "$actual" == "$PROXY_SUBNET" ]]; then
    ok "network 'proxy' exists ($actual)"
  else
    # Not fatal - it works fine - but IMMICH_TRUSTED_PROXIES is now wrong.
    warn "network 'proxy' is $actual, expected $PROXY_SUBNET"
    warn "set IMMICH_TRUSTED_PROXIES=$actual in Infisical, or recreate the network"
  fi
else
  docker network create --subnet "$PROXY_SUBNET" proxy >/dev/null
  ok "network 'proxy' created ($PROXY_SUBNET)"
fi

# --- 3b. the iot network ----------------------------------------------------
# Carries MQTT between mosquitto, frigate and homeassistant, and nothing else.
# Separate from `proxy` because MQTT has a flat permission model - any client
# that authenticates can subscribe to `#` and read every message on the broker,
# including camera events. Three containers is a smaller blast radius than
# every container in the house.
#
# `--internal` means Docker adds no route off the box for this network.
# mosquitto is on `iot` alone and therefore has no path to the internet at all,
# which is correct for a broker that only ever talks to two local clients.
# frigate and homeassistant are also on `proxy`, so they keep their default
# route through it and are unaffected.
# The subnet is deliberately NOT pinned, unlike `proxy`. Pinning proxy is
# load-bearing - IMMICH_TRUSTED_PROXIES and Home Assistant's trusted_proxies
# both name that range literally. Nothing names this one, so pinning it bought
# no safety and cost a collision: an earlier version asked for 172.19.0.0/16,
# which one of the stacks' default networks already held, and Docker refuses
# with "Pool overlaps with other one on this address space". Let Docker choose.
if docker network inspect iot >/dev/null 2>&1; then
  ok "network 'iot' exists ($(docker network inspect iot -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'))"
else
  docker network create --internal iot >/dev/null
  ok "network 'iot' created ($(docker network inspect iot -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'), internal)"
fi

# --- 4. data directories ----------------------------------------------------
for d in /srv/immich/data /srv/caddy /srv/infisical /srv/backups/infisical \
         /srv/frigate/media /srv/frigate/models /srv/homeassistant/config \
         /srv/unifi/config; do
  if [[ ! -d "$d" ]]; then
    sudo mkdir -p "$d"
    sudo chown "$(id -u):$(id -g)" "$d"
  fi
  ok "directory $d"
done

# Home Assistant's configuration.yaml is mounted read-only from the repo and
# `!include`s these three. HA cannot create them itself because it cannot write
# to the file that names them, and a missing include is a hard startup failure,
# not a warning. Creating them empty here is the whole fix.
for f in automations.yaml scripts.yaml scenes.yaml; do
  if [[ ! -e "/srv/homeassistant/config/$f" ]]; then
    printf '[]\n' | sudo tee "/srv/homeassistant/config/$f" >/dev/null
    sudo chown "$(id -u):$(id -g)" "/srv/homeassistant/config/$f"
  fi
  ok "home assistant include $f"
done

# Frigate refuses to start without a detector model, and the error in the log
# is about a missing path rather than about the thing you forgot to do.
if compgen -G "/srv/frigate/models/*.onnx" >/dev/null; then
  ok "frigate detector model present"
else
  warn "no .onnx model in /srv/frigate/models - frigate will not start"
  echo "        build it once: see docs/frigate.md#step-1-build-the-detector-model"
fi

# --- 5. firewall sanity -----------------------------------------------------
# Docker writes its own iptables rules ahead of UFW's, so a published port is
# reachable regardless of what `ufw status` claims. ufw-docker stitches UFW
# into the DOCKER-USER chain so the rules actually apply.
if command -v ufw >/dev/null; then
  if sudo ufw status | grep -q '^Status: active'; then
    ok "ufw active"
  else
    warn "ufw is installed but inactive"
  fi
  if sudo iptables -S DOCKER-USER 2>/dev/null | grep -q 'ufw-user-forward'; then
    ok "ufw-docker installed (DOCKER-USER -> ufw)"
  else
    warn "ufw-docker NOT installed - published ports bypass ufw entirely."
    echo "        sudo wget -O /usr/local/bin/ufw-docker \\"
    echo "          https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker"
    echo "        sudo chmod +x /usr/local/bin/ufw-docker && sudo ufw-docker install"
  fi
else
  warn "ufw not installed"
fi

# --- 6. only caddy should publish ports -------------------------------------
# The architectural rule, checked rather than trusted. Apps join `proxy` and
# are reached by container name; anything else with a host port is a mistake.
#
# `unifi` is the one allowed exception, and it is named here rather than
# quietly tolerated: switches and APs speak raw UDP to the controller, so its
# device-facing ports cannot go through Caddy. Its web UI still does. See
# docs/decisions.md#unifi-publishes-ports-and-has-to.
#
# Note this only catches ports published on all interfaces. unifi's 8080 and
# 3478 are bound to the LAN address specifically and never matched here in the
# first place; 10001/udp is, and is what the allow-list is for.
ALLOWED_PUBLISHERS='caddy|unifi'
strays=$(docker ps --format '{{.Names}}|{{.Ports}}' \
  | grep -E '0\.0\.0\.0:|:::' \
  | grep -vE "^($ALLOWED_PUBLISHERS)\|" | cut -d'|' -f1 || true)
if [[ -n "$strays" ]]; then
  warn "containers publishing ports other than caddy:"
  echo "$strays" | sed 's/^/        /'
else
  ok "no stray published ports"
fi

# --- 6b. no anonymous volumes -----------------------------------------------
# An image can declare `VOLUME /some/path` in its Dockerfile. If nothing is
# mounted there, Docker still creates a volume - an anonymous one, named with
# 64 hex characters, belonging to no stack and described by no file in this
# repo. It is created fresh on every container recreate, so the old one is
# orphaned rather than reused, and `docker volume ls` slowly fills with
# identical-looking garbage that nobody dares delete.
#
# Two were found this way: eclipse-mosquitto declares /mosquitto/log, and the
# mongo image declares /data/configdb. Both are now mounted by name in their
# compose files even though both stay empty.
#
# The rule this enforces: every volume on this box is named, and every name
# traces back to a compose file. If this warns, find which image declared it
# with `docker inspect <container>` and give it an explicit mount.
anon=$(docker volume ls -q 2>/dev/null | grep -E '^[0-9a-f]{64}$' || true)
if [[ -n "$anon" ]]; then
  warn "anonymous volumes present - some image has an unmounted VOLUME:"
  echo "$anon" | sed 's/^/        /'
  echo "        find the owner:  docker ps -q | xargs docker inspect \\"
  echo "                           --format '{{.Name}} {{range .Mounts}}{{.Name}} {{end}}'"
else
  ok "no anonymous volumes"
fi

# --- 6c. required variables live in deploy.sh, not in the compose files ------
# A `${VAR:?...}` guard inside a compose file looks like a safety feature and
# behaves like a trap. Compose parses the entire file for every subcommand, so
# the guard fires on `down`, `logs` and `ps` too - none of which would use the
# value - and the error, "required variable MONGO_PASS is missing a value",
# reads like the command was typed wrong rather than run without secrets.
#
# The convention: no guards in compose files. scripts/deploy.sh has a
# required_vars() table instead, checked after injection and before `up`. That
# keeps the fail-fast deploy while leaving plain compose usable in a stack
# directory. See docs/decisions.md#required-variables-are-checked-in-deploysh.
#
# Two ways this drifts, both caught here: a guard creeping back into a compose
# file, and a new stack with no case in required_vars(), which would deploy
# with no check at all.
#
# stacks/infisical is exempt. It is the one stack deploy.sh cannot handle - it
# holds the secrets, so it cannot fetch its own - and it reads a plain .env in
# its own directory. Compose auto-loads that file for every subcommand, so its
# guards fire only when the file is genuinely missing, which is the point.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
guard_drift=""
table_drift=""
for d in "$REPO_DIR"/stacks/*/; do
  s="$(basename "$d")"
  [[ "$s" == "infisical" ]] && continue
  [[ -f "$d/compose.yml" ]] || continue
  # Match a guard in an actual value, not the words ":?" inside a comment.
  if grep -qE '^[^#]*\$\{[A-Za-z_][A-Za-z0-9_]*:\?' "$d/compose.yml"; then
    guard_drift+="        $s"$'\n'
  fi
  grep -qE "^[[:space:]]*$s\)" "$REPO_DIR/scripts/deploy.sh" \
    || table_drift+="        $s"$'\n'
done
if [[ -n "$guard_drift" ]]; then
  warn "compose files still carrying \${VAR:?} guards - plain compose will fail there:"
  printf '%s' "$guard_drift"
  echo "        move them into required_vars() in scripts/deploy.sh"
fi
if [[ -n "$table_drift" ]]; then
  warn "stacks with no case in required_vars() in scripts/deploy.sh:"
  printf '%s' "$table_drift"
  echo "        add one - an empty list is correct for a stack with no secrets"
fi
if [[ -z "$guard_drift$table_drift" ]]; then
  ok "no compose guards; every stack has a required_vars() entry"
fi

# --- 6d. nothing running on a blank secret ----------------------------------
# The compensating control for check 6c. Moving the required-variable check out
# of the compose files and into deploy.sh means `docker compose up -d`, typed by
# hand in a stack directory, no longer refuses - it starts the containers with
# empty secrets. Prevention was traded for the ability to run plain compose, so
# this is the detection that replaces it.
#
# It is not as bad as it sounds: every stack here fails CLOSED on a blank
# credential rather than open. Mongo refuses to initialise, Postgres rejects an
# empty password, Caddy cannot solve a DNS challenge, Frigate's cameras will not
# connect, and mosquitto rewrites its passwd file rather than falling back to
# anonymous. The result is a broken stack, not an exposed one.
#
# What it costs is time, because a stack that is broken for this reason looks
# exactly like a stack that is broken for any other reason. This names it.
#
# Reads the required-variable table out of deploy.sh rather than keeping a
# second copy - see `deploy.sh --required-vars`.
#
# A variable that is absent from a container is skipped, not flagged: the table
# is per stack, and MONGO_INITDB_ROOT_PASSWORD belongs to unifi-db and not to
# unifi. Only present-and-empty counts.
blank_secrets=""
for d in "$REPO_DIR"/stacks/*/; do
  s="$(basename "$d")"
  [[ "$s" == "infisical" ]] && continue
  vars="$("$REPO_DIR/scripts/deploy.sh" --required-vars "$s" 2>/dev/null)" || continue
  [[ -n "${vars// /}" ]] || continue
  # `name:` at the top of each compose file is what compose labels containers
  # with, so the project label and the directory name are the same string.
  for cid in $(docker ps -q --filter "label=com.docker.compose.project=$s" 2>/dev/null); do
    cname="$(docker inspect -f '{{.Name}}' "$cid" | sed 's|^/||')"
    cenv="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$cid")"
    for v in $vars; do
      line="$(grep -m1 "^$v=" <<<"$cenv" || true)"
      [[ -z "$line" ]] && continue          # not this service's variable
      [[ "$line" == "$v=" ]] && blank_secrets+="        $cname: $v is empty"$'\n'
    done
  done
done
if [[ -n "$blank_secrets" ]]; then
  warn "containers running with a required secret set to empty:"
  printf '%s' "$blank_secrets"
  echo "        started outside scripts/deploy.sh. Redeploy the stack to fix."
else
  ok "no container running on a blank secret"
fi

# --- 7. infisical cli -------------------------------------------------------
if command -v infisical >/dev/null; then
  ok "infisical cli $(infisical --version 2>/dev/null | head -1)"
else
  warn "infisical cli not installed - scripts/deploy.sh needs it. See docs/secrets.md"
fi

# --- 8. gpu, for immich ml and transcoding ----------------------------------
if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
  ok "nvidia: $(nvidia-smi -L | head -1)"
  if docker info 2>/dev/null | grep -qi 'nvidia'; then
    ok "nvidia container toolkit registered with docker"
  else
    warn "nvidia-smi works but the container toolkit is not registered with docker"
  fi
else
  warn "no nvidia gpu detected - immich ml will run on cpu"
fi
[[ -e /dev/dri/renderD128 ]] && ok "/dev/dri/renderD128 present (intel quicksync)" \
                             || warn "/dev/dri/renderD128 missing - no iGPU transcoding"

echo
