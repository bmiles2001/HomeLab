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

## Every volume is named, including the empty ones

A small convention with an annoying failure mode behind it.

An image can declare `VOLUME /some/path` in its Dockerfile. If the compose file
mounts nothing there, Docker does not skip it — it creates an **anonymous**
volume, named with 64 hex characters, owned by no stack and described by no
file in this repo. Worse, it is not reused: each `docker compose up` that
recreates the container makes a new one and orphans the old. `docker volume ls`
fills up with identical-looking entries that nobody can safely delete, because
telling a live one from an orphan means inspecting every container.

One image here does this: `eclipse-mosquitto` declares `/mosquitto/log`. The
path is never written to in this setup — mosquitto logs to stdout — so the
mount is permanently empty and exists anyway.

The rule: **every volume on this box is named, and every name traces back to a
compose file.** An empty named volume costs nothing. An anonymous one costs the
ability to reason about `docker volume ls` at all.

`bootstrap.sh` checks for 64-hex volume names, in the same spirit as the
stray-port check — the point of a convention is that something notices when it
breaks.

## Required variables are checked in deploy.sh

Every stack that takes a secret used to declare it in its compose file as a
required-variable guard:

```yaml
MQTT_PASSWORD: ${MQTT_PASSWORD:?not injected - deploy via scripts/deploy.sh}
```

That reads like exactly the right thing to do. It is not, because **compose
parses the entire file for every subcommand, not just `up`.** The guard fires on
`down`, on `logs`, on `ps` — none of which would ever use the value:

```
$ cd stacks/mosquitto && docker compose down
required variable MQTT_PASSWORD is missing a value
```

The error names a variable, so it reads as though the *command* was typed wrong
rather than run without an environment. Nothing in it suggests "you meant to run
this through Infisical." It cost an evening, because it arrived alongside an
unrelated routing problem and made both look like one fault.

Every stack that took a secret had it. It was never a property of one stack —
the first one anyone happened to run `down` on was simply the one that got
blamed.

The guards are now gone from the compose files. `scripts/deploy.sh` carries a
`required_vars()` table instead, checked after Infisical injects and before
compose runs. Same fail-fast deploy, better message, and plain
`docker compose down` works in a stack directory again.

### What this gives up, stated properly

A hand-typed `docker compose up -d` in a stack directory no longer refuses. It
starts the containers with empty secrets. That is a real regression and it is
the price of the trade, so it is worth being exact about how bad it is.

**Every stack here fails closed, not open.** Checked one by one:

| stack | blank secret does what |
|---|---|
| immich | Postgres rejects an empty `POSTGRES_PASSWORD` |
| beszel | the agent cannot authenticate to the hub; the system never goes green |
| caddy | no Cloudflare token, so the DNS-01 challenge fails; no certificate |
| frigate | cameras and the broker both reject the credentials; no streams |
| mosquitto | `passwd` is regenerated with junk. It does **not** fall back to anonymous |

The result of the mistake is a **broken** stack, not an **exposed** one. That is
the difference between an afternoon and an incident, and it is why the trade is
acceptable — but it is not nothing, and the reason it is written down here is
that it was originally buried in one clause of a multiple-choice option rather
than said out loud.

**The one sharp edge:** mosquitto's entrypoint runs `rm -f /mosquitto/config/passwd`
before regenerating it. A mistaken plain `up` on that stack therefore takes the
broker down, and Frigate and Home Assistant notifications with it, until it is
redeployed properly. Nothing is lost permanently — the file is derived from
Infisical on every deploy — but it is the only stack where the blast radius
reaches other stacks.

**The compensating control** is `bootstrap.sh` check 6d, which inspects running
containers and warns on any required variable that is present and empty. This
repo already prefers detection to prevention for the stray-port and
anonymous-volume conventions; this is the same shape. Prevention was traded for
usable plain compose, so the check is what earns that back.

### The thing that was true the whole time

