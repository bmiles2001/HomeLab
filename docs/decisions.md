# Decisions

Why this is shaped the way it is. Written down so that in eighteen months you
can tell a considered choice from an accident.

Date: 2026-07-28.

---

## Compose files are the unit of deployment

**Not** quadlets, not a tool's proprietary stack format.

Compose is the portable layer. Every project you'll want to run publishes a
compose file, you can paste one to evaluate something in five minutes, and no
management UI owns them. Quadlets are more robust and more podman-native, but
adopting them means hand-translating every upstream compose file and losing
the paste-to-evaluate workflow — too much friction for a homelab that grows by
trying things.

Consequence: `podman compose` (the docker-compose v2 shim), not
`podman-compose` (the Python reimplementation, which has known path bugs under
WSL).

## Git is the source of truth, with no UI allowed to compete

Every tool considered had the same failure mode available to it: paste config
into a web editor, tool stores it in its own database, repo silently goes
stale. Portainer stores stacks in SQLite. Nginx Proxy Manager and Zoraxy store
routing in a database.

The rule that falls out: **any UI adopted must be a view over files on disk,
not a store of record.** That's why Dockge is the eventual container UI of
choice and Portainer's web editor is off-limits — Portainer's git-backed
stacks would be acceptable, its editor never is.

### Portainer — rejected for now

Two reasons. The web editor drift problem above, and Portainer's Podman
support is officially CentOS Stream 9 + Podman 5 + rootful only. A Windows
podman machine isn't a supported configuration.

### Komodo — rejected

Git-native by design and the best fit on paper. But its periphery agent talks
to `/var/run/docker.sock`; the podman socket can be bound there in the
container variant but not the systemd one, and it's a community workaround
rather than supported. Stacked on top of Windows and WSL, that's too many
unsupported layers deep to debug at 11pm.

Worth revisiting if the box ever moves to Linux.

**Amendment, 2026-08-03 — now rejected outright, for a different reason.**
The Docker-socket objection did die with the Linux pivot, so on that count Komodo
became viable. It's still not being adopted: Komodo wants to own environment
variables and secrets for the stacks it deploys, and that collides directly with
`scripts/deploy.sh` injecting them from Infisical at deploy time. Running both
means two systems believing they own the same values, with no error when they
disagree — the same class of silent drift that ruled out Portainer's web editor,
just relocated from config to credentials.

Picking one would mean either giving Komodo the secrets (and demoting Infisical to
a store nothing reads) or keeping Infisical and accepting that Komodo's deploy path
can't be used — at which point it's a dashboard, not a deploy tool.

Not on the "deliberately not done yet" list. Decided against.

### Podman Desktop for now, Dockge later

Podman Desktop covers eyeballing containers. Dockge stores stacks as real
compose files on disk, so adopting it costs nothing architecturally. Every
Docker-ecosystem UI needs the docker-compat socket, which podman does provide
officially — the tax is that none of those vendors test against podman.

## Caddy over SWAG and Traefik

All three terminate TLS, get a Let's Encrypt wildcard over Cloudflare DNS-01,
and reverse proxy. The difference is where config lives.

**Caddy** puts the entire routing table in one small text file that sits in
git perfectly. Adding an app is three lines. Reloads are graceful, and it
re-resolves upstream hostnames at dial time so container IP churn never
matters.

**SWAG** was the starting point and bundles genuinely useful things — ~200
preset app configs, fail2ban, optional ModSecurity WAF. But its config is a
tree of nginx `.conf` files inside the `/config` volume, mixed with generated
state. The volume ends up being the truth, which is the same drift problem in
a different coat. Its batteries mostly matter once something is exposed
publicly, which nothing is.

**Traefik** declares routing as labels on each container, so a stack fully
describes both the app and how it's reached. Arguably the purest
infrastructure-as-code of the three, and the closest conceptual match to a
Kubernetes ingress controller if that's worth something professionally.
Rejected on ergonomics: labels are fiddly to debug and the dashboard is
read-only.

Revisit SWAG's fail2ban and WAF the day something gets exposed to the
internet.

## Infisical for secrets

Chosen over SOPS + age, with the tradeoff understood.

**SOPS + age** would have been simpler: encrypted files committed to the repo,
no daemon, no bootstrap ordering, `git clone` plus one private key equals a
full rebuild. It remains the more robust choice on the merits.

**Infisical** was chosen for the UI, and for rotation being a 30-second web
operation rather than an encrypt-commit-push cycle. The costs, accepted
knowingly:

