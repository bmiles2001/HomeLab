# Cockpit

Host management UI for `forge` — storage, services, logs, terminal. Installed on
the host OS, not in a container.

```bash
sudo apt install -t resolute-backports cockpit cockpit-storaged
```

Reached at `https://cockpit.brent-miles.com` from the LAN, through Caddy.

---

## Why it doesn't break the "no UI competes with git" rule

[decisions.md](decisions.md#git-is-the-source-of-truth-with-no-ui-allowed-to-compete)
rules out any UI that keeps its own store of record. Cockpit qualifies as a *view*
rather than a store: it has no database and no config of its own to drift. It reads
and writes systemd units, LVM metadata, and the journal directly — the actual system
state, not a copy of it.

The caveat is real though: **changes made through Cockpit are host state, and host
state is not in this repo.** Creating a logical volume in the Storage page is exactly
as invisible to git as running `lvcreate` over SSH. The repo covers containers;
`bootstrap.sh` and the docs cover the host. Anything done in Cockpit that matters
belongs written down the same way the storage expansion was — see
[storage-expansion.md](storage-expansion.md).

Cockpit is also the first thing here that publishes a host port without being Caddy.
It doesn't violate README rule 2 (that rule is about containers, and `bootstrap.sh`'s
stray-port check only inspects `docker ps`), but it is the first exception, so it is
written down rather than noticed later.

---

## Routing

Almost nothing was needed. The wildcard `*.brent-miles.com` A record already points
at `10.0.0.4`, the wildcard certificate already covers every subdomain, and the
LAN-only zone's `@notlocal` guard already drops non-LAN traffic before any `handle`
below it runs. Cockpit inherits all three for free.

Two things did have to change.

### 1. Caddyfile — a handle block in the LAN-only zone

Added to `stacks/caddy/Caddyfile`, inside the `*.{env.DOMAIN}` block:

```caddy
	# --- cockpit.<domain> - Cockpit (host OS, not a container) -------------
	# The only upstream in this file that is not a container. Cockpit is a
	# systemd service on forge itself, so it cannot be reached by container
	# name; `host.docker.internal` is mapped to the proxy network's gateway
	# by the extra_hosts entry in compose.yml.
	#
	# Spoken to over HTTPS with verification disabled: cockpit-ws serves a
	# self-signed cert on 9090, and there is no way to give it a trusted one
	# for a name it is never addressed by. The hop is host-local. The cert the
	# browser sees is the wildcard Caddy presents.
	@cockpit host cockpit.{env.DOMAIN}
	handle @cockpit {
		reverse_proxy https://host.docker.internal:9090 {
			transport http {
				tls_insecure_skip_verify
			}
		}
	}
```

Place it with the other app blocks, above the `template:` comment. Order among
`handle` blocks doesn't matter for correctness here — the host matchers are
mutually exclusive — but the `@notlocal` guard must stay first.

### 2. compose.yml — reach the host from the container

`stacks/caddy/compose.yml`, in the `caddy` service:

```yaml
    extra_hosts:
      # Cockpit runs on the host, not in a container. Docker maps this to the
      # proxy network's gateway (172.18.0.1, pinned in bootstrap.sh).
      - "host.docker.internal:host-gateway"
```

Without this the name doesn't resolve and Caddy returns 502. Hardcoding
`172.18.0.1` would also work and is arguably more honest given the subnet is
pinned — `host-gateway` was chosen because it survives a subnet change, which is
the one thing pinning is meant to prevent but can't guarantee across a rebuild.

> This is a **compose** change, not just a Caddyfile change.
> `docker exec caddy caddy reload` will not apply it — `extra_hosts` is baked in at
> container creation. It needs a real deploy.

---

## Host configuration

Cockpit validates the `Origin` header on its WebSocket connections and silently
rejects mismatches. Without this, the login page loads, accepts your password, and
then hangs or drops — which looks like a proxy bug and isn't.

`/etc/cockpit/cockpit.conf` on forge:

```ini
[WebService]
Origins = https://cockpit.brent-miles.com https://10.0.0.4:9090
ProtocolHeader = X-Forwarded-Proto
```

```bash
sudo systemctl restart cockpit.socket cockpit.service
```

`ProtocolHeader` tells Cockpit the outer connection was HTTPS even though Caddy
reached it over a hop it considers plain, so session cookies get the `Secure` flag.

The `10.0.0.4:9090` origin is kept deliberately: it preserves direct access as a
fallback for when Caddy itself is the thing that's broken.

**This file is host state and is not in the repo.** If forge is ever rebuilt, this
is one of the things that has to be reapplied by hand unless it moves into
`bootstrap.sh`. Worth doing at some point; noted here so it isn't silently lost.

---

## Deploy

Per README rule 1 — edit on your PC, not on forge:

