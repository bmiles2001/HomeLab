# Home containers

Docker on `forge`, a bare-metal Ubuntu Server box. Every app on a real hostname
under `brent-miles.com` with a valid certificate, and the family photo library
mirrored to OneDrive.

**This repo is the source of truth.** If something is running that isn't
described here, it's a bug. If something is described here that isn't running,
one command fixes it.

```
bootstrap.sh          run once on a fresh machine - network, dirs, sanity checks
stacks/
  infisical/          secrets store. The only stack with a real .env file.
  caddy/              reverse proxy. The only stack that publishes ports.
  immich/             photo server
  frigate/            camera NVR. LAN-only, permanently.
scripts/
  deploy.sh           deploy a stack with secrets injected from Infisical
  infisical-backup.sh nightly dump of the secrets database
  immich-onedrive-*   one-way mirror of the photo library to OneDrive
docs/
  forge-session-runbook.md   build order: hardening, docker, first stacks
  immich-deploy.md           step-by-step: secrets, deploy, first login, iPhones
  photo-app-comparison.md    why Immich and not the others
  frigate.md                 GPU split, storage budget, why it stays off the internet
  secrets.md                 Infisical setup and the daily workflow
  remote-access.md           editing from your main PC
  decisions.md               why this is shaped the way it is
home-server-build-plan.md    hardware, BIOS, storage, GPU, everything non-container
```

Nothing is reachable from the internet **yet**. Ports 80/443 stay closed on the
router; DNS points at a private address that only resolves usefully from
inside the house. Opening 443 for `photos.brent-miles.com` is planned and has
its own prerequisites — see [docs/decisions.md](docs/decisions.md).

---

## The two rules

**1. Never edit on the host.** Edit on your main PC, commit, push, pull on the
host, deploy. SSH in to read logs and debug, not to change files. The moment
you fix something directly on the server, this repo starts lying to you.

**2. Only Caddy publishes ports.** Every other stack joins the shared `proxy`
network and is reached by container name. This is not just tidiness: Docker
writes its iptables rules ahead of UFW's, so a published port is reachable
from the LAN no matter what `ufw status` claims. One container publishing
ports is a decision; two is an accident.

---

## First run

```bash
git clone git@github.com:<you>/home-containers.git ~/home-containers
cd ~/home-containers
./bootstrap.sh
```

Then, in order, because each depends on the one before:

```bash
# 1. Infisical - has no dependencies, holds everyone else's secrets
cd stacks/infisical
cp .env.example .env && $EDITOR .env      # see docs/secrets.md
docker compose up -d

# 2. Caddy - needs CF_API_TOKEN, DOMAIN, ACME_EMAIL in Infisical under /caddy
cd ../.. && ./scripts/deploy.sh caddy

# 3. Apps
./scripts/deploy.sh immich
```

First Caddy start takes a minute or two while the wildcard certificate is
issued over DNS-01. Watch it with `docker logs -f caddy`.

---

## Cloudflare

One wildcard A record, and you never touch the dashboard again:

| Type | Name | Content      | Proxy status              |
| ---- | ---- | ------------ | ------------------------- |
| A    | `*`  | `10.0.0.4` | **DNS only** (grey cloud) |

It must be grey-clouded. Cloudflare cannot proxy to a private address, and
orange-clouding it produces a confusing 522.

**Tradeoff:** this publishes `10.0.0.4` to anyone who queries your DNS. It's
an unroutable address so it grants no access, but it does confirm you run
something at home. The alternative is AdGuard Home on this box with a local
wildcard rewrite, pointed at from your router's DHCP — then nothing about your
internal layout leaves the house, and the family gets ad blocking. Caddy still
needs the Cloudflare token either way, because DNS-01 talks to Cloudflare
directly.

The API token is scoped to Zone > DNS > Edit on one zone. Caddy uses it only
to write a short-lived `_acme-challenge` TXT record and delete it again.

---

## Adding an app

Four steps, no DNS record and no new certificate:

1. `stacks/<app>/compose.yml` — join the `proxy` network, publish no ports.
2. Put its secrets in Infisical under `/<app>`.
3. Three lines in `stacks/caddy/Caddyfile` pointing at `container_name:port`.
4. `./scripts/deploy.sh <app>` then
   `docker exec caddy caddy reload --config /etc/caddy/Caddyfile`.

