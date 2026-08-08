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
- [public-access.md](public-access.md) — the exposure model everything else
  follows, and which this stack deliberately sits outside
- [storage-expansion.md](storage-expansion.md#layout) — what `/srv` is and how
  much of it is left
- upstream's
  [Troubleshooting FAQ](https://github.com/wolveix/satisfactory-server/wiki/Troubleshooting-FAQ)