```bash
# main PC
git add stacks/caddy/Caddyfile stacks/caddy/compose.yml docs/cockpit.md
git commit -m "caddy: route cockpit.<domain> to the host"
git push

# forge
cd ~/home-containers && git pull --ff-only
./scripts/deploy.sh caddy
```

`cockpit.conf` is the exception — it's host config, so it's edited on forge directly.

Verify:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy getent hosts host.docker.internal   # expect 172.18.0.1
```

Then from a LAN machine, browse to `https://cockpit.brent-miles.com`. Padlock, no
warning.

**Open the Terminal page as the smoke test.** Static pages render fine over a broken
WebSocket path; the terminal doesn't. If it connects and echoes, the whole path works.

Confirm the guard still holds — the wildcard's `@notlocal` block should already cover
this, but the check costs nothing:

```bash
docker exec caddy tail -f /var/log/caddy/access.log
```

---

## Firewall (optional, recommended later)

Right now 9090 is open to the LAN from the earlier `ufw allow 9090/tcp`. Once the
Caddy route is confirmed working, that can be narrowed so the only path to Cockpit
is through the proxy:

```bash
sudo ufw delete allow 9090/tcp
sudo ufw allow from 172.18.0.0/16 to any port 9090 proto tcp comment 'cockpit via caddy'
```

**The tradeoff is real.** This removes your fallback: if Caddy is down or the
Caddyfile is broken, the Cockpit UI becomes unreachable at the moment you most want
a UI to debug with. SSH still works, and SSH is the tool you'd actually use for that,
so the loss is smaller than it sounds — but don't apply this on the same day you set
the route up. Let it run first.

Note that this rule is a host `INPUT` rule, not a Docker-published port, so it
behaves normally under UFW. The `DOCKER-USER` caveat in `bootstrap.sh` doesn't apply.

---

## What was already in place

Recorded because a fresh reading of this file might otherwise suggest work that
doesn't need doing:

| Thing | Status |
|---|---|
| `*.brent-miles.com` → `10.0.0.4`, grey cloud | already exists |
| Wildcard TLS cert over Cloudflare DNS-01 | already issued, `cf_tls` snippet |
| `CF_API_TOKEN` in Infisical under `/caddy` | already set |
| Caddy image with the Cloudflare DNS module | `ghcr.io/caddybuilds/caddy-cloudflare` |
| Ports 80/443 published | Caddy stack, already |
| LAN-only guard | `@notlocal` in the wildcard block |

No new DNS record, no new certificate, no new API token, no `caddy add-package`.

---

## Storage log noise

Cockpit's Storage page logs three `udisksd` module errors. They're missing optional
packages, not faults:

```bash
apt-cache search udisks2
sudo apt install udisks2-lvm2
sudo systemctl restart udisks2
```

`udisks2-lvm2` is the one worth having — it lets Cockpit create, resize, and snapshot
logical volumes from the GUI rather than only displaying them. `udisks2-btrfs`
silences the second error harmlessly. Skip `udisks2-iscsi`: it pulls in the open-iscsi
daemon for storage this host doesn't have.

(Check `apt-cache search` first. Resolute dropped `packagekit-tools`, so package names
here aren't safe to assume.)

The `multipathd` lines are startup chatter, not errors — multipath is for multi-path
SAN storage and is meaningless on a single NVMe:

```bash
sudo systemctl disable --now multipathd.service multipathd.socket
```

---

## Appendix — the PackageKit fix

Cockpit's Software Updates page initially failed with
`Failed to obtain authentication. Cannot refresh cache whilst offline`. Two
independent causes behind one message:

1. **polkit** — resolved by clicking *Administrative access* in the Cockpit header.
2. **NetworkManager** — pulled in as a dependency of the `cockpit` metapackage (via
   `cockpit-networkmanager`). Because netplan renders to `systemd-networkd`, NM
   managed zero interfaces and reported `STATE=disconnected, CONNECTIVITY=none`.
   PackageKit queries NM for online status, got "disconnected", and aborted every
   refresh in ~110ms without attempting a fetch. The speed was the tell — far too
   fast for a real network timeout.

```bash
sudo systemctl disable --now NetworkManager NetworkManager-wait-online
sudo systemctl mask NetworkManager
```

Side effect: Cockpit's Networking page is now inert. It could only manage NM
connections and NM managed none, so nothing was lost. This also ended the `wlp5s0`
sysctl tug-of-war between NM and systemd-networkd that was filling the journal.

Gotchas worth keeping:

- `packagekit-tools` (providing `pkcon`) is **not packaged in Ubuntu resolute**.
  Use `journalctl -u packagekit -f` instead.
- Disabling NM's connectivity *probe* (`[connectivity] enabled=false`) does **not**
  fix this. PackageKit reads NM's overall `State` property, and no probe setting can
  lift `disconnected` when NM owns no interfaces.