Routes point at container names rather than `10.0.0.4:PORT` because every
stack joins one shared `proxy` network, where Docker's embedded DNS resolves
container names. Container IPs change on restart; names don't. Caddy also
re-resolves upstreams at dial time, so IP churn never needs a reload.

---

## Immich

After first login at `https://photos.brent-miles.com`:

**Administration → Settings → Storage Template** — enable it and use:

```
{{y}}/{{y}}-{{MM}}/{{filename}}
```

This matters for the OneDrive half. Without it, files sit in a UUID tree
that's unreadable if you ever open the OneDrive copy directly. With it you get
`library/admin/2026/2026-07/IMG_4021.HEIC`.

**Administration → Settings → Backup** — enable scheduled database backups.

**iPhones:** install Immich from the App Store, point it at
`https://photos.brent-miles.com`, pick albums under Backup. iOS grants
background upload time opportunistically, so opening the app once a day
guarantees a flush. Because this is LAN-only, photos taken away from home
queue up and upload when you get back on wifi.

### The OneDrive mirror

A **one-way push**, not a sync. Immich is the source of truth; OneDrive is a
copy. Editing or deleting a file in OneDrive does nothing to Immich and gets
undone on the next run. Deletions in Immich move the OneDrive copy into a
dated `Immich-deleted/` folder rather than erasing it.

Skipped: `thumbs/` and `encoded-video/` — both regenerate from originals, and
syncing them can double your OneDrive usage for zero recovery value.

Install:

```bash
sudo install -m 755 scripts/immich-onedrive-sync.sh /usr/local/bin/
sudo cp scripts/immich-onedrive-sync.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now immich-onedrive-sync.timer
```

Dry run first, always: `sudo /usr/local/bin/immich-onedrive-sync.sh --dry-run`

**Restoring.** The OneDrive copy gives you back your *files*, not your
*library* — albums, faces and shared links live in Postgres. A real restore is:
bring up the stack, `rclone copy` the data back, then load the newest dump.
Test that once now on an empty second install, rather than discovering the gap
when you need it.

---

## Backups, ranked by how much it hurts to lose

| Thing                       | Where                       | Covered by                  |
| --------------------------- | --------------------------- | --------------------------- |
| Infisical database          | `infisical_pgdata` volume   | `scripts/infisical-backup.sh` |
| Infisical `ENCRYPTION_KEY`  | `stacks/infisical/.env`     | **your password manager**   |
| Immich Postgres             | `pgdata` volume             | dump inside the OneDrive mirror |
| Photos                      | `/srv/immich/data`          | OneDrive mirror             |
| Caddy certs + ACME account  | `caddy_data` volume         | nothing - reissued on demand |
| Everything else             | this repo                   | GitHub                      |

There is no longer a "the whole machine is one file" escape hatch — that was a
WSL convenience and it went away with WSL. The replacement is a real backup
discipline: the table above, plus the OS itself being reproducible from
`bootstrap.sh` and this repo. Nothing here assumes the boot drive survives.

---

## Capacity

2TB NVMe holds a lot of photos, but Immich stores originals plus generated
thumbnails and transcodes, so plan on roughly 1.3–1.5× your raw library size.
It's now a plain ext4 filesystem — what `df` says is what you have, with no
virtual disk that grows and never shrinks.

Immich's machine learning wants 6–8GB RAM. With 32GB in the box that's a
non-issue, and the RTX 3080 makes the `-cuda` ML image worth switching to once
the library is imported.

Watch it with `du -sh /srv/immich/data/*` occasionally.

---

## Deliberately not done yet

- **Public access to `photos.brent-miles.com`.** Decided but not built: forward
  443 to Caddy, CrowdSec on the Caddy logs, Immich the only public hostname.
  Immich ships no brute-force protection of its own, so that's the proxy's job.
- **Tailscale**, for administration. Complementary to the above rather than an
  alternative — public 443 for Immich, Tailscale for everything that should
  never be public.
- **Komodo**, for git-push→deploy. Ruled out under Podman-on-WSL because its
  agent needs a real Docker socket; that objection died with the pivot. Adopt
  it after Immich works, so its first stack is one you already trust.
- **Backups.** The photo library will exist in exactly one place on one NVMe
  until the OneDrive mirror runs. Largest unmitigated risk in the build.
- **A family dashboard.** Homepage, when there are enough apps to warrant it.
