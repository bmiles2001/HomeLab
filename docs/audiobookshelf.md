# Audiobookshelf

Written 2026-08-22. This is the **build**: the stack, the files, and the order
to run them in. The ecosystem question — where books come from, which iPhone
client, whether to add the download automation at all — is
[audiobooks.md](audiobooks.md), and it is worth reading first because it may
talk you out of half of this.

One container, no secrets, no database of its own beyond a SQLite file.
It is the simplest stack in the repo, and the only interesting parts are the
two places it touches things that already exist: Caddy and Komodo.

---

## Do beszel through Komodo first

`docs/komodo.md` step 6 says the first Komodo-managed stack must be one that
**already works**, so that a failure has exactly one possible cause. That is
beszel, and it hasn't been done yet.

Audiobookshelf is a brand new app. If it is also the first stack Komodo ever
deploys, then a red deploy could be the app, the compose file, the periphery
agent, the PKI handshake, the secret render, the procedure, or the sync — six
candidates, and no way to bisect them. Finish beszel through Komodo (steps 6
and 7 of `komodo.md`, the smoke test included), *then* come back here.

That ordering costs an evening and buys you a Komodo path you can trust when
this stack does break. Phases 1–5 below don't depend on Komodo at all — the
manual `deploy.sh` path works today, and Komodo is phase 6.

---

## What the commit contains

| File | Change |
|---|---|
| `stacks/audiobookshelf/compose.yml` | new |
| `komodo/audiobookshelf.toml` | new — Stack + Procedure |
| `scripts/deploy.sh` | new `audiobookshelf)` case in `required_vars()`, empty |
| `stacks/caddy/Caddyfile` | new `@audiobookshelf` block in the **LAN-ONLY** zone |
| `bootstrap.sh` | **not done — see step 1** |
| `docs/decisions.md` | **not done — needed before going public, not before deploying** |

---

## 1. On your PC

Everything above is already written except `bootstrap.sh`. It creates the host
data directories for every other stack and needs four more:

```
/srv/audiobookshelf/config
/srv/audiobookshelf/metadata
/srv/media/audiobooks
/srv/media/podcasts
```

`/srv/media` is a new top-level directory and it is deliberately **not** under
`/srv/audiobookshelf`. The download client will eventually need to hardlink from
its completed folder into the library, and a hardlink cannot cross a
bind-mount boundary — so both have to live under one directory that gets
mounted as one unit later. Putting the library inside the app's data directory
now is the decision that costs a full re-copy of the library in six months.

Also confirm the image tag exists before you push. GitHub tags releases
`v2.35.1`; the container registry does not carry the `v`:

```bash
docker manifest inspect ghcr.io/advplyr/audiobookshelf:2.35.1 >/dev/null && echo ok
```

Then commit and push.

---

## 2. On forge — the manual deploy

```bash
ssh forge
cd ~/home-containers && git pull

sudo mkdir -p /srv/audiobookshelf/{config,metadata} /srv/media/{audiobooks,podcasts}
sudo chown -R root:root /srv/audiobookshelf /srv/media

./scripts/deploy.sh audiobookshelf
```

It should print `deploying 'audiobookshelf' with secrets from
infisical:prod/audiobookshelf` and then nothing about missing variables — the
required list is empty, so `infisical run` wraps a deploy that needs nothing
from it. That is correct, not a misconfiguration.

Reload Caddy for the new hostname. **After a `git pull`, `caddy reload` is not
enough** — the Caddyfile is a single-file bind mount and Docker binds it by
inode, so reload re-reads the old content and reports success:

```bash
docker exec caddy grep -c audiobookshelf /etc/caddy/Caddyfile   # 0 means stale
./scripts/deploy.sh caddy -- --force-recreate
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

Verify:

```bash
docker compose -f stacks/audiobookshelf/compose.yml ps      # healthy, not just up
curl -s -o /dev/null -w '%{http_code}\n' https://books.brent-miles.com   # 200
```

The healthcheck takes up to 60s on first start — `start_period` is generous
because a version bump runs database migrations.

---

## 3. First launch — claim the root account now

`https://books.brent-miles.com` will offer to create a root user. **Do it in
this session, not tomorrow.** Audiobookshelf gives the admin role to the first
account created, exactly like Immich, and the reason to do it while the
hostname is still LAN-only is that there is no `IMMICH_ALLOW_SETUP=false`
equivalent to fall back on.

Then, in order:

1. **Settings → Users → Add User** for your wife. Give her the `user` role, not
   `admin`. Independent playback position is per account, which is the whole
   reason not to share one login.
2. **Libraries → Add Library**, type *Book*, folder `/audiobooks`. Name it
   something plain — it shows up in the phone app.
3. **Settings → Item Metadata Utils → metadata provider: Audible**. It is the
   best matcher for audiobooks by a wide margin; the default is Google Books,
   which is a book database that happens to know some audiobooks exist.
4. Leave **"Store metadata with item"** off for now. On, it writes
   `metadata.json` next to the audio files, which is nice for portability and
   annoying when a scan and a download client are both touching the tree.

---

## 4. Library layout

Audiobookshelf reads structure, not just tags. Match this and series ordering,
author pages and covers all populate themselves:

