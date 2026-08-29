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

| Piece | Where | Job |
|---|---|---|
| `satisfactory-latest-save.{sh,service,timer}` | host systemd | point `latest/latest.sav` at the newest `.sav` |
| `saves` service | `stacks/satisfactory/compose.yml` | serve that one directory over HTTP on `proxy` |
| `spaghetti.<domain>` block | `stacks/caddy/Caddyfile` | TLS, the LAN guard, and the CORS headers |

**Nothing writes into `SaveGames/`.** The updater creates one relative symlink
in `/srv/satisfactory/latest/`, a directory of its own, and both container
mounts are read-only.

#### Why a timer and not a `.path` unit

A systemd `.path` unit on `PathChanged` fires on close-after-write and would be
instant, which is strictly nicer — except that a `.path` unit watches exactly one
directory and does not recurse. It would have to name the session directory the
server happens to have created, and it would silently stop the day a new one
appears. A 60-second timer against a server that autosaves every five minutes
costs nothing and cannot rot that way.

#### Why the newest save is safe to serve mid-write

Autosaves rotate across three slots, so the newest file is the one that will
*not* be rewritten for another two intervals — about fifteen minutes at the
default. The script also skips any save less than 15 seconds old, which covers
the write itself. Between the two there is no realistic window in which the map
can download a truncated file.

### Install

```bash
# 1. The directory the symlink lives in. bootstrap.sh creates it; by hand:
sudo mkdir -p /srv/satisfactory/latest
sudo chown "$(id -u):$(id -g)" /srv/satisfactory/latest

# 2. The updater.
sudo install -m 755 scripts/satisfactory-latest-save.sh /usr/local/bin/
sudo install -m 644 scripts/satisfactory-latest-save.service /etc/systemd/system/
sudo install -m 644 scripts/satisfactory-latest-save.timer   /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now satisfactory-latest-save.timer

# Prove it before moving on.
sudo systemctl start satisfactory-latest-save.service
journalctl -u satisfactory-latest-save -n 20 --no-pager
ls -l /srv/satisfactory/latest/          # latest.sav -> ../saved/SaveGames/...

# 3. The sidecar. Brings up satisfactory-saves alongside the game container;
#    the game container is not recreated by this.
./scripts/deploy.sh satisfactory

# 4. Caddy. RECREATE, not reload - the Caddyfile is a single-file bind mount
#    and a git pull leaves the container on the old inode. See
#    decisions.md#single-file-bind-mounts-need-a-recreate-not-a-reload.
./scripts/deploy.sh caddy -- --force-recreate
```

### Verify

```bash
# The file is there, and it is the size of a save rather than of an error page.
curl -sI https://spaghetti.brent-miles.com/latest.sav

# The CORS header the map depends on.
curl -sI -H 'Origin: https://satisfactory-calculator.com' \
  https://spaghetti.brent-miles.com/latest.sav | grep -i '^access-control'

# The preflight. Anything other than 204 here means the map will load the save
# once and then never refresh.
curl -s -o /dev/null -w '%{http_code}\n' -X OPTIONS \
  https://spaghetti.brent-miles.com/latest.sav
```

### When it doesn't work

| Symptom | Cause |
|---|---|
| Map errors, browser console says CORS | Caddy was reloaded rather than recreated after a `git pull` |
| Map loads once, never updates | The preflight isn't answering 204, so `If-Modified-Since` never reaches the file server |
| 404 on `latest.sav` | The timer hasn't run, or `SAVE_ROOT` doesn't match where this server actually writes — check `journalctl -u satisfactory-latest-save` |
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
