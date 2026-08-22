# Komodo

Container UI and deploy orchestrator for `forge`. Adopted on the condition that
it owns nothing — not secrets, not stack configuration, not the compose files.

`docs/decisions.md#komodo--rejected` rejected it on 2026-08-03 because "Komodo
wants to own environment variables and secrets, and that collides directly with
`scripts/deploy.sh` injecting them from Infisical." That objection is answered
here rather than waved away: Komodo is wired up as a *consumer* of Infisical,
with three config fields and one script standing between it and the secrets.

---

## What owns what

| Thing | Owner | Komodo's relationship to it |
|---|---|---|
| Secret values | Infisical | fetched at deploy time by `scripts/komodo-env.sh`, never stored |
| Compose files | this repo, on disk | read in place (`files_on_host`) |
| Stack configuration | `komodo/*.toml` in this repo | Resource Sync in `managed` mode; its database is a cache |
| Host state | forge | not in this repo — same caveat as [cockpit.md](cockpit.md) |

Three Stack fields do the load-bearing work, and all three are set in
`komodo/beszel.toml` with the reasoning inline:

- `environment = ""` — Komodo writes this field to `env_file_path`,
  **overwriting the file**. Anything typed into the Environment box in the UI
  would clobber the rendered secrets on the next deploy.
- `env_file_path = ".env"` — left at the default on purpose. Passing
  `--env-file` to compose suppresses the automatic `.env` lookup, so a decoy
  filename would cause the symlink to be silently ignored.
- `skip_secret_interp = true` — Komodo's own Variables/Secrets store stays
  unused, and an accidental entry in it stays inert.

---

## Komodo stores no credentials

Not "as few as possible" — none. Three separate things get confused under the
word "secrets", and all three are settled:

**1. Komodo's Variables/Secrets store** (the `[[KEY]]` interpolation feature,
Settings → Variables). Unused. `skip_secret_interp = true` on every stack means
an entry accidentally made there is inert rather than active.

**2. Komodo's own runtime secrets** — database password, JWT secret, webhook
secret, initial admin password. These live in Infisical under `/komodo` and are
injected by `./scripts/deploy.sh komodo` like any other stack's. Komodo is not a
special case here; it is just another consumer.

**3. Stack secrets.** Rendered per deploy by `scripts/komodo-env.sh`, onto tmpfs,
removed afterwards. Covered above.

### The one thing Infisical cannot hold

A **git provider token**, if the Repo resource ever needs one. It cannot come
from Infisical, because Komodo would need it to clone before anything has run
that could fetch it — and unlike Core's other settings, `[[git_provider]]`
accounts support neither environment variables nor the `_FILE` syntax. TOML or
the UI only.

You most likely need zero of them:

