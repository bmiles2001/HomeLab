# Immich — deploy runbook

Everything needed to get `photos.brent-miles.com` serving, LAN-only, from
whatever state `forge` is in right now. Written 2026-07-29.

Verified against upstream today: **v3.0.3 is current** (released 2026-07-14),
and the `postgres:14-vectorchord0.4.3-pgvectors0.2.0` tag in
`stacks/immich/compose.yml` matches the tag in upstream's v3 compose file
exactly. The pin is good; don't move it.

The OneDrive mirror is deliberately out of scope. Stop at step 7.

---

## 0. Preflight — find out where you actually are

You've been at this for two days; don't guess. Run this and read the output.

```bash
ssh forge
cd ~/home-containers && git pull
./bootstrap.sh
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

Then match against this table and start at the first row that isn't true:

| Check | Expected | If not |
|---|---|---|
| `bootstrap.sh` all-green except stray-port warnings | — | fix what it names before continuing |
| `infisical_backend` running | yes | §1 |
| `infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/caddy` returns 3 keys | yes | §1 |
| `caddy` running, publishing 443 | yes | §2 |
| `docker logs caddy 2>&1 \| grep -i "certificate obtained"` | one line | §2 |
| `immich_server` running | no, yet | §3 — you're here |

If `caddy` is running but you never saw the cert land, do §2 before anything
else. Immich behind a proxy with no certificate is two problems wearing one
coat, and you won't be able to tell them apart.

---

## 1. Infisical up, and the `/immich` folder populated

Skip the first two commands if Infisical is already running.

```bash
cd ~/home-containers/stacks/infisical
docker compose up -d
docker compose ps          # infisical_backend must be healthy, not just up
```

Now put Immich's secrets in. Use the CLI — it's faster and it's the same path
`deploy.sh` will take, so if it works here it works there:

```bash
# on forge, with ~/.infisical-identity sourced
DB_PW=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32)
echo "$DB_PW"        # paste into your password manager NOW

infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/immich \
  DB_PASSWORD="$DB_PW" \
  DB_USERNAME=postgres \
  DB_DATABASE_NAME=immich \
  IMMICH_VERSION=v3.0.3 \
  TZ=America/Chicago