- Its Postgres becomes single-point-of-failure infrastructure holding every
  credential at once. Mitigated by `scripts/infisical-backup.sh`, which must
  be running *before* anything real is migrated in.
- It must be up to deploy. It does not need to be up to reboot — running
  containers keep their environment — so the dependency only bites when you're
  already at the keyboard.
- One bootstrap secret still lives on disk (`stacks/infisical/.env` plus the
  machine identity in `~/.infisical-identity`). The chain terminates in your
  password manager, not in nothing.

## One shared `proxy` network

Created out of band by `bootstrap.sh` and declared `external: true` everywhere,
so no single stack owns it and tearing one down can't delete it.

Only Caddy publishes ports. Apps join `proxy` and are reached by container
name; backing services like Postgres and Redis stay on their stack's private
default network and never join. This is a real security improvement over
publishing every app's port to the LAN, and it removes the hardcoded
`10.0.0.4:PORT` upstreams that the first draft needed.

## Container data never touches `C:/`

The original setup bind-mounted `C:/_ContainerMounts/...`. Podman on Windows
runs containers inside a WSL2 VM, so those mounts cross the drvfs bridge on
every write — slow for config, and unsafe for Postgres, which doesn't get the
flush and locking semantics it requires. (`wsl-host.md` explained this at
length; it was deleted in the Linux pivot below, along with its subject.)

Data lives on the machine's ext4 disk: named volumes, or paths like
`/srv/immich/data` where something outside the container needs to read them.

---

# Amendment: the Linux pivot

Date: 2026-07-28, same day. The "still open" item below was reopened within
hours of being written.

## Bare-metal Ubuntu Server + Docker, on `forge`

Windows was earning nothing. The box is headless by design, and every awkward
paragraph above — the drvfs bridge, `C:/` volume mounts, the WSL port proxy,
`RemoteCommand wsl -d podman-machine-default` — existed only to work around it.

Consequences, all simplifications:

- `docs/wsl-host.md` is deleted. Its entire subject no longer exists.
- "Container data never touches `C:/`" stops being a rule and becomes a fact.
- `podman compose` → `docker compose`. Compose stays the unit of deployment;
  that decision was made for portability and portability is what just paid out.
- Docker-ecosystem tooling is now running in the configuration its vendors
  actually test against, rather than on podman's compat socket.

New cost accepted: membership in the `docker` group is root-equivalent. Fine
for a single-admin box, and it's the price of the tooling working at all.

## Komodo — reversed, now adopted

The rejection above was entirely about the periphery agent needing
`/var/run/docker.sock` under podman-on-WSL. On real Docker that objection
evaporates. Komodo was already "the best fit on paper" for git-push→deploy, and
it additionally polls image registries and can keep other containers updated.

Adopted, but *after* Immich is running — its first stack should be one that
already works, so a failure has exactly one possible cause.

Dockge is dropped from the plan. Komodo covers the same ground and is
git-native rather than git-tolerant.

## Immich, confirmed by comparison rather than assumption

Re-evaluated against Ente, PhotoPrism, Nextcloud Memories and others. Immich is
the only one meeting the hard requirement — a native iOS app doing background
camera-roll backup for three people — without a paid third-party app in the
path. See [photo-app-comparison.md](photo-app-comparison.md).

## Public exposure, chosen over the alternatives

`photos.brent-miles.com` will be reached by forwarding 443 to Caddy, which
already holds a Let's Encrypt wildcard via Cloudflare DNS-01. Cloudflare stays
grey-cloud for that host.

- **Cloudflare Tunnel** rejected: the free plan's 100 MB request body limit
  breaks iPhone video backup, and their terms discourage proxying bulk media.
  Still the right tool if a share-only subdomain is ever wanted.
- **Tailscale-only** rejected: coworkers with no account can't open a shared
  album, which is an explicit requirement.

This makes the SWAG note above actionable — "revisit fail2ban and a WAF the day
something gets exposed" is now due. The answer is **CrowdSec parsing Caddy's
logs**, not fail2ban on SSH: with password auth disabled there is no SSH
credential to brute-force, and the real attack surface is the HTTP front door.
Immich ships no brute-force protection of its own.

## The two GPUs get one workload each

Frigate on the Intel UHD 770, Immich on the RTX 3080.

The workloads have opposite shapes: Frigate detects continuously and forever,
where latency directly caps how many cameras can run; Immich's ML is bursty and
nobody notices if an import takes an extra minute. Splitting them means neither
can starve the other, and — more practically — a performance problem has one
possible cause instead of two.

