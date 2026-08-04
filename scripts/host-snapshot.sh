#!/usr/bin/env bash
#
# Snapshot the parts of forge that a host-level install could disturb, so
# "did that break anything?" is a diff rather than a feeling.
#
#   ./scripts/host-snapshot.sh before
#   ...do the risky thing...
#   ./scripts/host-snapshot.sh after
#   ./scripts/host-snapshot.sh diff
#
# Written for the UniFi OS Server install (docs/unifi-os-server.md), which
# puts podman on a Docker box and wants ports Caddy may already hold. Nothing
# here is UniFi-specific though - use it before any host change you might
# want to reverse.
#
# Snapshots land in /srv/snapshots and are NOT in git: they contain this
# machine's iptables rules and listening sockets, which is exactly the sort of
# thing that should not be pushed anywhere.

set -euo pipefail

SNAP_DIR="${SNAP_DIR:-/srv/snapshots}"
MODE="${1:-}"

usage() {
  echo "usage: $0 {before|after|diff}"
  echo
  echo "  before   capture the current state"
  echo "  after    capture it again"
  echo "  diff     show what changed between the two"
  exit 1
}

[[ "$MODE" =~ ^(before|after|diff)$ ]] || usage

mkdir -p "$SNAP_DIR"

capture() {
  local out="$SNAP_DIR/$1"
  mkdir -p "$out"

  # Listening sockets. The single most important one: if Caddy stops holding
  # :443, everything in the house behind it is down.
  ss -tulnp 2>/dev/null | sort > "$out/listening.txt" || true

  # Containers and their published ports.
  docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' \
    2>/dev/null | sort > "$out/containers.txt" || true
  docker network ls --format '{{.Name}}\t{{.Driver}}\t{{.Scope}}' \
    2>/dev/null | sort > "$out/networks.txt" || true

  # Subnets, because a second container runtime allocating ranges is how you
  # discover a collision at the worst possible moment.
  for n in $(docker network ls --format '{{.Name}}' 2>/dev/null); do
    printf '%s\t%s\n' "$n" \
      "$(docker network inspect "$n" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)"
  done | sort > "$out/subnets.txt" || true

  # Firewall. Addresses and counters stripped so an unrelated packet count
  # does not show up as a change.
  sudo iptables-save 2>/dev/null \
    | grep -vE '^#|^:[A-Z]+ [A-Z]+ \[' > "$out/iptables.txt" || true

  # Docker and podman both drive iptables. If the alternatives system flips
  # between nft and legacy underneath them, Docker's rules stop applying and
  # nothing announces it.
  update-alternatives --display iptables 2>/dev/null \
    | head -3 > "$out/iptables-alt.txt" || true

  # Routes, in case something adds a default or a bridge.
  ip -brief addr show 2>/dev/null | sort > "$out/addrs.txt" || true
  ip route show 2>/dev/null | sort > "$out/routes.txt" || true

  # Anything new and running at boot.
  systemctl list-units --type=service --state=running --no-pager --no-legend \
    2>/dev/null | awk '{print $1}' | sort > "$out/services.txt" || true

  date -Is > "$out/taken-at.txt"
  echo "snapshot '$1' written to $out"
}

case "$MODE" in
  before|after)
    capture "$MODE"
    ;;
  diff)
    for d in before after; do
      [[ -d "$SNAP_DIR/$d" ]] || { echo "no '$d' snapshot in $SNAP_DIR" >&2; exit 1; }
    done
    echo "=== $(cat "$SNAP_DIR/before/taken-at.txt") -> $(cat "$SNAP_DIR/after/taken-at.txt") ==="
    changed=0
    for f in listening containers networks subnets iptables iptables-alt addrs routes services; do
      if ! diff -q "$SNAP_DIR/before/$f.txt" "$SNAP_DIR/after/$f.txt" >/dev/null 2>&1; then
        changed=1
        echo
        echo "--- $f ---"
        diff -u "$SNAP_DIR/before/$f.txt" "$SNAP_DIR/after/$f.txt" \
          | tail -n +3 | grep -E '^[+-]' || true
      fi
    done
    echo
    if (( changed )); then
      echo "Changes found. Read them against docs/unifi-os-server.md#what-counts-as-impact"
      echo "before deciding whether this is expected or a rollback trigger."
    else
      echo "No differences. Nothing observable changed."
    fi
    ;;
esac