```
/srv/media/audiobooks/Brandon Sanderson/Mistborn/1 - The Final Empire/book.m4b
/srv/media/audiobooks/T Kingfisher/Nettle & Bone/book.m4b
```

Author folder, optional series folder, one folder per book. Single-file `.m4b`
with embedded chapters is the format to normalise on — a folder of 200 numbered
mp3s works, but chapter navigation is worse and the metadata is usually wrong.

Drop five or ten real books in and hit **Scan**. Sources are in
[audiobooks.md](audiobooks.md#where-the-books-come-from); the zero-effort ones
are Libro.fm purchases and LibriVox.

---

## 5. Her phone — do this before building anything else

**There is no official Audiobookshelf app on the iOS App Store.** It is
TestFlight-only and the beta has repeatedly been full. Use **Plappa** (free,
CarPlay) or **ShelfPlayer** ($5.99 once).

While `books.brent-miles.com` is LAN-only, the app works on home wifi and books
downloaded there play anywhere. That is a real, usable state — and it is worth
living in for a week before deciding whether remote access is worth a second
public hostname.

---

## 6. Add it to Komodo

Only after beszel has deployed both ways.

**a. Create the Infisical path.** One key, and it is not a secret:

```bash
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod \
  --path=/audiobookshelf TZ=America/Chicago
```

Why a path exists at all for a stack with no secrets is the next section.

**b. Build the Stack in the UI** using `komodo/audiobookshelf.toml` as the
field-by-field reference, then **export it to TOML and reconcile the two**.
Same instruction as beszel and for the same reason: the `pre_deploy` /
`post_deploy` spelling in these files is inferred from upstream's Repo docs,
not confirmed for Stacks.

**c. Deploy from the UI, then immediately:**

```bash
ls -l ~/home-containers/stacks/audiobookshelf/.env      # a symlink into /dev/shm
readlink -f ~/home-containers/stacks/audiobookshelf/.env | xargs ls -l
```

The second command should fail with *No such file* — the target is gone because
`post_deploy` removed it, and the dangling symlink is the expected resting
state. If the target still exists, the deploy failed and `post_deploy` was
skipped.

**d. Confirm the manual path still works:**

```bash
./scripts/deploy.sh audiobookshelf
```

If it refuses with `.env exists`, a Komodo deploy failed and left a live file
behind. That is the guard working.

**e. Add the Procedure**, then let the Resource Sync pick both up. Run the sync
unmanaged first and read the diff.

---

## Why a stack with no secrets still gets the hooks

This is the one non-obvious thing in the stack, and it was nearly missed.

Komodo writes its own env file into the run directory at **step 2** of every
deploy, before `pre_deploy` at step 5. With no `pre_deploy`, that empty *real*
file just stays there. `deploy.sh`'s guard is:

```bash
if [[ -f "$STACK_DIR/.env" ]]; then
```

`-f` is true for an empty regular file. So the first Komodo deploy would
permanently break the manual path — refusing to deploy, citing secrets on disk,
over a zero-byte file belonging to a stack that has none. A guard that fires on
a non-problem is worse than no guard, because the next one gets ignored.

Running `render`/`clean` anyway leaves the state that was actually tested: a
**dangling symlink**, which `-f` follows and reads as absent. Both deploy paths
keep working and the guard goes back to meaning what it says.

The cost is the `/audiobookshelf` Infisical path holding `TZ`. `komodo-env.sh
render` calls `infisical export --path=/<stack>` and needs somewhere to export
from.

The shorter alternative — no `pre_deploy`, and a `post_deploy` of
`/usr/bin/rm -f .../.env` — was rejected: `post_deploy` is gated on
`if res.deployed`, so a *failed* deploy leaves the empty file behind and blocks
`deploy.sh` at exactly the moment you want to fall back to it.

---

## 7. Going public — later, and separately

`books.brent-miles.com` is in the LAN-ONLY zone today. Promoting it is its own
commit and its own evening, and it needs, in this order: a `decisions.md` entry,
an exact site block moved to the PUBLIC zone with its own `books-access.log`,
`header_up X-Forwarded-For {remote_host}`, `books` added to the DDNS updater's
record list, the root account already claimed (step 3), and a verification that
the real client IP reaches the app — Audiobookshelf is Node/Express underneath,
the same architecture that made `IMMICH_TRUSTED_PROXIES` necessary, and it does
not inherit Immich's fix.

The full checklist is [audiobooks.md](audiobooks.md#exposure). Do not do it the
same night as the first deploy.

---

## Still open

- **`bootstrap.sh`** does not create the four directories yet. Step 2 does it by
  hand, which means a rebuild from bare metal would miss them.
- **File ownership.** Audiobookshelf does not support PUID/PGID and runs as
  root, so anything it writes into `/srv/media/audiobooks` is root-owned. That
  is fine with one container and becomes a real problem the day qBittorrent
  needs to write into the same tree. The fix is a shared group on the host
  directories with `chmod g+ws`, decided once — not per container, and not by
  chowning after the fact every time.
- **Backups.** `/srv/audiobookshelf/config` is small and holds every playback
  position in the house. `/srv/media/audiobooks` is large and re-acquirable.
  Only the first belongs in the backup set, and it is not in it yet.
- **The automation stack** (gluetun + qbittorrent + prowlarr + shelfarr) is not
  written. It is deliberately a separate stack so the library server and the
  part that churns can be replaced independently.
