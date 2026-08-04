# UniFi OS Server

Ubiquiti's supported self-hosted controller, installed **on forge** rather than
in a container. This is a deliberate exception to how everything else here
works, taken on trial, with the conditions for reversing it written down before
it starts.

Replaces `stacks/unifi/`, which is parked rather than deleted — see
[Rolling back](#rolling-back).

---

## Why this and not the container

The container works for managing devices that are already adopted. What it
cannot do is Layer-2 discovery: the controller sits on `172.18.x.x` and the
access points broadcast on `10.0.0.x`, so neither can find the other without
NAT tricks, and adoption becomes a manual `set-inform` per device.

Ubiquiti says as much in their own FAQ when asked whether UniFi OS Server will
ship as a container:

> No. This is a complete solution that requires certain services to be run on
> the host to enable device discovery, adoption, and automatic system updates.

The second reason is more mundane: the legacy Network Server gates parts of
setup behind an online Ubiquiti account, and the wizard fails in ways that are
hard to distinguish from a broken deployment. Two evenings went into a
`403` on `/api/cmd/sitemgr` that turned out to be a product boundary rather
than a bug in this repo.

---

## What this costs, stated plainly

This is a bigger exception than Cockpit, and it is worth being honest about why
rather than filing it under the same heading.

[Cockpit](cockpit.md) was admitted because it is a **view**, not a store: no
database, no config of its own, rebuildable with one `apt install` and one
config file that lives in this repo.

UniFi OS Server fails that test on four counts at once:

| | Cockpit | UniFi OS Server |
| --- | --- | --- |
| Holds irreplaceable state | no | **yes** — sites, adoption keys, history |
| Installed by apt | yes | **no** — a binary from `fw-download.ubnt.com` |
| Updates under your control | yes | **no** — updates itself via Update Manager |
| Brings a container runtime | no | **yes** — podman, alongside Docker |

Any one of those exists somewhere on this box already. All four together is
new, and that is the actual decision being made here. See
[decisions.md](decisions.md#unifi-os-server-runs-on-the-host-on-trial).

---

## The two rules this trial runs under

1. **If it fails, that is acceptable.** A controller that will not install, or
   installs and misbehaves, is a bad evening and nothing more. Leave it broken
   and come back to it.
2. **If it damages the Docker infrastructure, roll it back immediately.**
   Immich, Frigate, Home Assistant, Infisical and Caddy were working before
   this and must be working after. That is not negotiable and not worth
   debugging under pressure.

Rule 2 is only useful if "damaged" is something you can check rather than
sense, which is what `scripts/host-snapshot.sh` is for.

---

## Step 1 — snapshot, before anything

```bash
./scripts/host-snapshot.sh before
```

Captures listening sockets, containers and their ports, Docker networks and
subnets, iptables, the iptables alternatives setting, addresses, routes and
running services. Written to `/srv/snapshots`, which is not in git — it
contains this machine's firewall rules.

---

## Step 2 — stop the container stack, keep the files

```bash
cd stacks/unifi && docker compose down
```

Do **not** delete `stacks/unifi/` and do not remove its volumes. Those files
are the rollback path, and the Mongo volume costs nothing to keep.

Ubiquiti are explicit that the old Network Server must not be running when the
new one installs — two controllers issuing config to the same devices is a
genuinely confusing state.

---

## Step 3 — check who holds 80 and 443

```bash
sudo ss -tlnp | grep -E ':(80|443)\s'
```

This will show Caddy. That is expected, and it is the single biggest known
collision: UniFi OS consoles serve their portal on 443 and manage their own
certificates, so it does not want to live behind a reverse proxy the way the
container did.

**Leave Caddy running anyway.** If UniFi OS Server cannot bind 443 it will fail
loudly at install, which is rule 1 — an acceptable outcome. If you stop Caddy
first to "let the installer through," it will take the port, and every other
service in the house loses its front door the moment Caddy tries to come back.
That is rule 2, self-inflicted.

Incumbency is doing useful work here. Do not give it away.

---

## Step 4 — install

Per [Ubiquiti's instructions](https://help.ui.com/hc/en-us/articles/34210126298775-Self-Hosting-UniFi).
Requirements are met by forge: Ubuntu 24.04 or later, x86-64, 2GB RAM minimum,
10GB free.

```bash
sudo apt-get update && sudo apt-get install podman slirp4netns
```

Watch what that pulls in. Podman and Docker coexist fine in the ordinary case,
but both drive iptables, and the failure worth catching is
`update-alternatives` flipping between `iptables-nft` and `iptables-legacy`
underneath them. Docker's rules stop applying and nothing announces it. The
snapshot's `iptables-alt` file exists for exactly this.

Then fetch the installer URL from [Releases](https://community.ui.com/releases)
or the [download page](https://ui.com/download) — right-click the download and
copy the link address:

```bash
curl -O '<uos_server_download_link>'
chmod +x <installer>
sudo ./<installer>
```

Useful afterwards:

```bash
sudo systemctl status uosserver
sudo systemctl stop uosserver
sudo systemctl disable uosserver     # stop it starting at boot
```

---

## Step 5 — snapshot again and read the diff

```bash
./scripts/host-snapshot.sh after
./scripts/host-snapshot.sh diff
```

### What counts as impact

**Expected, not a problem:**

- A new `uosserver` service.
- New podman networks and a `10.88.0.0/16` subnet, podman's default.
- New listening sockets on 8080, 3478/udp, 10001/udp, 8444.
- New iptables chains with `CNI-` or `NETAVARK-` prefixes.

**Roll back:**

- Caddy no longer listening on 443, or any existing container missing from
  `containers.txt`.
- `iptables-alt` changed — Docker's rules may now be going to a table nothing
  reads.
- Any existing Docker network's subnet changed, or a new subnet overlapping
  `172.18.0.0/16`.
- Anything in `docker ps` that was healthy before and is not now.

**Check by hand regardless**, because a snapshot cannot see application state:

```bash
curl -sk -o /dev/null -w 'immich  %{http_code}\n' https://photos.brent-miles.com
curl -sk -o /dev/null -w 'frigate %{http_code}\n' https://security.brent-miles.com
curl -sk -o /dev/null -w 'ha      %{http_code}\n' https://home.brent-miles.com
```

---

## A consequence worth acting on

Podman's default network is `10.88.0.0/16`. The LAN-only guard in the Caddyfile
allows `10.0.0.0/8`, which contains it — so every podman container UniFi OS
Server creates would be treated as "on the LAN" by Caddy and allowed through to
Frigate, Home Assistant and Cockpit.

`decisions.md` already flagged tightening that range once the Orbi's DHCP
behaviour was confirmed. This turns a tidy-up into something with a reason:

```caddy
@notlocal not remote_ip 10.0.0.0/24 192.168.0.0/16 127.0.0.1/32
```

Do this **before** the install, not after.

---

## Rolling back

Nothing here is one-way. In order:

```bash
# 1. stop and disable the host service
sudo systemctl stop uosserver
sudo systemctl disable uosserver

# 2. confirm the ports came back
sudo ss -tlnp | grep -E ':(80|443|8080)\s'

# 3. bring the container stack back - the files never left
cd stacks/unifi && git checkout . 2>/dev/null || true
cd ../.. && ./scripts/deploy.sh unifi

# 4. uncomment the unifi block in stacks/caddy/Caddyfile, then RECREATE
#    caddy - a reload will not pick up a pulled file. See
#    decisions.md#single-file-bind-mounts-need-a-recreate-not-a-reload
./scripts/deploy.sh caddy -- --force-recreate

# 5. verify against the snapshot you took at the start
./scripts/host-snapshot.sh after && ./scripts/host-snapshot.sh diff
```

Removing podman afterwards is optional and riskier than leaving it — an
`apt purge` that takes `containernetworking-plugins` or an iptables alternative
with it is a worse outcome than an idle package. Leave it unless the diff says
it is causing harm.

---

## If it works

Then this document stops being a trial and becomes a runbook, and two things
are owed:

- **A backup story.** UniFi OS Server holds every adoption key and all site
  history, in podman volumes it owns. It joins Home Assistant's data directory
  on the [still open](decisions.md#still-open) list until something covers it.
- **A decision on `stacks/unifi/`.** Delete it, or keep it parked. Parked is
  fine for a while; parked forever is how a repo starts lying.
