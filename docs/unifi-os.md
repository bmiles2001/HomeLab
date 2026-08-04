# UniFi OS Server (in Docker)

The controller for the house switch and access points. UniFi OS Server —
Ubiquiti's current self-hosted product — running as a container rather than as
a host install.

Reached at `https://unifi.brent-miles.com` through Caddy, and directly at
`https://10.0.0.20` — the container has its own address on the house LAN.

```bash
./scripts/deploy.sh unifi-os
```

Supersedes [unifi.md](unifi.md) (the legacy Network Application, parked) and
[unifi-os-server.md](unifi-os-server.md) (the host install, not done).

---

## Why this and not the host install

Ubiquiti's answer to "will UniFi OS Server ship as a container" is no, and
[unifi-os-server.md](unifi-os-server.md) worked through what installing it on
forge would have cost: podman alongside Docker, a self-updating binary outside
apt, irreplaceable state outside git, and a fight with Caddy over port 443.

[github.com/lemker/unifi-os-server](https://github.com/lemker/unifi-os-server)
extracts the same binary into an image. That buys back everything the host
install would have spent:

| | Host install | This |
| --- | --- | --- |
| Described by this repo | no | **yes** |
| Deployed by `deploy.sh` | no | **yes** |
| Needs podman on forge | yes | **no** |
| Fights Caddy for 443 | yes | **no** — 443 stays inside the container |
| Updates itself | yes | **no** — pinned tag, you choose |

What it does not buy back is vendor support, and it adds a privilege grant
worth understanding before deploying.

---

## What this container can do to the host

This is the most privileged thing in this repo and the honest cost of the
approach.

UniFi OS Server is not one process. It is systemd running a tree of services —
the Network application, MongoDB, RabbitMQ — which is why the container needs:

- `cgroup: host` and `/sys/fs/cgroup:rw` — the **host's** cgroup hierarchy,
  writable. This is a documented container-escape primitive, not a theoretical
  one.
- `NET_RAW` and `NET_ADMIN` — raw sockets for STUN and discovery.

Compare that to the care taken elsewhere here: Mosquitto is on an internal
network to keep three containers' worth of blast radius, Frigate's config is
mounted read-only so its own UI cannot edit it. This container could, in
principle, act on the host.

It is accepted for two reasons, both narrow:

1. **The alternative was strictly worse.** Installing UniFi OS Server on forge
   gives the same software the same access, minus the container boundary, plus
   podman, plus self-updating.
2. **It is LAN-only and stays that way.** Same rule as Frigate. It never gets
   a public hostname.

If that trade stops looking acceptable, the way out is a Cloud Key — real
hardware, on its own, doing this job with no privileges on anything of yours.

---

## Deploy

### 1. Directories

```bash
./bootstrap.sh
```

Creates the seven bind-mount paths under `/srv/unifi-os`. All state lives
there: `/persistent` and `/var-lib-mongodb` between them hold every adoption
key and all site history.

### 2. Park the legacy stack

```bash
cd stacks/unifi && docker compose down
```

Two controllers issuing config to the same devices is a genuinely confusing
state. Do not delete `stacks/unifi/` — it is the rollback.

### 3. Deploy

```bash
./scripts/deploy.sh unifi-os
docker logs -f unifi-os-server
```

There are no secrets in this stack; `deploy.sh` has an explicit empty entry for
it so a missing case stays a mistake rather than a blank cheque. First start is
slow — systemd brings up MongoDB and RabbitMQ before the Network application,
and the console answers on 443 well before it is usable.

### 4. Set up directly, not through Caddy

Go to **`https://10.0.0.20`** from your PC and accept the self-signed
certificate.

Do first-run setup here rather than at `unifi.brent-miles.com`. The legacy
application's wizard failed through the reverse proxy with a bare `403` on
`/api/cmd/sitemgr` and no message; whether this one does is unknown, and setup
is not when you want to find out. Once an admin exists and you can log in,
switch to the Caddy hostname and confirm that works too.

`UOS_SYSTEM_IP` is already `10.0.0.20` in the compose file, so the inform
address is right from the start — no settings page to remember, unlike the
legacy stack.

---

## Discovery and macvlan

This is the reason the stack looks the way it does.

A normal Docker container sits behind NAT on a bridge — `172.18.x.x` — while
the access points broadcast on `10.0.0.x`. Unicast survives a published port;
broadcasts do not survive DNAT. So a bridged controller can be *talked to* but
can never *find* anything, and every adoption becomes a manual `set-inform`
against an IP you had to go and look up.

macvlan gives the container its own MAC and its own address on the real
segment. `bootstrap.sh` creates it:

```bash
docker network create -d macvlan \
  --subnet 10.0.0.0/24 --gateway 10.0.0.1 \
  --ip-range 10.0.0.16/28 \
  -o parent=<default-route-nic> lan
```

The container joins `lan` at `10.0.0.20` and `proxy` for Caddy. Adoption is
then what it should be: unadopted devices appear in the console on their own
and you click Adopt.

### Reserve the range in the Orbi

`--ip-range 10.0.0.16/28` is `10.0.0.16`–`10.0.0.31`. **Exclude that block from
the Orbi's DHCP pool.** Docker allocates from it with no idea the router
exists, and the router hands out leases with no idea Docker does. The collision
is intermittent and presents as the controller vanishing for no reason.

### The host cannot reach it

A quirk of macvlan, not a misconfiguration: **forge itself cannot talk to
`10.0.0.20`.** The kernel does not bridge a parent interface to its own macvlan
children. From your PC it works fine; from the machine hosting the container it
does not.

Consequences worth knowing before they confuse you:

- `curl https://10.0.0.20` **from forge** fails. From anywhere else it works.
- This is precisely why the container is still on `proxy`. Caddy is a container
  on that bridge, not a process on the host, so it reaches
  `unifi-os-server:443` normally. Drop `proxy` and the Caddy route dies.
- `docker exec` and `docker logs` work as usual.

If host access is ever genuinely needed, the fix is a macvlan shim interface on
forge. It isn't needed today and adds host state, so it isn't there.

### Parent interface and promiscuous mode

`bootstrap.sh` detects the parent from the default route and checks the NIC for
`PROMISC`. macvlan needs the NIC to accept frames for MACs that aren't its own;
when it doesn't, the container looks perfectly configured and receives
absolutely nothing. Override the detection if forge grows a second NIC:

```bash
LAN_PARENT=enp5s0 ./bootstrap.sh
```

Wi-Fi parent interfaces do not work with macvlan at all. forge is wired.

### Manual adoption, if you still need it

Discovery should make this unnecessary, but it still works and is worth
knowing:

```bash
ssh ubnt@<device-ip>          # default password: ubnt
set-inform http://10.0.0.20:8080/inform
```

Note `http`, not `https`, and port `8080` — the inform channel, not the
console. Using the console address here fails silently.

If the devices are currently adopted elsewhere — a Cloud Key, or the phone
app's local controller — take a full backup there first and restore it through
the setup wizard. The restore brings the device keys with it and they re-adopt
themselves once they can reach the inform address.

---

## Updating

```bash
# check what the maintainer has published
# https://github.com/lemker/unifi-os-server/pkgs/container/unifi-os-server
```

Set `UNIFI_OS_VERSION` in `stacks/unifi-os/compose.yml` and redeploy. **Take a
backup from the console first** — UniFi does not support downgrades, and
restore-from-backup is the only way back.

The tag defaults to `latest`, which should be pinned as soon as there is a
known-good version to pin to. `latest` on a third-party repackaging of someone
else's proprietary binary means "whatever a stranger published this morning,"
pointed at the house network.

Watch for the failure mode specific to this arrangement: Ubiquiti ship a new
UniFi OS Server, the extraction breaks, and the image goes stale or broken with
no vendor to escalate to. That is the risk being carried, and the mitigation is
that `stacks/unifi/` still exists.

---

## Rolling back

```bash
cd stacks/unifi-os && docker compose down
cd ../unifi && cd ../.. && ./scripts/deploy.sh unifi
```

Then in `stacks/caddy/Caddyfile`, comment out the `@unifi` block and uncomment
`@unifi-legacy`, and **recreate** Caddy rather than reloading it — a pulled
file is a new inode and a reload will re-read the old one:

```bash
./scripts/deploy.sh caddy -- --force-recreate
```

See [decisions.md](decisions.md#single-file-bind-mounts-need-a-recreate-not-a-reload).

The legacy stack's Mongo volume was never deleted, so it comes back where it
was. Devices will need their inform host pointed back at the old controller.

---

## Things that will look like bugs

**Nothing on 443 from the host, and `ss -tlnp` shows no UniFi ports at all.**
Correct. This stack publishes nothing — it has its own LAN address. If
`bootstrap.sh` ever reports `unifi-os-server` as a stray port publisher,
something has gone wrong with the `lan` network and it has fallen back to
borrowing the host's.

**`curl https://10.0.0.20` fails on forge but works from your PC.** Expected,
and explained above under [the host cannot reach it](#the-host-cannot-reach-it).

**Devices adopt and then go offline minutes later.** `UOS_SYSTEM_IP` and
`ipv4_address` disagree. Both are in the compose file and must match; devices
adopt against one address and are told to report to the other.

**The console is slow for the first few minutes.** systemd is starting MongoDB
and RabbitMQ underneath. `docker logs -f unifi-os-server` shows the truth.
