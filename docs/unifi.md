# UniFi

The UniFi Network Application, self-hosted, managing the house switch and access
points from one place instead of each device's own web page.

Reached at `https://unifi.brent-miles.com` from the LAN, through Caddy.

```bash
./scripts/deploy.sh unifi
```

---

## What this does and does not cover

Network Application is the **only** Ubiquiti software that can be self-hosted.
It covers switches, access points, and gateways: SSIDs and WPA settings, VLANs
and networks, port profiles and PoE, firmware updates, the client list, channel
and RF planning, and per-device statistics.

Protect (cameras), Access (doors), and Talk (phones) are not container software
and never will be — they run only on Ubiquiti's own hardware, a Cloud Key or a
Dream Machine. If a UniFi camera ever arrives here it belongs in Frigate, not in
a second controller.

---

## The shape of the stack

Two containers.

| Container  | What it is                                         |
| ---------- | -------------------------------------------------- |
| `unifi`    | the application. Java. Web UI on 8443.             |
| `unifi-db` | MongoDB 7.0. Required, external, and not optional. |

The application has no embedded database. This is the single biggest difference
from the old `unifi-controller` image, and it is why a migration from one to the
other is a backup-and-restore rather than a version bump.

**MongoDB is pinned to 7.0, not 8.0, and that is deliberate** — see
[MongoDB will not start on this kernel](#mongodb-will-not-start-on-this-kernel)
below. It is a supported combination, but it is a workaround with an exit
condition, not the intended end state.

---

## Why this stack publishes ports

Every other app in this repo is reached by Caddy over the `proxy` network and
publishes nothing. UniFi cannot be, because switches and access points do not
speak HTTP to their controller:

| Port        | Direction        | What breaks without it                                        |
| ----------- | ---------------- | ------------------------------------------------------------- |
| `8080/tcp`  | device → app     | Everything. This is the inform channel — state and config.    |
| `3478/udp`  | device → app     | Devices adopt, then flap between connected and disconnected.  |
| `10001/udp` | device broadcast | Unadopted devices never appear in the UI.                     |

A reverse proxy carries none of these. So the compose file publishes exactly
those three and nothing else, and the web UI on 8443 stays unpublished and goes
through Caddy like everything else. The reasoning is recorded in
[decisions.md](decisions.md#unifi-publishes-ports-and-has-to); `bootstrap.sh`'s
stray-port check has `unifi` on an explicit allow-list so the exception is
visible rather than tolerated.

`8080` in particular must never be remapped. The port number is written into
each device's inform URL when it adopts. Changing only the host side produces
devices that adopt successfully and go offline several minutes later — the worst
possible failure shape, because the first thing that happens looks like success.

---

## Deploy

### 1. Secrets

Under `/unifi` in Infisical, environment `prod`:

| Key                          | Notes                                                        |
| ---------------------------- | ------------------------------------------------------------ |
| `MONGO_PASS`                 | the application's database user. **Alphanumeric only.**       |
| `MONGO_INITDB_ROOT_PASSWORD` | Mongo's root user. Used once, by the init script.             |

Alphanumeric is not a style preference. `MONGO_PASS` ends up inside a MongoDB
connection URI, and anything needing percent-encoding has to be encoded by hand
in two places. Generating a password without those characters removes the
problem instead of solving it.

Everything else has a working default in the compose file. `LAN_IP` defaults to
`10.0.0.4`; override it in Infisical if forge ever moves.

### 2. Directory

`bootstrap.sh` creates `/srv/unifi/config`. Run it if you have not since this
stack was added:

```bash
./bootstrap.sh
```

That path is a bind mount rather than a named volume for one reason: the UI's
own backups land in `/srv/unifi/config/data/backup`, and a `.unf` file is the
only recovery path this stack has. It needs to be reachable from outside the
container.

### 3. Deploy, and wait longer than feels right

```bash
./scripts/deploy.sh unifi
docker logs -f unifi
```

First start takes several minutes. The controller opens 8443 well before it
serves anything, so a browser that connects and hangs is normal for the first
minute or two — the compose healthcheck has a 180-second `start_period` for
exactly this. Wait for `UniFi Network Application ... is ready`.

### 4. Set the inform host — before adopting anything

`https://unifi.brent-miles.com` → **Settings → System → Advanced → Inform Host**.

Set it to `10.0.0.4`, and **tick Override**.

This is the step that gets skipped, and skipping it is the cause of most "the AP
adopted and then vanished" reports. By default the controller tells devices to
report to whatever address it sees itself as, which inside Docker is a container
IP on the `proxy` network that no access point can reach. Devices are handed an
unreachable address at adoption and drop off shortly after.

Ubiquiti move this setting every few releases. If it is not where this says,
search the settings for "Inform".

---

## Migrating from an existing controller

If the APs and switch are currently adopted to something else — a Cloud Key, a
Dream Machine, or the phone app's built-in local controller — this is a
migration, and **there is no in-place upgrade path**.

1. On the old controller: **Settings → System → Backups → Download** a full
   backup, with history.
2. Deploy this stack with an empty `/srv/unifi/config`.
3. On the first-run wizard, choose **Restore from backup** and upload the `.unf`.
4. Set the inform host as above, before the devices try to check in.
5. Shut the old controller down. Two controllers issuing config to the same
   devices is a genuinely confusing state to debug.

Devices re-adopt themselves once they can reach the new inform host, because the
restore brings their keys with it. Expect a few minutes of them showing as
disconnected.

If the devices were never adopted anywhere — factory fresh — skip all of this and
use the setup wizard normally.

---

## Adopting a device that never appears

Discovery is a broadcast, and broadcasts are exactly what containers are worst
at. `10001/udp` is published on all interfaces rather than bound to the LAN
address specifically to give this the best chance, but it can still fail on a
network with VLANs or a satellite.

Adoption itself does not depend on discovery. Point the device at the controller
directly:

```bash
ssh ubnt@<device-ip>
set-inform http://10.0.0.4:8080/inform
```

The default password is `ubnt`. The device then appears in the UI as pending
adoption. Note the URL is `http`, not `https`, and the port is `8080` — this is
the inform channel, not the web UI, and using the UI's address here fails
silently.

---

## Rotating the Mongo password

**This is the one stack in the repo where changing a secret in Infisical and
redeploying does not take effect.**

`MONGO_USER`, `MONGO_PASS`, `MONGO_HOST` and friends are read only on first run,
and written into `/srv/unifi/config/system.properties`. Every start after that
reads the file, not the environment. A redeploy with a new password gives a
container that starts, connects with the old credentials, and reports nothing
wrong — while Infisical claims a value that nothing is using.

To actually rotate it:

1. Change `MONGO_PASS` in Infisical.
2. Update the user in Mongo:

   ```bash
   docker exec -it unifi-db mongosh -u root -p --authenticationDatabase admin \
     --eval 'db.getSiblingDB("admin").changeUserPassword("unifi", "<new>")'
   ```

3. Edit `unifi.db.password` (or the `MONGO_PASS` line) in
   `/srv/unifi/config/system.properties` on the host to match.
4. `docker restart unifi`.

Step 3 is an edit to host state, which is the thing this repo otherwise forbids.
It is unavoidable here — the file is generated, not templated — so it is written
down instead of pretended away.

---

## Upgrading

### The application

Bump `UNIFI_VERSION` in `stacks/unifi/compose.yml` and redeploy. Read the
linuxserver changelog first: this image has changed bundled JRE versions to
follow UniFi's requirements, and a major UniFi release can change which MongoDB
versions are supported.

Take a backup from the UI before any major version bump. UniFi does not support
downgrades, and the restore-from-backup path is the only way back.

### MongoDB

Not a version bump. MongoDB refuses to start against a data directory written by
a newer major, and performs no automatic upgrade, so changing `MONGO_VERSION`
and redeploying gives a database container in a restart loop and a controller
that cannot authenticate.

The supported path is: take a full UniFi backup from the UI, stop the stack,
delete the `unifi_unifi_db` volume, change the pin, deploy fresh, restore from
the backup. Slower than an upgrade and much harder to get wrong.

```bash
# after taking a backup from Settings > System > Backups
cd stacks/unifi && docker compose down
docker volume rm unifi_unifi_db
# change MONGO_VERSION in compose.yml
cd ../.. && ./scripts/deploy.sh unifi
# then restore the .unf through the setup wizard
```

Version constraints, both of which have to hold at once:

- **UniFi**: 8.1+ supports MongoDB 3.6–7.0. 9.0+ adds 8.0.
- **This box**: MongoDB 8.0+ will not start until forge is on kernel 7.0.14 or
  later. See below.

---

## MongoDB will not start on this kernel

The reason `MONGO_VERSION` is pinned to `7.0` rather than `8.0`.

```
"msg":"MongoDB cannot start: Linux kernel versions 6.19 and newer has a
       known incompatibility with this version of MongoDB"
```

MongoDB 8.0 switched its bundled TCMalloc allocator to a per-CPU cache built on
the kernel's restartable-sequences (rseq) feature. TCMalloc relied on the kernel
writing `cpu_id_start` on reschedule — real behaviour, but never part of the
documented rseq ABI. Linux 6.19 rewrote rseq for performance and stopped doing
it. TCMalloc has not been fixed, so MongoDB ships a kernel version check and
refuses to start rather than segfault every thirty seconds.

Affected kernels are **6.19 through 7.0.13**. Kernel **7.0.14 and later** fixes
it, per MongoDB's own production notes.

Two things worth knowing, because both waste time:

- **The `GLIBC_TUNABLES=glibc.pthread.rseq=1` workaround in forum threads does
  not apply here.** That trick makes glibc claim rseq first so TCMalloc falls
  back to a per-thread cache, and it was written for the era when this
  presented as a crash. What we get is a version check that fires before any
  allocation happens. The process never reaches the code the tunable affects.
- **Rolling forward does not escape it.** 8.2 vendors the same TCMalloc. The
  only versions that work are 7.0 and below, or a specific old patch release
  (8.0.4) that predates the check — which is not something to build on.

**MongoDB 7.0 is not affected** and is a supported UniFi database, so that is
the pin until the kernel moves.

### Getting back to 8.0

```bash
uname -r     # need 7.0.14 or later
```

When forge is on 7.0.14+, follow [Upgrading → MongoDB](#mongodb) above: backup,
delete the volume, change the pin, restore. The kernel upgrade is the part that
needs care, not the Mongo bump — forge runs the NVIDIA driver via DKMS for
Frigate and Immich, so verify `nvidia-smi` and the Frigate detector come back
before touching this stack.

Tracked in [decisions.md](decisions.md#still-open) so the pin does not quietly
become permanent.

---

## Backups

The controller's own backup (**Settings → System → Backups**) is the artefact
that matters — it contains the site config, device adoption keys, and history,
and it is what a restore consumes. Turn on auto-backup and set a retention of a
few copies. They land in `/srv/unifi/config/data/backup`.

That directory currently has no offsite copy, which puts it in the same bucket as
Home Assistant's data directory on the
[still open](decisions.md#still-open) list. The `unifi_db` volume is **not** the
backup — restoring a UniFi install means importing a `.unf`, not copying
MongoDB's files.

---

## Things that look like bugs and are not

**The certificate warning on first setup.** Before the Caddy route exists, or if
you reach `https://10.0.0.4:8443` directly, the app serves its own self-signed
certificate. Through `unifi.brent-miles.com` the browser sees the Cloudflare
wildcard and is happy. Caddy skips verification on the hop behind it on purpose —
see the comment in the Caddyfile.

**A device stuck on "Adopting".** Almost always the inform host, occasionally
`3478/udp`. Check the inform host setting first; it is one click and it is the
cause most of the time.

**The dashboard loads but never updates.** That is the WebSocket being buffered.
`flush_interval -1` in the Caddyfile block is what prevents it; if the block was
copied without it, this is the symptom.

**Mongo "Authentication failed" on a fresh deploy.** The init script only runs on
an empty `/data/db`. If the `unifi_db` volume already existed — from a first
attempt, or because Mongo started once without the script mounted — it was
skipped and the user was never created. Delete the volume and redeploy; do not
try to repair it.

This is the likely state after the kernel incompatibility above: the 8.0
container created the volume and then refused to start, so the init script never
ran and never will on that volume. Deleting it is part of the fix, not an extra
step.

```bash
cd stacks/unifi && docker compose down
docker volume rm unifi_unifi_db
cd ../.. && ./scripts/deploy.sh unifi
```