`docker restart frigate` never needed any of this. It acts on the container, does
not parse the compose file, and never wanted a secret — before or after this
change. Every container in this repo has an explicit `container_name`, so the
routine "reload something" case has always been available and was never broken.
What was broken was `docker compose restart`, which parses the file like every
other subcommand.

Reach for `docker restart <name>` / `docker stop <name>` for lifecycle,
`scripts/deploy.sh <stack>` to apply a change, and compose subcommands only when
you actually mean the stack as a unit.

### Why not just keep the guards and always use scripts/compose.sh

Because that version has the same shape of failure as the one it was meant to
prevent, one level up: with guards in the compose files, **stopping a stack
requires Infisical to be reachable.** `scripts/compose.sh frigate down` runs
`infisical run`, so if Infisical is the thing that has broken, nothing can be
cleanly brought down. A dependency that only bites during a failure is exactly
the kind this repo tries not to accumulate.

**`stacks/infisical` keeps its guards**, and should. It is the one stack
`deploy.sh` cannot handle — it holds the secrets, so it cannot fetch its own —
and it reads a plain `.env` in its own directory. Compose auto-loads that file
for *every* subcommand, so the guards there only fire when the `.env` is
genuinely missing. Which is the behaviour you want.

`scripts/compose.sh` survives the change but shrinks: it is now only for the few
commands that need real values (`config`, a one-off `run`), not for routine
`down`/`logs`/`ps`.

`bootstrap.sh` check 6c catches both directions of drift — a guard creeping back
into a compose file, and a new stack with no entry in `required_vars()`, which
would otherwise deploy with no check at all. Check 6d catches the consequence of
the trade: a container actually running on an empty secret. It reads the same
`required_vars()` table through `deploy.sh --required-vars`, so there is one
copy of the list and not two.

## Single-file bind mounts need a recreate, not a reload

Not a decision so much as a trap that this repo's own workflow walks into, found
the hard way when a freshly added hostname returned nothing while every
container was up and healthy and Caddy could reach the upstream by name
perfectly well.

Docker bind-mounts a **single file** by inode, not by path. Git does not edit
files in place — it writes a new file and renames it over the old name, which
produces a new inode. So after `git pull` on forge, a running container is
still bound to the file that existed when it started, and there is no
indication anywhere that this has happened:

```
grep -c status stacks/caddy/Caddyfile              # 5   - on the host
docker exec caddy grep -c status /etc/caddy/Caddyfile  # 0   - in the container
```

`caddy reload` makes this worse rather than better. It re-reads the path, gets
the stale inode, adapts it without error, and logs success. The one command
that looks like it should prove the fix worked is the command that convinces
you nothing is wrong.

This has nothing to do with `:ro`, and the mount is not a copy — a live edit to
the same inode (`$EDITOR`, `sed -i` without `--follow-symlinks`, `>>`) does
show up immediately. It is specifically **replacement** that breaks the link,
and replacement is what git, and most editors' atomic saves, do.

Four files in this repo are mounted this way, and every one of them is
somebody's source of truth:

| File                                     | Container      |
| ---------------------------------------- | -------------- |
| `stacks/caddy/Caddyfile`                 | `caddy`        |
| `stacks/frigate/config.yml`              | `frigate`      |
| `stacks/homeassistant/configuration.yaml` | `homeassistant` |
| `stacks/mosquitto/mosquitto.conf`        | `mosquitto`    |

**The rule: after a pull that touched any of those, recreate the container.**
Not restart — restart keeps the same mounts. Recreate.

```bash
./scripts/deploy.sh caddy -- --force-recreate
```

