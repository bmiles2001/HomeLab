# Satisfactory

A dedicated Satisfactory server on `forge`, reachable from the internet so
friends can join.

Image: [wolveix/satisfactory-server](https://github.com/wolveix/satisfactory-server).
Stack: `stacks/satisfactory/compose.yml`.

This is the only stack other than Caddy that publishes host ports, and the only
one whose exposed surface is a game binary rather than something with a login
page. Why that was accepted, and what bounds it, is in
[decisions.md](decisions.md#satisfactory-publishes-ports-and-caddy-cannot-help).
This file is the mechanism and the runbook.

---

## The five things that catch people out

Read these before deploying. Four of the five are in upstream's FAQ because
everybody hits them.

1. **You join through the in-game Server Manager, not the Join Game menu.**
   Joining by IP from the server browser produces `Encryption Token Missing`.
   That is the game's design, not a misconfiguration.
2. **A brand-new server looks hung.** It sits there waiting to be *claimed*
   through the Server Manager. Nothing is wrong.
3. **First start downloads ~20GB** via SteamCMD before the game ever runs.
   Expect fifteen minutes or more on the first `up`.
4. **All three ports must be open**, in both UFW and the router: `7777/udp`,
   `7777/tcp`, `8888/tcp`. Forwarding two of the three is the single most
   common failure report upstream.
5. **From inside the house, connect to `10.0.0.4`, not the public address.**
   Most consumer routers don't hairpin, so the WAN address fails from the LAN
   while working perfectly for everyone outside it.

---

## Deploy

```bash
# 0. Directory. bootstrap.sh creates /srv/satisfactory owned by your user;
#    re-run it, or do it by hand:
sudo mkdir -p /srv/satisfactory && sudo chown "$(id -u):$(id -g)" /srv/satisfactory

#    The compose file sets PUID/PGID 1000. If `id -u` is not 1000, set
#    SATISFACTORY_* to match or chown to 1000:1000 - a mismatch here is the
#    cause of every "permission denied" in upstream's tracker.

# 1. Check there's room. gamefiles alone is ~20GB and saves grow.
df -h /srv

# 2. Deploy. No secrets, but go through the script anyway so the stack is
#    deployed the same way as everything else.
./scripts/deploy.sh satisfactory

# 3. Watch it fetch the game. This is the slow part.
cd stacks/satisfactory && docker compose logs -f
```

Then, **in the game on your PC**: Server Manager → Add Server → `10.0.0.4:7777`
→ accept the self-signed certificate → set an admin password → name the server →
create or upload a save.

### Immediately after claiming: turn on Auto Pause

Server Manager → the server → Settings → **Auto Pause: on**.

This is the most valuable setting on the box and it is not available as an
environment variable, so it cannot live in the compose file. Without it an empty
server keeps simulating the entire factory forever, holding a core busy for
nobody, 24/7, on a machine that is also running an NVR.

Worth setting at the same time: **Auto Save Interval** (default 5 minutes) and
**Auto Save on Disconnect**.

---

## Exposure

### UFW

`ufw-docker` is what makes UFW rules actually apply to published container ports
— Docker writes its iptables rules ahead of UFW's, so without it a published
port is reachable no matter what `ufw status` says. `bootstrap.sh` check 5
verifies it's installed. Confirm that first, then:

```bash
sudo ufw-docker allow satisfactory 7777/udp
sudo ufw-docker allow satisfactory 7777/tcp
sudo ufw-docker allow satisfactory 8888/tcp
sudo ufw status numbered
```

### Router

Forward all three to `10.0.0.4`, same port in and out:

| WAN | → LAN | Protocol |
|---|---|---|
| 7777 | 10.0.0.4:7777 | UDP |
| 7777 | 10.0.0.4:7777 | TCP |
| 8888 | 10.0.0.4:8888 | TCP |

Do **not** remap the external port unless you also set `SERVERGAMEPORT` /
`SERVERMESSAGINGPORT` in the compose file. The server advertises the port it
believes it is on; a host-side remap alone produces a server that listens on one
port and tells clients about another.

### Giving friends an address

Options, in increasing order of effort:

- **The raw WAN IP.** Works today, breaks whenever the ISP changes it.
- **A DNS record.** `satisfactory.brent-miles.com` as an **A record pointing at
  the WAN IP**, Cloudflare **grey-cloud** (DNS only). Orange-cloud proxying
  would break it outright — Cloudflare's proxy carries HTTP, not game UDP.

  Note this is a deliberate exception to the rule in
  [public-access.md](public-access.md): *"the wildcard A record must not move"*
  — it stays at `10.0.0.4`, and this is a separate, more specific record that
  does not disturb it. A more specific record wins over the wildcard, the same
  way `photos.` does.
- **Dynamic DNS**, if the WAN address moves often. The DDNS stack was removed
  from this repo and is recoverable with
  `git checkout <commit> -- stacks/ddns`.

### What is and isn't protected

The game ports have no auth in front of them; the session handshake is the only
gate. The API on 8888 is guarded by the admin password you set at claim time,
over a self-signed certificate — which is why clients get a certificate prompt.

**Use a real password there.** It is the one credential on this stack, it is
internet-facing, and it grants full server administration. It belongs in your
password manager, not in Infisical — the game stores it in its own config under
`/srv/satisfactory/saved`, and nothing in this repo reads or injects it.

The container is not on the `proxy` network and holds no docker socket, so a
compromise reaches one container, one bind mount, and outbound internet.

---

## Saves

Everything irreplaceable is in `/srv/satisfactory/saved`. `gamefiles` is a
redownload, `logs` is disposable, `backups` is a copy.

```bash
# List saves
ls -lh /srv/satisfactory/saved/SaveGames/

# Copy one off the box before doing something risky
scp forge:/srv/satisfactory/saved/SaveGames/*.sav .
```

Uploading a save from your PC is easiest through the Server Manager's own upload
button rather than by dropping files into that directory — the server indexes
what it knows about, and a file appearing underneath it mid-session is not
something it watches for.

### Backups

The container copies `saved/` into `/srv/satisfactory/backups` when it first
starts. That covers a save the game corrupts. It does **not** cover losing the
disk: both directories are on the same NVMe, along with everything else on this
box.

Making that off-box is the obvious follow-up and is not done. The pattern is
already here — `scripts/immich-onedrive-sync.{sh,service,timer}` is a systemd
timer running `rclone` at `/srv/immich/data`, and saves are a few hundred MB
rather than a photo library, so it is a small job. Logged in
[decisions.md](decisions.md#still-open).

---

## Viewing the save on the Interactive Map

`https://satisfactory-calculator.com/en/interactive-map?url=https://spaghetti.brent-miles.com/latest.sav`

Bookmark that. It opens the Satisfactory-Calculator Interactive Map on whatever
the server saved most recently, and it keeps working forever because the
filename never changes — a symlink moves underneath it instead.

### Why this needs no public exposure

The map takes `?url=` and **fetches the save in your browser**, not on their
servers. The tell is that the only thing upstream asks of the far end is a CORS
header; CORS exists solely to police fetches a browser makes on a page's behalf.
satisfactory-calculator.com never connects to forge.

So the whole thing sits inside the LAN-only wildcard block with Frigate and
Komodo:

- no DNS record — `*.brent-miles.com` already resolves to `10.0.0.4`
- no port forward, and nothing added to the router or `ufw-docker`
- no certificate work — the DNS-01 wildcard already covers the name, which is
  what satisfies upstream's "valid SSL certificate" requirement
- nothing new reachable from the internet, so this is not a second exception to
  [public-access.md](public-access.md)

The cost is that it only works from inside the house. Sharing the factory with
the friends who play on the server would mean a second public hostname, and that
is logged in [decisions.md](decisions.md#still-open) rather than done.

Note that the map itself is not self-hosted and cannot be: upstream's licence
restricts the code to their own domain. This feeds their hosted page a file.

### The three pieces

All three are in git and all three deploy the same way as everything else in
the house. Nothing is installed on forge by hand.

| Piece | Where | Job |
|---|---|---|
| `saves-updater` service | `stacks/satisfactory/compose.yml` + `updater/` | point `latest/latest.sav` at the newest `.sav`, once a minute |
| `saves` service | `stacks/satisfactory/compose.yml` | serve that one directory over HTTP on `proxy` |
| `spaghetti.<domain>` block | `stacks/caddy/Caddyfile` | TLS, the LAN guard, and the CORS headers |

**Nothing writes into the save directory.** `saved/` is mounted read-only into
both containers. The only thing the updater creates is one relative symlink in
`/srv/satisfactory/latest/`, a directory that contains nothing else, and it
does that as `1000:1000` with no network and a read-only root filesystem.

The updater searches recursively from `/srv/satisfactory/saved` and does not
care which layout this server uses — upstream's docs, this image and this
repo's own runbook have each named a different one, and the server adds a
directory per session underneath. Rooting the search at `saved/` is the fix for
the first version of this, which named `saved/SaveGames` and was skipped by its
own systemd condition on a box where that directory does not exist.

#### Why the symlink is relative

`latest.sav -> ../saved/server/<file>.sav` is valid in two namespaces at once.
`latest/` and `saved/` are siblings under `/srv/satisfactory` on the host and
siblings under `/saves` in both containers, so the same relative path resolves
in all three. An absolute `/srv/...` target would be correct on the host and
dangle inside the containers.

#### Why a loop and not inotify

A watcher would fire on close-after-write and be instant, which is strictly
nicer. It is not used because it has to be told which directory to watch —
`inotify` does not recurse — and the directory the server writes to is
precisely the thing that has already been wrong once here. A 60-second loop
against a server that autosaves every five minutes costs nothing and cannot rot
that way.

#### Why the newest save is safe to serve mid-write

Autosaves rotate across `AUTOSAVENUM` slots — five by default — so the newest
file is the one that will *not* be rewritten for another four intervals, about
twenty-five minutes at the default. The script also skips any save less than 15
seconds old, which covers the write itself. Between the two there is no
realistic window in which the map can download a truncated file.

The updater ignores `ServerSettings.<port>.sav`, which lives among the saves,
is a `.sav`, and is not a save. It is rewritten whenever a server setting
changes, so without the exclusion it would periodically become the newest file
in the directory and hand the map something it cannot parse.

### Install

```bash
# 1. The directory the symlink lives in. bootstrap.sh creates it; by hand:
sudo mkdir -p /srv/satisfactory/latest
sudo chown "$(id -u):$(id -g)" /srv/satisfactory/latest

# 2. Both containers. The game container is not recreated by this.
./scripts/deploy.sh satisfactory

# 3. Caddy. RECREATE, not reload - the Caddyfile is a single-file bind mount
#    and a git pull leaves the container on the old inode. See
#    decisions.md#single-file-bind-mounts-need-a-recreate-not-a-reload.
./scripts/deploy.sh caddy -- --force-recreate
```

That is the whole install, and it is also the whole update path: `git pull`
then `./scripts/deploy.sh satisfactory`. Editing the updater script needs no
`sudo` and nothing reloaded — `updater/` is mounted as a directory, so a pull
replaces the file the container is reading.

#### If you deployed the systemd version first

It existed for about an hour on 2026-08-29. Remove it, or it keeps running
alongside the container and the two fight over the same symlink:

```bash
sudo systemctl disable --now satisfactory-latest-save.timer
sudo rm -f /etc/systemd/system/satisfactory-latest-save.{service,timer}
sudo rm -f /usr/local/bin/satisfactory-latest-save.sh
sudo systemctl daemon-reload

# The symlink it left behind is root-owned. Harmless - the container can
# replace it, because the directory is 1000:1000 - but tidy it anyway.
sudo rm -f /srv/satisfactory/latest/latest.sav
```

### Verify

```bash
# The file is there, and it is the size of a save rather than of an error page.
curl -sI https://spaghetti.brent-miles.com/latest.sav

# The CORS header on the response itself.
curl -sI -H 'Origin: https://satisfactory-calculator.com' \
  https://spaghetti.brent-miles.com/latest.sav | grep -i '^access-control'

# THE PREFLIGHT, sent exactly as the browser sends it. A 204 on its own is not
# enough - read Access-Control-Allow-Headers and confirm it contains
# access-control-allow-origin. That is the entry the map needs, it is the one
# that has already been wrong once, and a plain `curl -X OPTIONS` will not
# catch it because curl sends no Access-Control-Request-Headers of its own.
curl -s -D - -o /dev/null -X OPTIONS \
  -H 'Origin: https://satisfactory-calculator.com' \
  -H 'Access-Control-Request-Method: GET' \
  -H 'Access-Control-Request-Headers: access-control-allow-origin,if-modified-since' \
  https://spaghetti.brent-miles.com/latest.sav | grep -iE '^HTTP|^access-control'

# The auto-refresh path: 304 while the symlink has not moved, 200 once it has.
LM=$(curl -sI https://spaghetti.brent-miles.com/latest.sav \
     | grep -i '^last-modified' | cut -d' ' -f2- | tr -d '\r')
curl -s -o /dev/null -w '%{http_code}\n' -H "If-Modified-Since: $LM" \
  https://spaghetti.brent-miles.com/latest.sav
```

### When it doesn't work

| Symptom | Cause |
|---|---|
| Map errors, console says `Request header field access-control-allow-origin is not allowed` | That entry is missing from `Access-Control-Allow-Headers`. The map's XHR really does send a request header by that name — see the comment on the `spaghetti` block in the Caddyfile |
| Map errors, console says CORS for some other reason | Caddy was reloaded rather than recreated after a `git pull` |
| Map errors, console mentions "local network" or `ERR_BLOCKED_BY_PRIVATE_NETWORK_ACCESS_CHECKS` | Not CORS. Chrome 142+ blocks a public-origin page from reaching RFC1918 addresses, and the old server-side opt-in was removed in favour of a permission prompt only the site can trigger — this whole design would then need public exposure. Not what happened on 2026-08-29, but it is the one thing that could kill it |
| Map loads once, never updates | The preflight isn't answering 204, so `If-Modified-Since` never reaches the file server |
| 404 on `latest.sav` | `docker logs satisfactory-saves-updater`. "no .sav files under /saves/saved yet" means the server hasn't autosaved; anything else names itself. Cross-check with `find /srv/satisfactory/saved -name '*.sav'` |
| `satisfactory-saves-updater` is unhealthy | The loop has stalled or died — the heartbeat is older than three intervals. The logs are the next stop; the map is serving a stale save until it comes back |
| The map updates, then stops, and the logs look fine | Check nothing reinstalled the old systemd timer. Two things writing the same symlink is the one way these can disagree |
| `satisfactory-saves` is unhealthy | Expected until the first autosave exists. After that, the symlink is dangling — the mounts are siblings under `/saves` and the link must stay relative |
| Nothing resolves, from a phone on cellular | Working as designed |

Two smaller things worth knowing. A late-game save is several hundred megabytes
and the map re-downloads it on every refresh, so this is a LAN activity in more
than one sense. And with **Auto Pause** on, an empty server stops writing
autosaves — the map stops updating because the factory has stopped, which is
correct but looks like a bug the first time.

---

## Updating

Two different things update on two different schedules, and conflating them
causes confusion:

**The game** updates itself on every container start, because `SKIPUPDATE` is
`false`. So `docker compose restart` after a Coffee Stain patch is all that's
needed. The catch: a server that has updated ahead of the group's clients locks
everyone out until Steam pushes the client update, which it usually already has.

**The container image** is pinned via `SATISFACTORY_VERSION` (default `latest`).
Bump it deliberately:

```bash
cd stacks/satisfactory
docker compose pull
cd ../.. && ./scripts/deploy.sh satisfactory
```

Read upstream's release notes first — the 1.0 and 1.1 upgrades both needed
manual steps, and upstream keeps a wiki page per major version.

---

## When 16G is not enough

Symptom: the container disappears mid-session and `docker inspect satisfactory`
shows exit code **137**. That is the OOM killer, not a crash.

Before raising the limit, look at what else is resident — Beszel charts this,
which is what it's for. forge has 32GB total and Immich's ML container, Frigate,
Home Assistant and Beszel all live on it. Raising the cap past ~20G starts
competing with the cameras, and losing recordings to a factory is the wrong
trade.

The cheaper fixes first:

- **Auto Pause on** (above). An idle paused server uses a fraction of a running
  one.
- **Fewer players** via `SATISFACTORY_MAXPLAYERS`.
- **`SERVERSTREAMING=true`**, which is the default — don't turn it off.

---

## Related

- [decisions.md](decisions.md#satisfactory-publishes-ports-and-caddy-cannot-help)
  — why this stack is allowed to publish ports
- [decisions.md](decisions.md#the-save-viewer-is-lan-only-because-the-map-fetches-in-the-browser)
  — why the map needs no public exposure at all
- [public-access.md](public-access.md) — the exposure model everything else
  follows, and which this stack deliberately sits outside
- [storage-expansion.md](storage-expansion.md#layout) — what `/srv` is and how
  much of it is left
- upstream's
  [Troubleshooting FAQ](https://github.com/wolveix/satisfactory-server/wiki/Troubleshooting-FAQ)