- If `bmiles2001/HomeLab` is public, no token is involved at all.
- If it is private, the simplest answer is to not give Komodo git at all — SSH
  in, `git pull --ff-only`, and press Deploy. That is level 1 in
  [Deploying: on demand](#deploying-on-demand), and it costs one command.
- If you do want Komodo pulling a private repo, put the account in
  **`/etc/komodo/periphery.config.toml`**, not the UI. A `[[git_provider]]`
  block there is scoped to this server and sits next to the identity file as
  host state; the same block in Core's config or the UI would be global and
  live in its database.

### The credential that stays on disk regardless

`/etc/komodo/infisical-identity`. The thing used to *read* Infisical cannot
itself be stored in Infisical, so the chain terminates in your password manager
— exactly as `docs/decisions.md#infisical-for-secrets` already says of
`~/.infisical-identity` and `stacks/infisical/.env`. This is a third instance of
an accepted pattern, not a new compromise.

---

## The deploy sequence

Read out of `bin/periphery/src/api/compose.rs` rather than inferred, because
two steps of it are the whole design:

1. interpolate → **2. write stack files, including the env file** → 3. validate
→ 4. registry login → **5. pre_deploy** → 6. compose config → 7. build →
8. pull → 9. down → **10. `docker compose up -d`** → **11. post_deploy**

Two consequences:

**Step 2 happens before step 5.** Komodo writes its own (empty) `.env` first,
then `komodo-env.sh render` replaces it. Our file wins. If this ever reverses in
an upstream release, secrets stop arriving and every variable resolves to empty
— which, given the `${VAR:-}` convention, would start containers *successfully*
and wrong. That is the failure mode to watch for after a Komodo upgrade.

**Step 11 is gated on `res.deployed`.** A failed `compose up` skips post_deploy
entirely. Cleanup therefore cannot be the only protection, which is why the
rendered file lives on tmpfs.

---

## Where the secrets go

`scripts/komodo-env.sh render <stack>` writes `/dev/shm/komodo-env/<stack>.env`
(0600, in a 0700 directory) and symlinks it as `stacks/<stack>/.env`. Nothing
touches the NVMe. `clean` removes the tmpfs file and leaves the symlink
dangling.

That dangling state was tested, not assumed:

| | Behaviour |
|---|---|
| `docker compose config/ps/logs/down` in the stack dir | works, exit 0, variables resolve empty — harmless because of the `${VAR:-}` convention |
| `deploy.sh`'s `[[ -f "$STACK_DIR/.env" ]]` guard | reads it as **absent** (`-f` follows symlinks) |
| A *live* leftover from a failed Komodo deploy | guard **fires**, loudly, next time you run `deploy.sh` by hand |

So the guard rail written for the old workflow becomes the leftover detector for
the new one, at no cost. Do not "fix" it to use `-e`.

### The quoting trap

Compose interpolates the `.env` file, so `AUTH_PASSWORD_HASH=$2b$12$KIXQ0…`
written raw loses everything from the third `$` onward — `$KIXQ0…` is read as an
unset variable and expands to nothing. It arrives as `$2b$12`, with no warning
and no error, and you find out when you cannot log in.

The note in [homelable.md](homelable.md) that says no `$$` escaping is needed is
true for `infisical run` and **false the moment a file is in the path**.

`komodo-env.sh` therefore renders the file itself, from
`infisical export --format=json`, double-quoted with `\`, `"` and `$`
backslash-escaped. Verified against `docker compose config` to round-trip `$`,
`'`, `"`, `\`, backticks, `#`, `=`, leading and trailing spaces, and embedded
newlines. Single-quoting was rejected — dotenv single quotes have no escape
sequence, so a value containing an apostrophe cannot be represented.

---

## Periphery

**Install the systemd binary, not the container.** `pre_deploy` runs inside
whatever Periphery is, so a containerised agent would run `komodo-env.sh` in a
filesystem with no `infisical` CLI, no repo, and no identity.

Periphery does not run as `brent`, so `~/.infisical-identity` and `.bashrc` are
not in the picture. Give it its own credentials:

```bash
sudo install -d -m 700 /etc/komodo
sudo tee /etc/komodo/infisical-identity >/dev/null <<'EOF'
export INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=...
export INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=...
export INFISICAL_PROJECT_ID=...
EOF
sudo chmod 600 /etc/komodo/infisical-identity
```

Mint a **separate machine identity** in Infisical for this, not a copy of the
one in `~/.infisical-identity`. Two reasons: it can be revoked without locking
you out of `deploy.sh`, and its read scope can be narrowed to only the paths
Komodo deploys.

An `EnvironmentFile=` on the periphery unit works equally well — the script
prefers already-exported values and only sources the file as a fallback.

Periphery also needs `docker` group membership (root-equivalent on this box,
already accepted in `decisions.md`) and the `infisical` CLI on its `PATH`.

---

## How you reach it

`https://deploy.{DOMAIN}`, in the **LAN-only** block of the Caddyfile. No new
DNS record and no new certificate — the wildcard and the `@notlocal` guard cover
it, the same way [cockpit.md](cockpit.md) got them for free.

The subdomain is named for the function rather than the product, following
`secrets` / `security` / `home` / `status` / `lab`. Cockpit is the file's only
product-named host and only because "host" would have read worse.

```caddy
	# --- deploy.<domain> - Komodo -------------------------------------------
	@komodo host deploy.{env.DOMAIN}
	handle @komodo {
		reverse_proxy komodo:9120 {
			flush_interval -1
		}
	}
```

Core listens on **9120** (upstream's own compose publishes `9120:9120`). It
joins `proxy` and publishes nothing, so README rule 2 holds.

**This stays LAN-only permanently, and it is the strongest such case in the
file.** Beszel exposes a map of what runs on this box; Frigate exposes the
cameras; Komodo exposes the controls. Its Periphery agent holds the docker
socket, so a session here is root on forge — see `stacks/beszel/compose.yml` for
what that phrase means literally.

**Periphery is never routed through Caddy, and never listens at all.** v2 lets
the agent dial Core instead of the other way round, so it runs in *outbound*
mode against `ws://127.0.0.1:9120` — Core's loopback publish. Nothing on forge
listens for it, there is no port 8120 open to the LAN, and no firewall rule to
maintain (Cockpit's `ufw` narrowing has no equivalent here).

That is why `compose.yml` publishes `127.0.0.1:9120:9120`, and it is the third
published port on this box and the first from a container. The alternative —
inbound mode, with Core reaching the host at `host.docker.internal:8120` the way
Caddy reaches Cockpit — would have meant the agent binding a port and then
being firewalled back down. A loopback publish is the smaller exception.

---

## Deploying: on demand

LAN-only has a consequence: the repo is on GitHub, and GitHub's webhook cannot
reach a hostname the `@notlocal` guard drops. **There is no git-push-to-deploy
here**, and adding one would mean putting an internet-reachable endpoint on the
tool that holds the docker socket.

So deploys are a button, not a push. `komodo/home-containers.toml` defines a
Repo resource with `webhook_enabled = false` and a Procedure that runs
`PullRepo` then `DeployStack` in sequence — one click, from a phone on the
couch, after you have pushed from your PC.

Two levels of this, and starting at the first one costs nothing:

1. **Komodo never touches git.** SSH in, `git pull --ff-only`, then press Deploy
   in the UI. Zero new failure modes, and it is your current habit with the
   `./scripts/deploy.sh` step replaced by a button.
2. **The Procedure above.** Komodo runs the pull too. Worth knowing before you
   turn this on: a Repo resource can be told to *reclone*, which discards the
   working copy. That is survivable here only because README rule 1 already says
   forge's checkout is disposable — you edit on your PC. Do not start keeping
   local changes on forge after enabling this.

A Cloudflare Tunnel for the webhook path is the deferred upgrade. Note that
`decisions.md`'s rejection of Tunnels was specifically the free plan's 100 MB
request body limit breaking iPhone video upload — that reason does not carry
over to a webhook, which is a few KB. It would need its own decision on exposing
an inbound path to this service at all.

`scripts/deploy.sh` stays regardless. It is the manual path, the path for
anything Komodo does not manage, and the path that still works when Komodo is
the thing that is broken. The two agree on what a stack needs because
`komodo-env.sh` reads `deploy.sh --required-vars <stack>` rather than keeping a
second copy of the table.

---

## Resource Syncs

Komodo's database holds stack configuration — which repo, which run directory,
which flags. That is a store of record competing with git, which is the same
objection that ruled out Portainer's web editor.

The fix is a **Resource Sync** in `managed` mode pointed at `komodo/` in this
repo: the TOML gets full authority, and resources present in the database but
absent from the files are deleted. Edits made in the UI survive only until the
next sync, which is the correct relationship.

Bootstrapping order: build the first stack in the UI, export it to TOML, commit
that, *then* create the sync and let it take over.

---

## Getting started

Do these in order. Steps 1–4 stand alone — you can stop after 4 with a working
read-only UI and decide about the deploy path later.

### 1. Put the secrets in Infisical

Create path `/komodo` in the `prod` environment with seven keys. Generate the
three random ones on forge rather than inventing them:

```bash
openssl rand -base64 48   # KOMODO_JWT_SECRET
openssl rand -base64 48   # KOMODO_WEBHOOK_SECRET
openssl rand -hex 24      # KOMODO_DATABASE_PASSWORD  <- hex, not base64
```

**The database password must be URL-safe, and this is not fussiness.** FerretDB
reaches Postgres over a connection *URI*
(`postgres://user:pass@komodo-postgres:5432/postgres`), so a password containing
`/ : @ ? # %` corrupts the string rather than failing to authenticate — you get
a parse error that says nothing about passwords. `openssl rand -base64` emits
`/` and `+` routinely. Use `-hex`, which cannot.

The other two never enter a URI, so base64 is fine for them.

| Key | Value |
|---|---|
| `KOMODO_DATABASE_USERNAME` | `admin` is fine — it never leaves the private network |
| `KOMODO_DATABASE_PASSWORD` | generated above |
| `KOMODO_JWT_SECRET` | generated above |
| `KOMODO_WEBHOOK_SECRET` | generated above |
| `KOMODO_INIT_ADMIN_USERNAME` | your login |
| `KOMODO_INIT_ADMIN_PASSWORD` | your login password |
| `DOMAIN` | `brent-miles.com`, duplicated from `/caddy` as usual |

`KOMODO_INIT_ADMIN_*` are read only on the first launch against an empty
database. They live in Infisical anyway because the day they matter again is
the day the database is gone and you are rebuilding.

### 2. Make the host directories

```bash
sudo mkdir -p /srv/komodo/{keys,backups}
```

Only two. The database itself lives in named volumes (`pgdata`,
`ferretdb-state`) for the same reason `immich_postgres` does — correct
ownership on ext4, and recovery via a dump rather than by copying the
directory. Core writes those dumps into `/srv/komodo/backups`.

These belong in `bootstrap.sh` alongside the other `/srv` paths. Adding them
there is the difference between a rebuild that works and a rebuild that stops
here.

> **If you already tried this with MongoDB**, clear the failed attempt first —
> `docker compose -p komodo down -v` and `sudo rm -rf /srv/komodo/db`. Mongo
> never reached the point of writing anything, so nothing is lost. See the
> header of `stacks/komodo/compose.yml` for why it cannot run on this kernel.

### 3. Deploy Core

On your PC: commit and push. On forge:

```bash
cd ~/home-containers && git pull --ff-only
./scripts/deploy.sh komodo
./scripts/deploy.sh caddy -- --force-recreate
```

**The `--force-recreate` on Caddy is not optional after a pull.** The Caddyfile
is a single-file bind mount and Docker binds it by inode; `git pull` replaces
files by rename, so a plain reload silently re-reads the old routing table and
reports success. The Caddyfile header covers this at length.

Order does not matter — Caddy re-resolves upstream names at dial time, so a
route pointing at a container that does not exist yet is a 502, not a failure
to start.

Check:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
docker exec caddy grep -c deploy /etc/caddy/Caddyfile   # 0 means the reload lied
curl -sI http://127.0.0.1:9120 | head -1                # Core, on loopback
docker compose -p komodo ps
```

### 4. Log in

`https://deploy.brent-miles.com`, with `KOMODO_INIT_ADMIN_*`. You should see a
Server named `forge` with no agent attached — that is step 5.

Stopping here is a legitimate resting point: you have the UI, and every stack
still deploys through `scripts/deploy.sh`.

### 5. Install Periphery on the host

Not a container. See [Periphery](#periphery) above for why, and set up
`/etc/komodo/infisical-identity` from that section first.

```bash
sudo python3 <(curl -sfL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py) \
  --core-address ws://127.0.0.1:9120 \
  --connect-as forge
```

`--connect-as` must match `KOMODO_FIRST_SERVER_NAME` in `compose.yml` exactly.
Outbound mode is used deliberately: the agent dials Core over the loopback
publish, so nothing on this box listens for it and there is no firewall rule to
maintain.

Then give the agent Core's public key, so it will accept the connection:

```bash
sudo cp /srv/komodo/keys/core.pub /etc/komodo/keys/core.pub
sudo tee -a /etc/komodo/periphery.config.toml >/dev/null <<'EOF'
core_public_keys = "file:/etc/komodo/keys/core.pub"
EOF
sudo systemctl restart periphery
sudo systemctl status periphery --no-pager
```

`/etc/komodo/periphery.config.toml` is **host state and is not in this repo**,
exactly like `/etc/cockpit/cockpit.conf`. If forge is rebuilt, this and the
identity file are what has to be reapplied by hand.

The Server in the UI should go green within a few seconds.

### 6. Add the first stack, by hand, and export it

`decisions.md` says the first Komodo stack should be one that already works, so
that a failure has exactly one possible cause. That is beszel.

Build it in the UI using `komodo/beszel.toml` as the reference for every field,
**then export it to TOML and reconcile the two.** The pre_deploy / post_deploy
spelling in that file is inferred from upstream's docs for Repos, not confirmed
for Stacks — this is the step that confirms it.

Smoke test, in this order:

```bash
# Deploy from the Komodo UI, then immediately:
docker exec beszel-agent sh -c '[ -n "$TOKEN" ] && echo "secret arrived"'
ls -l ~/home-containers/stacks/beszel/.env    # a symlink into /dev/shm
readlink -f ~/home-containers/stacks/beszel/.env | xargs ls -l
```

The last command should fail with "No such file" — the target is gone because
post_deploy removed it, and the dangling symlink is the expected resting state.
If the target still exists, the deploy failed and post_deploy was skipped; that
is the case `deploy.sh`'s guard is there to catch.

Then confirm the manual path still works:

```bash
./scripts/deploy.sh beszel
```

It should deploy normally. If it refuses with "`.env` exists", a Komodo deploy
failed and left a live file behind — that is the guard doing its job, not a
bug.

### 7. Turn on the Resource Sync, last

Only once a stack has deployed both ways. Create a Resource Sync in "files on
host" mode pointed at `/syncs` (the read-only mount of `komodo/` in this repo),
run it unmanaged first to read the diff, and only then set it managed.

Managed mode deletes resources that exist in the database but not in the files.
Running it managed before the files are known-correct is how you delete the
stack you just built.

---

## Still open

- **`/srv/komodo/*` and the `komodo` case are not in `bootstrap.sh` yet.** The
  directories in step 2 and a check-6c entry both belong there; without them a
  rebuild stops at step 2 and check 6c will fail on a stack it does not know.
- **Periphery's `root_directory`** defaults to `/etc/komodo`, and upstream says
  compose files and repos "need to be inside this directory". Stacks here are
  `files_on_host` at absolute paths outside it. If the agent refuses those
  paths, the fix is `repo_dir` / `stack_dir` overrides in
  `periphery.config.toml`, not moving the repo.
- **The `DeployStack` execution spelling** in `komodo/home-containers.toml` is a
  guess; upstream's sync docs only show `Deploy` for Deployments. Build the
  Procedure in the UI once and export it.
- **Cloudflare Tunnel for the webhook path**, if on-demand pulls start to chafe.
  The Tunnel rejection in `decisions.md` was about the 100 MB body limit and
  does not apply to a webhook; the exposure question is a separate decision.
- **`poll_for_updates` against pinned tags** reports movement on the exact tag,
  not the existence of a newer minor. Something like Diun would be needed for
  "0.19 is out", and it needs no secrets.
- **A git provider token**, only if the Repo resource in
  `komodo/home-containers.toml` turns out to need one — see
  [Komodo stores no credentials](#komodo-stores-no-credentials) for why it
  probably does not, and where it would go if it does.
- **The UI's Deploy button on an unmanaged stack** would start containers with
  blank values. Every stack Komodo can see should have the `pre_deploy` hook, or
  none of it.