The iGPU also decodes the camera streams via QuickSync, which is the larger win
of the two. Software-decoding several 24/7 streams would keep a meaningful slice
of the i9 permanently busy for no reason.

Reversible: if camera count outgrows OpenVINO on the iGPU, detection moves to
the 3080 via the ONNX detector. See [frigate.md](frigate.md).

## Frigate is LAN-only, and that is not a "for now"

Immich is going on the public internet. Frigate never is. An NVR is the
worst-case-if-breached service in the house — live video of the inside of it —
and its threat model assumes a trusted network.

This is also why its `config.yml` is mounted **read-only**: Frigate's web UI can
edit that file, which would reintroduce exactly the drift problem that rules out
Portainer's editor above. Same rule, applied consistently.

Camera credentials live in Infisical under `/frigate` and are referenced by
variable inside `config.yml`, so camera URLs stay in git without their
passwords. The cameras themselves belong on a VLAN with no internet route.

## Amendment: Frigate moves to the 3080

Reverses [the two GPUs get one workload each](#the-two-gpus-get-one-workload-each).
Both ML workloads now run on the RTX 3080; the UHD 770 does nothing.

The original split was defensible — a continuous workload and a bursty one
shouldn't compete — but it optimised for the wrong thing. The enhanced
detection the 3080 makes possible is the reason for running Frigate at all
rather than buying an appliance NVR, and a yolov9 model on an Ampere card is a
different class of accuracy from SSDLite MobileNet on an iGPU. Trading that
away to avoid contention that hasn't happened yet was premature.

What the original reasoning got right, and what to watch: a large Immich import
**will** visibly raise Frigate's inference time. Not stop it — CUDA
time-slices — but if detection looks slow, check whether Immich is busy before
looking anywhere else. That's the cost, and it's paid only during imports.

Fully reversible in two lines of `config.yml` plus the `/dev/dri` device, and
[frigate.md](frigate.md#sharing-the-3080-with-immich) says how.

Consequence worth noting: the iGPU is now idle and is the natural home for
Immich's video transcoding, which currently isn't configured to use anything.

## Recording off until there is a disk for it

Frigate ships here with `record.enabled: false`. This is a live-view and
alerting system, not a recorder, and calling it anything else would be
self-deception.

Continuous recording of four cameras for a week is over a terabyte — most of
the NVMe, on the disk the photo library was bought for. Frigate filling that
filesystem takes Immich's Postgres down with it, so the failure isn't "no
footage," it's "no photo server." Motion-only retention reduces that without
bounding it.

The right answer is a dedicated spinning drive: cheap per TB, good at
sequential writes, and it isolates the failure. Until one exists, off is more
honest than a retention policy tuned to a disk that's already spoken for.
`FRIGATE_MEDIA` exists so that day is a one-line change.

## MQTT gets its own network, not `proxy`

Mosquitto is on an `iot` network shared with exactly Frigate and Home
Assistant, and is not on `proxy` at all.

MQTT has a flat permission model — any client that authenticates can subscribe
to `#` and read every message on the broker, including camera event payloads.
Putting it on `proxy` would make it resolvable and reachable by every container
in the house for no benefit, since it has no web interface for Caddy to route
to in the first place.

`iot` is created `--internal`, so mosquitto has no route off the box. Frigate
and Home Assistant keep theirs through `proxy`.

## Home Assistant partially escapes git

An honest exception to [git is the source of truth](#git-is-the-source-of-truth-with-no-ui-allowed-to-compete),
recorded rather than hidden.

`configuration.yaml` is in this repo and mounted read-only, same as Frigate's
config. But that is the small part of HA's configuration. The rest — every
integration's setup and credentials, users, tokens, devices — lives in
`.storage/` as JSON that HA writes constantly and that has no supported
hand-edited form. Automations built in the UI land in `automations.yaml` in the
data directory, also outside git.

There is no version of HA where this isn't true; it is a stateful application,
not a config file with a daemon attached. Pretending otherwise would mean
either forbidding the UI — which defeats the point of HA — or a repo that
claims to describe a system it does not.

What follows from that: `/srv/homeassistant/config` is real state and needs a
real backup, which it does not yet have. See
[home-assistant.md](home-assistant.md#backups).

## UniFi publishes ports, and has to

A real exception to [only Caddy publishes ports](#one-shared-proxy-network),
and the first one a container has been granted.

The UniFi Network Application is reached by two different kinds of client. A
browser, which Caddy handles like any other app — the web UI on 8443 is not
published and goes through `unifi.brent-miles.com` exactly like Frigate and
Home Assistant. And the switch and access points, which do not speak HTTP to
their controller at all: `8080/tcp` for the inform channel, `3478/udp` for
STUN, `10001/udp` for discovery broadcasts. A reverse proxy carries none of
those, and there is no configuration of Caddy that changes this.

The alternatives were considered and are worse:

- **`network_mode: host`** would work and is what a lot of guides suggest. It
  also puts every port the application opens on the LAN, including 8443, and
  takes the container off `proxy` so Caddy can no longer reach it by name. One
  deliberate exception becomes a blanket one.
- **A Cloud Key** removes the problem by buying hardware, which is the correct
  answer for somebody who does not already have a server running.

So: three device-facing ports, published, listed individually in the compose
file with what breaks without each one. Two of them are bound to `10.0.0.4`
rather than `0.0.0.0` so the interface is a decision. `10001/udp` is not,
because devices announce themselves by broadcast and a socket bound to a
unicast address never sees that traffic — a subtlety that would otherwise
present as an empty Devices page with nothing in any log.

`bootstrap.sh`'s stray-port check now carries an explicit allow-list rather
than a special case buried in a regex. The point of that check is that a
second publisher should be a decision someone made, and an allow-list is what
a decision looks like in a script.

**Where the line is:** the UI stays behind Caddy and stays LAN-only, for the
same reason Frigate does. A network controller can reconfigure the network
every other service in the house sits on. It is not a candidate for the public
zone, now or later.

**Consequence:** README rule 2 is no longer literally true and now reads as a
rule with one named exception. That is worse than an absolute rule and better
than a rule everybody knows is quietly violated.

See [unifi.md](unifi.md).

## Every volume is named, including the empty ones

A small convention with an annoying failure mode behind it.

An image can declare `VOLUME /some/path` in its Dockerfile. If the compose file
mounts nothing there, Docker does not skip it — it creates an **anonymous**
volume, named with 64 hex characters, owned by no stack and described by no
file in this repo. Worse, it is not reused: each `docker compose up` that
recreates the container makes a new one and orphans the old. `docker volume ls`
fills up with identical-looking entries that nobody can safely delete, because
telling a live one from an orphan means inspecting every container.

Two images here do this. `eclipse-mosquitto` declares `/mosquitto/log`, and
`mongo` declares `/data/configdb`. Neither path is ever written to in this
setup — mosquitto logs to stdout, and `/data/configdb` only holds state in a
sharded cluster — so both mounts are permanently empty and both exist anyway.

The rule: **every volume on this box is named, and every name traces back to a
compose file.** An empty named volume costs nothing. An anonymous one costs the
ability to reason about `docker volume ls` at all.

`bootstrap.sh` checks for 64-hex volume names, in the same spirit as the
stray-port check — the point of a convention is that something notices when it
breaks.

## Still open
- **A backup for Home Assistant's data directory.** HA Container has no backup
  UI, and `/srv/homeassistant/config/.storage` holds every credential HA has.
  Nothing covers it today.
- **An offsite copy of UniFi's `.unf` backups.** Same shape as the HA problem:
  `/srv/unifi/config/data/backup` is the only thing that can rebuild the
  controller, and it exists on one disk. See [unifi.md](unifi.md#backups).
- **UniFi's MongoDB is pinned back to 7.0, and shouldn't stay there.** MongoDB
  8.0+ refuses to start on Linux kernels 6.19 through 7.0.13 — a bundled
  TCMalloc depending on rseq behaviour the kernel stopped providing. 7.0 is
  unaffected and is a supported UniFi database, so it works, but it is an
  older major sitting on a shorter support window for a reason that has
  nothing to do with this repo. Kernel 7.0.14+ resolves it; the exit is a
  kernel upgrade on forge and then the documented Mongo major-upgrade dance.
  Care needed because the NVIDIA driver rebuilds via DKMS and Frigate depends
  on it. See [unifi.md](unifi.md#mongodb-will-not-start-on-this-kernel).
- **Immich transcoding on the now-idle iGPU.** Free performance, unclaimed.
- **Backups.** The photo library will exist in exactly one place on one NVMe.
  `rclone` to OneDrive is the intended answer; until it runs, this is the
  largest unmitigated risk in the build.
- **Remote access for administration.** Tailscale remains the low-risk answer
  and is now complementary rather than an alternative — public 443 for Immich,
  Tailscale for everything that should never be public.
