# UniFi OS Server (in Docker)

The controller for the house switch and access points. UniFi OS Server —
Ubiquiti's current self-hosted product — running as a container rather than as
a host install.

Reached at `https://unifi.brent-miles.com` from the LAN, through Caddy, and
directly at `https://10.0.0.4:11443` during setup.

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

### 4. Set up on 11443, not through Caddy

Go to **`https://10.0.0.4:11443`** and accept the self-signed certificate.

Do the first-run setup here rather than at `unifi.brent-miles.com`. The legacy
application's wizard failed through the reverse proxy with a bare `403` on
`/api/cmd/sitemgr` and no message; whether this one does is unknown, and
finding out during setup is not the time. Once an admin exists and you can log
in, switch to the Caddy hostname and confirm it works.

`UOS_SYSTEM_IP` is already set to `10.0.0.4` in the compose file, so the inform
address is correct from the start — no settings page to remember, unlike the
legacy stack.

### 5. Remove the direct port, once it is proven

Delete the `11443` line from `stacks/unifi-os/compose.yml` and redeploy. It
exists for setup and debugging, and every published port that outlives its
reason is how the "only Caddy publishes ports" rule dies quietly.

---

## Adoption

Discovery does not work, and this container does not change that. It sits on a
Docker bridge at `172.18.x.x` while the access points broadcast on
`10.0.0.x` — the published `10003/udp` carries unicast fine but subnet
broadcasts do not survive DNAT.

So adopt each device by hand, once:

```bash
ssh ubnt@<device-ip>
set-inform http://10.0.0.4:8080/inform
```

Default password `ubnt`. Note `http`, not `https`, and port `8080` — this is
the inform channel, not the console. Using the console address here fails
silently.

If the devices are currently adopted to something else — a Cloud Key, or the
phone app's local controller — take a full backup there first and restore it
through the setup wizard. The restore brings the device keys with it and they
re-adopt themselves once they can reach the inform address.

### If discovery matters

The fix is macvlan: give the container its own address on the real LAN, so it
shares a broadcast domain with the hardware.

```bash
# in bootstrap.sh, alongside `proxy` and `iot`
docker network create -d macvlan \
  --subnet 10.0.0.0/24 --gateway 10.0.0.1 \
  -o parent=<nic> lan
```

Then join both networks — `lan` for the devices, `proxy` so Caddy keeps
working — with a reserved address outside the Orbi's DHCP pool. The published
ports all become unnecessary at that point, which would also retire this
stack's exception to README rule 2.

**Deliberately not done yet.** Four devices adopted by hand, once, is cheaper
than introducing a network type nobody here has debugged, and `set-inform`
works. Revisit when device count makes that false.

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

**Nothing on 443 from the host.** Correct. 443 is inside the container. Caddy
reaches it over the `proxy` network; you reach it at `11443` or through the
hostname.

**`bootstrap.sh` lists a third port publisher.** Expected — `unifi-os-server`
is on the allow-list alongside `caddy` and `unifi`. A fourth is still a
warning.

**Devices adopt and then go offline minutes later.** `UOS_SYSTEM_IP` is wrong,
or 3478/udp is not reaching the container. The first is in the compose file,
not a settings page.

**The console is slow for the first few minutes.** systemd is starting MongoDB
and RabbitMQ underneath. `docker logs -f unifi-os-server` shows the truth.
