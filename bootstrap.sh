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