The tempting fix is to mount the parent directory instead of the file, since
directory mounts resolve names on each access and do not have this problem.
That is rejected for the same reason the mounts are read-only in the first
place: `stacks/caddy/` also contains `compose.yml`, and Frigate's directory
mount would hand its web UI a writable config again, which is exactly the drift
[git is the source of truth](#git-is-the-source-of-truth-with-no-ui-allowed-to-compete)
exists to prevent. A recreate is cheap; a config store that competes with the
repo is not.

## Beszel over Prometheus, and over nothing

Monitoring was the thing this box did not have. `storage-expansion.md` records
root reaching 92% full, and nothing said so — it was noticed. The 3080 now runs
both Frigate's detector and Immich's ML, and the contention warning written into
[the GPU amendment](#amendment-frigate-moves-to-the-3080) has no instrument
behind it. `restart: unless-stopped` makes a crash-looping container look
exactly like a healthy one.

**Prometheus + Grafana + node_exporter + cAdvisor** is the default answer and
was rejected for the same reason Komodo was: it is four moving parts, a scrape
config, and dashboard JSON that becomes a second source of truth competing with
this repo. It is the right answer when you need custom queries over metrics
nobody thought to collect. That is not this house.

**Beszel** is a Go binary and a SQLite file. Its cost is that you get the
metrics it chose — no arbitrary queries, no PromQL — and its benefit is that
there is nothing to maintain. Alert rules live in its database, which is the
same escape from git that Home Assistant has, and it is written down in
[beszel.md](beszel.md#alerts) rather than pretended away.

**Netdata** was the closer call — better per-metric depth, and agentless in the
sense that one install gives you everything. It was passed over for resource
footprint and for defaulting to a cloud account, which is the wrong direction
for a house that runs Immich specifically to not be on someone else's server.

### Beszel's agent is on the host network

The only deviation from rule 2 on this box, and a narrow one.

Network throughput is read from the host's interfaces. An agent on a bridge
network reports the traffic across its own veth pair instead — a number that is
plausible and wrong, which is worse than a missing chart.

What makes this acceptable is that it publishes nothing. Upstream's config sets
`LISTEN=45876`, which under host networking puts a listener on every interface
the box has. This stack sets `LISTEN` to a unix socket on a bind mount that both
containers share, so the agent binds no TCP port at all. `bootstrap.sh`'s check
6 needed no allow-list entry — and an allow-list entry is permanent, so needing
none is the point.

### And it holds the docker socket, which is the actual cost

Per-container stats require `/var/run/docker.sock`. It is mounted `:ro`, and
**`:ro` on a socket is decoration.** A read-only bind mount stops the socket
file being replaced or chmod'd. It does not stop anything being sent through
it, because `connect()` and `send()` are not filesystem writes — every Docker
API verb still works, `POST /containers/create` included.

Stated plainly, and this replaces a weaker claim an earlier draft of this file
made: **that container is root on forge.** It can create a privileged container
with `/` mounted and step out onto the host. Reading every secret `deploy.sh`
injects, via `inspect`, is the quietest thing it could do rather than the worst.

The rule this sets for the rest of the repo: a `:ro` socket mount is not a
mitigation and must never be counted as one in any file here. The only real
mitigation is a socket proxy holding the socket and returning 403 for
everything but `GET /containers/*/stats` —
[beszel.md](beszel.md#the-docker-socket-is-the-real-cost), and open, not built.

### SMART is on, and it prices the socket proxy in

Decided 2026-08-04, and the ordering is the whole point.

`SYS_ADMIN` and a raw NVMe controller do **not** compound with the socket above.
The socket already grants everything they would, so on the day they were enabled
they changed the blast radius by exactly zero. Anyone reading the compose file
and seeing two scary-looking privileges next to each other should understand
they are alternative routes to one place, not two locks on one door.

What they do is **price the socket proxy**. That mitigation exists to move this
container out of the root-equivalent class; `SYS_ADMIN` plus `/dev/nvme0` keeps
it there regardless of what the socket is doing — NVMe admin passthrough reaches
Format and Sanitize, and raw controller access reads any block on the disk with
no reference to file permissions.

So the proxy stopped being a thing that can be bolted on later in isolation. It
is now a two-part job: proxy the socket **and** revert the SMART block, giving
up drive health, or find another way to read it. Doing only the first half is
the failure mode to guard against — real work, no security change, and a
container everyone now believes is constrained.

Made knowingly, and the reasoning is not subtle: everything on forge is on one
NVMe, most of it has no second copy, and `storage-expansion.md` already records
this box running out of disk once without anything noticing. A mitigation that
exists beats one that is written down. Drive health won.

## Satisfactory publishes ports, and Caddy cannot help

Decided 2026-08-08, and it reopens an allow-list that had been closed.

`bootstrap.sh` check 6 existed to enforce one sentence: apps join `proxy` and are
reached by container name, and `caddy` is the only stack that publishes a host
port. That list had been back down to one name after the DDNS controller was
removed, with a note that a second entry was a decision to document rather than a
quick fix. This is that document.

The reason is not convenience. Satisfactory's game traffic is **raw UDP on
7777**. Caddy is an HTTP reverse proxy; there is no configuration of it that
carries this, because there is no HTTP request to route. The choice is between
publishing the port and not running the server. The DDNS controller that used to
hold the exception was the same shape — raw UDP a proxy cannot carry — which is
the bar for anything that gets added here in future. "This was easier" is not.

**What this actually exposes.** Three ports on the WAN address with nothing in
front of them:

| Port | Protocol | Carries | Guarded by |
|---|---|---|---|
| 7777 | UDP | the game | the game's session handshake |
| 7777 | TCP | reliable messaging | same |
| 8888 | TCP | the server API | the admin/claim password, over self-signed TLS |

That is a C++ game server, written by a game studio, listening to the open
internet — a meaningfully different risk class from Immich behind Caddy and
CrowdSec, and it is being accepted knowingly. Two things bound it: the container
is not on `proxy`, so a compromise of it reaches no other stack over the network,
and it holds no docker socket and no elevated capabilities, unlike
[Beszel's agent](#and-it-holds-the-docker-socket-which-is-the-actual-cost). The
blast radius is one container, one bind mount, and outbound internet.

The alternative was Tailscale, and it was rejected for the same reason it was
rejected for Immich: it requires every participant to install something and hold
an account. A game server whose players are "whoever is around this weekend" does
not survive that. The difference from Immich is that here the fallback is worse,
not better — Immich at least has its own login.

**What the check no longer buys.** With two names in `ALLOWED_PUBLISHERS`, it
verifies the set of publishing *containers*, not the set of published *ports*. A
fourth port appearing on `satisfactory` passes silently. `ufw status` and the
router's forward list are now the things to read after any change, and that is a
real reduction in what bootstrap.sh proves.

**The reversal, if it comes.** Take the entry back out of `ALLOWED_PUBLISHERS`,
drop the router forwards, and run it LAN-only or over Tailscale. Nothing about
the stack's data or config depends on being public — see
[satisfactory.md](satisfactory.md#exposure).

## Homelable is LAN-only, and that is not a "for now"

Added 2026-08-13. A visual canvas for the network — you draw the house, it
keeps the nodes coloured by whether they answer. `lab.<domain>`, in the
LAN-only block, and it belongs there more firmly than anything else in that
block including Frigate.

The argument is short. Frigate is the worst-case-if-breached service because it
is cameras. Homelable is the worst-case-if-*read* service, which is a different
axis: it is a drawn diagram of every host in the house, its open ports and its
service versions, assembled and kept current. Breaching it gets an attacker
nothing directly. Reading it hands them the week of reconnaissance they would
otherwise have to do noisily.

That also means the usual escape hatch does not apply. "Put strong auth on it
and expose it" is how Immich got public, and it was the right call there
because Immich's value *is* remote access — see
[Public exposure](#public-exposure-chosen-over-the-alternatives). Homelable has
no remote use case at all. Nobody needs the network map from a hotel. If that
ever changes, the answer is Tailscale, not a hostname.

### The container, not the HACS integration

Homelable ships two independent implementations: the Docker stack, and a Home
Assistant custom integration that reimplements the panel inside HA. They keep
separate databases and do not sync, so this is a choice, not an ordering.

The container won on two counts. It is the larger implementation — nmap-based
service detection, rack canvas, floor plans, Proxmox and MQTT importers, all
absent from the integration. And it is the one that stays in git: HACS
integrations live in `custom_components` and `.storage`, outside this repo,
invisible to `deploy.sh`, and updated by clicking a button in a web UI. That is
precisely the drift this repo exists to prevent
([Git is the source of truth](#git-is-the-source-of-truth-with-no-ui-allowed-to-compete)),
and Home Assistant is already
[the one stack allowed to escape it](#home-assistant-partially-escapes-git).
Granting a second exception to the same rule, for the same stack, for a tool
whose whole job is documenting the network accurately, reads badly.

What the integration had that the container does not is free authentication.
Caddy's LAN guard plus a bcrypt hash in Infisical covers it for less.

### The scanner is bridged, and gives up MAC addresses

The backend sits on the stack's own bridge network, which means its ARP cache
is the container's, not the host's. The scanner reads `/proc/net/arp`, so two
things are lost: MAC addresses and vendor identification on every node, and any
device that answers ARP but drops ICMP. Ping, nmap and reverse DNS all work
normally through the NAT.

`network_mode: host` fixes it and was rejected. It would put uvicorn on
0.0.0.0:8000 across every interface on `forge`. The one host-networked
container in this repo binds a unix socket and publishes no TCP port at all,
and that is the entire basis on which it was accepted
([the agent is on the host network](#beszels-agent-is-on-the-host-network)).
Reusing the exception without reusing the property that justified it would
quietly turn a narrow carve-out into a precedent.

Macvlan is the real answer if vendor names ever matter — its own LAN address,
its own ARP table, no listener on the host. It costs a reserved IP and the
macvlan rule that the host cannot reach the container, which matters because
Caddy is on the host and would then need the frontend to stay put while only
the backend moves. Filed under
[Still open](#still-open) rather than done, because nothing is currently
blocked on it.

## Still open
- **A backup for Home Assistant's data directory.** HA Container has no backup
  UI, and `/srv/homeassistant/config/.storage` holds every credential HA has.
  Nothing covers it today.
- **A socket proxy in front of Beszel's agent** — now a two-part job, not one.
  Proxying the socket without also reverting the S.M.A.R.T. block changes
  nothing, because `SYS_ADMIN` and `/dev/nvme0` keep the container
  root-equivalent on their own. Either both, or neither, or a different way to
  read drive health. See [SMART is on](#smart-is-on-and-it-prices-the-socket-proxy-in).
- **A backup for `/srv/beszel/data`.** It holds the alert rules, which are not
  in git — the same gap Home Assistant has.
- **Immich transcoding on the now-idle iGPU.** Free performance, unclaimed.
- **Backups.** The photo library will exist in exactly one place on one NVMe.
  `rclone` to OneDrive is the intended answer; until it runs, this is the
  largest unmitigated risk in the build.
- **Off-box copies of the Satisfactory saves.** `/srv/satisfactory/backups` is
  on the same NVMe as `/srv/satisfactory/saved`, so it covers a corrupt save and
  nothing else. The same gap Home Assistant and Beszel have, with lower stakes.
  See [satisfactory.md](satisfactory.md#backups).
- **A macvlan network for Homelable's scanner.** Bridged, it cannot read MAC
  addresses or see devices that drop ICMP — see
  [the scanner is bridged](#the-scanner-is-bridged-and-gives-up-mac-addresses).
  Nothing is blocked on it; it buys vendor names and silent IoT.
- **A backup for `/srv/homelable/data`.** The hand-drawn map and any floor
  plans. The scanner can redraw most of it, which is why this sits below the
  others on the same list.
- **Remote access for administration.** Tailscale remains the low-risk answer
  and is now complementary rather than an alternative — public 443 for Immich,
  Tailscale for everything that should never be public.