```

Two things about that password, both of which will bite silently:

**Alphanumeric only.** Immich's own docs now say to restrict `DB_PASSWORD` to
`A-Za-z0-9`. `stacks/immich/.env.example` suggests
`openssl rand -base64 32 | tr -d '/+='`, which leaves `=` padding in the value.
The command above is the corrected version — I've also fixed the comment in
`.env.example`.

**Leave `DB_USERNAME` as `postgres`.** `scripts/immich-onedrive-sync.sh`
hardcodes `POSTGRES_USER` defaulting to `postgres` for its `pg_dumpall`. Change
one and you break the other, and you find out when a backup you thought was
running turns out to be an empty file.

Confirm:

```bash
infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/immich
```

The web UI, if you'd rather click, is at `https://secrets.brent-miles.com` —
but only once Caddy is up, because Infisical publishes no host ports either.
(`docs/secrets.md` still says you can reach it at `http://localhost:8080`
before Caddy exists. That's left over from an earlier draft and isn't true;
I've corrected it.)

---

## 2. Caddy, only if it isn't already serving a cert

```bash
cd ~/home-containers
./scripts/deploy.sh caddy
docker logs -f caddy
```

You're waiting for `certificate obtained successfully` for `*.brent-miles.com`.
DNS-01 takes a minute or two. If it stalls or errors:

- **`could not determine zone for domain`** — the `CF_API_TOKEN` in Infisical
  is wrong or scoped to the wrong zone. It needs Zone > DNS > Edit on
  `brent-miles.com`.
- **Rate-limit errors** — uncomment `acme_ca` (the staging line) in the
  Caddyfile's global block, get routing working, then comment it back out.
  Staging certs are untrusted; that's expected.
- **Nothing in the log at all** — `DOMAIN` isn't set in Infisical under
  `/caddy`, so the site block never matched anything.

The Immich route is **already in `stacks/caddy/Caddyfile`** and points at
`immich_server:2283`. Caddy resolves upstreams at dial time rather than at
config load, so it started fine with that name unresolvable and will simply
begin working the moment the container joins the `proxy` network. **No Caddy
reload is needed in step 3.** This is the exception to the README's four-step
"adding an app" recipe — the three lines were written ahead of time.

---

## 3. GPU sanity check, then deploy

You verified driver 595.84 and container passthrough yesterday, but the ML
container will refuse to start if anything shifted — and `unattended-upgrades`
pulling a new NVIDIA package overnight is exactly the failure your own runbook
warned about. Thirty seconds:

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
```

Both must print the 3080. If the second one fails and the first succeeds, the
host driver moved out from under the toolkit — `sudo apt install --reinstall
nvidia-container-toolkit && sudo systemctl restart docker`.

The `deploy.resources` block in `compose.yml` is byte-for-byte upstream's
`cuda` service from `hwaccel.ml.yml`, so this is the supported configuration,
not an improvisation.

Dry run first — it prints the fully resolved config and changes nothing:

```bash
cd ~/home-containers
./scripts/deploy.sh immich --dry-run
```

Read it for `${...}` that didn't get substituted. Then:

```bash
./scripts/deploy.sh immich
```

Four containers: `immich_server`, `immich_machine_learning`, `immich_redis`,
`immich_postgres`.

```bash
docker logs -f immich_server
```

First start runs schema migrations against an empty database and takes a minute
or two. You want `Immich Server is listening on ... [v3.0.3]`.

### If something doesn't come up

- **`immich_postgres` restart-loops** — almost always the password. Because
  Postgres only reads `POSTGRES_PASSWORD` when it *initialises* the volume,
  fixing the secret afterwards doesn't help. On a fresh install the fix is
  cheap: `docker compose down -v` in `stacks/immich`, then redeploy. Do **not**
  run that once you have photos in there.
- **`immich_machine_learning` exits immediately** — GPU. Check
  `docker logs immich_machine_learning` for `libnvidia-ml.so.1`, which means
  the driver isn't visible. The server works fine without ML; face detection
  and smart search just don't run. Not a reason to stop.
- **`redis` fails to pull** — the repo pins `valkey/valkey:9-bookworm` where
  upstream uses `valkey/valkey:9`. If the tag has gone away, use `valkey:9`.
- **`bootstrap.sh` warns about stray published ports** — something other than
  Caddy is publishing. Fix it; that's the one architectural rule this whole
  setup rests on.

---

## 4. First login, before anyone else touches it

Browse to `https://photos.brent-miles.com` from a machine **inside the house**.
You should get a valid padlock and the Immich "Getting Started" page.

**The first person to load that page becomes admin.** Register yourself now,
before you tell anyone the URL.

Then immediately lock the door behind you. Add to Infisical under `/immich`:

```bash
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/immich \
  IMMICH_ALLOW_SETUP=false
```

then `./scripts/deploy.sh immich` again. (`compose.yml` already carries
`IMMICH_ALLOW_SETUP: ${IMMICH_ALLOW_SETUP:-true}` on `immich-server`, so this
is a secret change and a redeploy, not a file edit.)

That disables the `/auth/admin-sign-up` endpoint. It matters little today
behind a closed router, and it matters a great deal the day you forward 443 —
and this is the only moment you'll remember to do it.

### If the page doesn't load

- **Padlock warning** — you're on a staging cert from §2, or DNS resolved to
  something other than `10.0.0.4`. Check with `nslookup photos.brent-miles.com`
  from your PC.
- **Connection refused / 502** — Caddy can't reach the container.
  `docker network inspect proxy` and confirm both `caddy` and `immich_server`
  are listed. If Immich isn't there, its `proxy` network membership didn't take.
- **Times out from outside the house** — correct. That's the design.

---

## 5. Settings that are painful to change later

**Administration → Settings → Storage Template.** Enable it, then set:

```
{{y}}/{{y}}-{{MM}}/{{filename}}
```

Do this **before** uploading anything. Without it, files sit in a UUID tree,
which is unreadable if you ever open the OneDrive copy directly. With it you get
`library/admin/2026/2026-07/IMG_4021.HEIC`. Changing it later means running the
Storage Template Migration job over the whole library — possible, but it
rewrites every path and the OneDrive mirror then re-uploads all of it.

**Administration → Settings → Backup.** Enable scheduled database backups. This
is separate from the mirror script's own dump; both are cheap and they cover
different failure modes.

**Administration → Users.** Create accounts for your wife and daughter. Give
each a storage label if you want their photos in separate top-level folders.

---

## 6. One photo, end to end, on one phone

Do not install this on three phones and then debug. One phone, one photo.

1. Immich from the App Store, server URL `https://photos.brent-miles.com`.
2. Log in as yourself.
3. **iOS Settings → Immich → Background App Refresh: ON.** Background backup
   silently never runs without this and gives you no warning.
4. Backup screen (cloud icon, top right) → pick albums → Enable Backup.
5. Take a photo. Watch it appear in the web UI.

Then confirm it landed where you expect on disk:

```bash
ls -R /srv/immich/data/library/
```

You should see the `2026/2026-07/` shape from step 5. If you see UUIDs, the
storage template didn't take — fix it now, while the library is one photo.

Only then install on the other two phones.

---

## 7. Verify, and write it down

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}'   # 4 immich + caddy + infisical
nvidia-smi                                           # ML process visible during an import
du -sh /srv/immich/data/*
docker exec immich_postgres pg_isready -U postgres
```

Commit the `IMMICH_ALLOW_SETUP` change and this doc's outcome. If you changed
anything on the host directly to make it work, that's rule one broken — put it
in the repo before you close the terminal.

---

## What's now due

In the order the risk actually sits:

1. **The OneDrive mirror.** As of the moment step 6 succeeds, your family's
   photos exist in exactly one place, on one NVMe, with no backup. This is the
   largest unmitigated risk in the build and it gets worse every day the
   library grows.
2. **Restore test.** `scripts/immich-onedrive-sync.sh` gives you back files,
   not albums and faces. Test the full restore on a throwaway second install
   while the library is small enough that it takes ten minutes.
3. **Public 443.** Forward the port, CrowdSec on the Caddy logs, and set
   `IMMICH_TRUSTED_PROXIES` so Immich sees real client IPs instead of Caddy's
   container address. Its own rate limiting is useless without that. Separate
   session, clear head.
4. **Hardware transcoding.** Optional, and the 3080 can do it: `nvenc` needs
   `capabilities: [gpu, compute, video]` on `immich-server`, which is a
   different capability set than the ML block. Worth it once there's video
   volume, not before.
5. **Komodo.** Immich now works, which was the stated precondition.

## Sources

- [Immich — Docker Compose install](https://docs.immich.app/install/docker-compose)
- [Immich — Environment variables](https://docs.immich.app/install/environment-variables)
- [Immich — Post installation steps](https://docs.immich.app/install/post-install)
- [Immich — v3.0.0 release notes](https://immich.app/blog/v3.0.0-release)
- [upstream `docker-compose.yml`](https://github.com/immich-app/immich/blob/main/docker/docker-compose.yml)
- [upstream `hwaccel.ml.yml`](https://github.com/immich-app/immich/blob/main/docker/hwaccel.ml.yml)
