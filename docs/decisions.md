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

## Still open

- **Frigate recording budget.** Continuous recording of four cameras for a week
  is over a terabyte — most of the NVMe, competing with the photo library it was
  bought for. `record.retain.mode: motion` is the interim answer; a dedicated
  spinning disk for recordings is the real one.
- **Backups.** The photo library will exist in exactly one place on one NVMe.
  `rclone` to OneDrive is the intended answer; until it runs, this is the
  largest unmitigated risk in the build.
- **Remote access for administration.** Tailscale remains the low-risk answer
  and is now complementary rather than an alternative — public 443 for Immich,
  Tailscale for everything that should never be public.
