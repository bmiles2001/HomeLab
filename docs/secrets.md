# Secrets

No credential is ever written to a file in this repo. Compose files contain
`${VAR}` and nothing else. At deploy time `infisical run` fetches the values,
sets them as environment variables, and compose interpolates them — plaintext
never touches disk.

```
your PC ──git push──> GitHub ──git pull──> host
                                            │
                                            ├─ compose.yml  (${CF_API_TOKEN})
                                            │
Infisical ──infisical run──> environment ───┘──> docker compose up -d
```

## The one exception

Infisical cannot fetch its own secrets from itself. `stacks/infisical/.env` is
a real file, gitignored, holding four values. Keep a copy in your password
manager — **especially `ENCRYPTION_KEY`**, without which a database backup is
an unreadable blob.

That's the entire bootstrap chain: one file on the host, one copy in 1Password
or Bitwarden. Everything else derives from it.

## Version pinning — read before you bump

The server and the CLI have to be roughly contemporaries. The CLI talks to
`/api/v4/secrets`; a server older than that route answers `404 Route ... not
found`, which reads like a project or permissions problem and is neither.

**Never use the `latest-postgres` tag.** It was frozen 2025-08-08 and is a
relic of the Mongo→Postgres migration. `compose.yml` pins an explicit `vX.Y.Z`;
check <https://hub.docker.com/r/infisical/infisical/tags> before changing it.

## Setup, once

### 1. Bring up Infisical

```bash
cd stacks/infisical
cp .env.example .env
openssl rand -hex 16       # -> ENCRYPTION_KEY
openssl rand -base64 32    # -> AUTH_SECRET
openssl rand -base64 32 | tr -d '/+='   # -> DB_PASSWORD
$EDITOR .env
docker compose up -d
```

Reach it at `https://secrets.brent-miles.com` — **only** once Caddy is up.
Infisical publishes no host ports (only Caddy does), so there is no
`http://localhost:8080` to fall back on. If you need the UI before Caddy
exists, publish `127.0.0.1:8080:8080` on the `backend` service temporarily and
remove it again afterwards; otherwise use the CLI.

Create the admin account immediately — the first person to hit a fresh
Infisical becomes the admin.

### 2. Create a project and folders

One project, environment `prod`, with a folder per stack matching the
directory name in `stacks/`:

```
/caddy      CF_API_TOKEN, DOMAIN, ACME_EMAIL
/immich     DB_PASSWORD, DB_USERNAME, TZ, IMMICH_VERSION,
            IMMICH_ALLOW_SETUP, IMMICH_TRUSTED_PROXIES
/ddns       CF_DDNS_TOKEN, DOMAIN, TZ
```

`/ddns` holds a **second, separate** Cloudflare token rather than reusing
`/caddy`'s. The permissions are identical, so this buys nothing against a
determined attacker — it buys blast radius when *you* revoke one at 11pm.
Rotating the DDNS token shouldn't be able to stop certificate renewal.

Each stack's `.env.example` documents exactly which keys it expects. Those
files are documentation now — never copy one to `.env`.

### 3. Install the CLI on the host

```bash
curl -1sLf 'https://artifacts-cli.infisical.com/setup.deb.sh' | sudo -E bash
sudo apt-get install -y infisical
```

### 4. Give the host a machine identity

The host authenticates as a machine, not as you. In the Infisical UI:
**Organization Access Control → Identities → Create identity**, Universal
Auth, then grant it read access to the project.

Store the resulting client ID and secret on the host, along with the project ID
from **Project → Settings → General → Project ID**:

```bash
umask 077
cat > ~/.infisical-identity <<'EOF'
export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=...
export INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=...
export INFISICAL_PROJECT_ID=...
EOF
echo 'source ~/.infisical-identity' >> ~/.bashrc
```

That file is `chmod 600` and outside the repo. It's the one local secret worth
protecting properly — treat it like an SSH private key.

The project ID isn't a secret, but it belongs here so `deploy.sh` can run from
any directory. `deploy.sh` passes it as `--projectId` rather than relying on an
`infisical init`-generated `.infisical.json`, because the script `cd`s into the
stack directory and cwd-based project discovery is one more thing that can drift
without saying so.

Confirm it works:

```bash
infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/caddy
```

## Daily use

```bash
./scripts/deploy.sh caddy            # inject and deploy
./scripts/deploy.sh immich --dry-run # print resolved config, change nothing
```

`deploy.sh` refuses to run if it finds a `.env` in a stack directory. That
guard exists because the failure mode isn't dramatic — it's someone quietly
dropping a `.env` at 1am to unblock themselves, after which the repo has
stopped being true and nobody notices for six months.

## What this costs you

**Infisical must be running to deploy.** It does *not* need to be running for
a reboot: containers keep their environment across restarts, so
`restart: unless-stopped` brings everything back without it. The dependency
only bites when you're changing something — which is when you're at the
keyboard anyway. That's the whole chicken-and-egg problem, and it's smaller
than it first looks.

**Its database is now critical infrastructure.** Losing
`infisical_pgdata` loses every credential for every stack simultaneously. Set
up the backup before migrating anything real:

```bash
sudo install -m 755 scripts/infisical-backup.sh /usr/local/bin/
sudo systemd-run --on-calendar=daily --unit=infisical-backup \
  /usr/local/bin/infisical-backup.sh
```

Test a restore once. A backup you haven't restored from is a hypothesis.

## Rotating the Cloudflare tokens

There are two of them now, and they rotate independently. That's the point.

**Caddy's** (`/caddy` → `CF_API_TOKEN`) writes short-lived `_acme-challenge`
TXT records for DNS-01 and deletes them again. Revoking it breaks certificate
renewal, which you won't notice for up to 60 days.

**DDNS's** (`/ddns` → `CF_DDNS_TOKEN`) writes the `photos` A record every few
minutes. Revoking it breaks remote access the next time the WAN address
changes.

Either way, 30 seconds:

1. Revoke and recreate at <https://dash.cloudflare.com/profile/api-tokens>
   using the **Edit zone DNS** template, scoped to one zone.
2. Update the relevant key in Infisical under `/caddy` or `/ddns`.
3. `./scripts/deploy.sh caddy` or `./scripts/deploy.sh ddns`.

No file edited, no commit, no chance of it ending up in git history.

Cloudflare's newer tokens are prefixed and "scannable" (`cfut_`, `cfat_`).
That's what broke the older Caddy images — see the note in
`stacks/caddy/compose.yml` before assuming a new token is bad.
