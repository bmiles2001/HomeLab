# Shelfarr — the audiobook automation stack

Written 2026-08-22. Six containers: `gluetun`, `qbittorrent`, `prowlarr`,
`sabnzbd`, `shelfarr`, `shelfarr-libation`. Named after the one you actually
look at.

The reasoning lives in the compose file and in
[audiobooks.md](audiobooks.md#the-stack). **This page is the punch list.**

**Do not start this until [audiobookshelf.md](audiobookshelf.md) is done and the
library has been in use for a week.** This stack imports *into* that one; if
the library server isn't proven, an import failure has two possible causes.

---

## 0. Prerequisites

- `stacks/audiobookshelf` deployed and healthy.
- A VPN subscription. You don't have one yet — pick in step 2.
- A Usenet provider **and** a Usenet indexer, if you want the usenet half
  working on day one. Both are paid and separate; ~$50–80/yr all in. The stack
  deploys fine without them and SABnzbd just sits idle.

---

## 1. Verify the image tags — before you commit anything

The six tags in `compose.yml` are best-known values, **not** values confirmed
against the registries. Run this on forge; anything that prints `MISSING` gets
corrected in the same commit.

```bash
for img in \
  qmcgaw/gluetun:v3.41.3 \
  lscr.io/linuxserver/qbittorrent:5.1.2 \
  lscr.io/linuxserver/prowlarr:2.0.5 \
  lscr.io/linuxserver/sabnzbd:4.5.5 \
  ghcr.io/pedro-revez-silva/shelfarr:0.32.3 \
  ghcr.io/pedro-revez-silva/shelfarr-libation:0.32.3
do
  docker manifest inspect "$img" >/dev/null 2>&1 \
    && echo "ok      $img" \
    || echo "MISSING $img"
done
```

Shelfarr's tag is the one most likely to be wrong — its release page and its
repo page disagree about the current version, and the `v` prefix on the git tag
may or may not be carried into the container tag. If it reports MISSING, list
what actually exists:

```bash
curl -s https://api.github.com/repos/Pedro-Revez-Silva/shelfarr/releases/latest \
  | grep '"tag_name"'
```

---

## 2. Pick a VPN provider

You don't have one. Three that gluetun supports well:

| Provider | `VPN_TYPE` | Keys it needs | Port forwarding |
|---|---|---|---|
| **ProtonVPN** | `wireguard` | `WIREGUARD_PRIVATE_KEY` | Yes — gluetun supports it natively |
| **Mullvad** | `wireguard` | `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES` | **No** — removed in 2023 |
| **Private Internet Access** | `openvpn` | `OPENVPN_USER`, `OPENVPN_PASSWORD` | Yes |

**ProtonVPN if you're seeding, Mullvad if you're not.** Port forwarding is the
only real differentiator here and it only matters for torrents — with SABnzbd
carrying the primary load, "not seeding well" is a smaller problem than it
looks. Mullvad is the simplest thing that works: one config page, no account
tied to your identity, flat €5/mo.

Generate the WireGuard config in the provider's portal and keep the **private
key** and the **address** it hands you. Do not download their `.conf` file and
try to point gluetun at it — gluetun wants the values, not the file.

---

## 3. Put the secrets in Infisical

Path `/shelfarr`, `prod` environment. Adjust to whichever provider you picked:

```bash
# WireGuard (ProtonVPN / Mullvad)
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/shelfarr \
  VPN_SERVICE_PROVIDER='mullvad' \
  VPN_TYPE='wireguard' \
  WIREGUARD_PRIVATE_KEY='<from the provider portal>' \
  WIREGUARD_ADDRESSES='10.64.0.2/32' \
  SERVER_COUNTRIES='USA' \
  TZ='America/Chicago'
```

```bash
# OpenVPN (PIA) - instead of the two WIREGUARD_ lines above
  OPENVPN_USER='<username>' \
  OPENVPN_PASSWORD='<password>' \
  VPN_PORT_FORWARDING='on'
```

**Quote every value in single quotes.** WireGuard keys are base64 and routinely
contain `/` and `+`; provider passwords contain whatever their generator felt
like. Unquoted, your shell will eat some of it and gluetun will report an
authentication failure that reads like a wrong password rather than a truncated
one.

Confirm what landed, without printing the values:

```bash
infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/shelfarr \
  | awk '{print $1}'
```

---

## 4. The `media` user, and the directories

This is the step that prevents the permissions mess later. Audiobookshelf runs
as root and cannot be told otherwise; every container in *this* stack runs as
uid/gid 3000 with `umask 002`. A setgid directory tree is what makes those two
facts coexist.

```bash
sudo groupadd -g 3000 media
sudo useradd -u 3000 -g 3000 -M -s /usr/sbin/nologin media

sudo mkdir -p /srv/media/{audiobooks,podcasts,downloads/{incomplete,complete}}
sudo mkdir -p /srv/shelfarr/{gluetun,qbittorrent,prowlarr,sabnzbd,shelfarr}

sudo chown -R media:media /srv/media /srv/shelfarr

# 2775: setgid, so anything created below inherits group `media` regardless of
# which container created it. This is the line doing the work.
sudo chmod -R 2775 /srv/media
sudo chmod -R 0755 /srv/shelfarr
```

Verify the setgid bit actually took — it is silently dropped by some `chmod`
invocations:

```bash
stat -c '%A %U:%G %n' /srv/media /srv/media/audiobooks /srv/media/downloads
# expect drwxrwsr-x media:media  - note the `s`, not an `x`, in the group triad
```

If Audiobookshelf has already been running, it created files in
`/srv/media/audiobooks` as root. The `chown -R` above fixes what exists; new
files it writes will be `root:media` mode 644, readable but not group-writable.
That is fine for a library ABS mostly reads. It is listed under **Still open**
because it is the loose end that will eventually need a `umask` on the ABS
container or a periodic fixup.

---

## 5. Deploy

```bash
ssh forge
cd ~/home-containers && git pull

./scripts/deploy.sh shelfarr
```

Watch gluetun come up before anything else — the other two tunnel containers
are gated on its healthcheck and will sit in `Created` until it passes:

```bash
docker logs -f gluetun
# looking for: "You are running the latest release"
#              "healthy!"
# Ctrl-C once it says healthy.

docker compose -f stacks/shelfarr/compose.yml ps
# all six: Up (healthy). gluetun first, the rest within ~90s.
```

Reload Caddy for the four new hostnames. **After a `git pull`, `caddy reload`
is not enough** — single-file bind mount, bound by inode:

```bash
docker exec caddy grep -c 'torrents' /etc/caddy/Caddyfile   # 0 means stale
./scripts/deploy.sh caddy -- --force-recreate
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

---

## 6. Verify the tunnel — do this before configuring anything

Two tests. Neither is optional and the second is the one people skip.

**a. Traffic actually leaves through the VPN:**

```bash
curl -s https://api.ipify.org; echo                          # forge's real WAN address
docker exec qbittorrent curl -s https://api.ipify.org; echo  # must be DIFFERENT
docker exec sabnzbd     curl -s https://api.ipify.org; echo  # must be the SAME (by design)
```

If the qbittorrent line matches your WAN address, stop. Nothing else in this
document matters until it doesn't.

**b. The kill switch actually kills:**

```bash
docker exec gluetun ip link            # find the tunnel interface, usually tun0
docker exec gluetun ip link set tun0 down

docker exec qbittorrent curl -s -m 5 https://api.ipify.org \
  && echo "LEAKING - stop and fix" \
  || echo "no route - kill switch holding"

docker restart gluetun
```

The failure you want is a timeout, not an address.

---

## 7. qBittorrent first run

The linuxserver image generates a temporary password on first start and prints
it exactly once:

```bash
docker logs qbittorrent 2>&1 | grep -i 'temporary password'
```

Now the Host header problem. `https://torrents.brent-miles.com` will return a
bare **Unauthorized** rather than a login page, and nothing in the UI explains
why. There is no environment variable for it — the setting is in the config
file the container just wrote:

```bash
docker stop qbittorrent

sudo tee -a /srv/shelfarr/qbittorrent/qBittorrent/qBittorrent.conf >/dev/null <<'EOF'
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
EOF

docker start qbittorrent
```

Both are safe here and would not be if this were public: the only thing that
can reach port 8080 is Caddy, and the only thing that can reach Caddy on this
hostname is the LAN.

Then in the UI at `https://torrents.brent-miles.com`:

1. **Tools → Options → Web UI** — change the password off the temporary one.
2. **Downloads → Save files to** `/srv/media/downloads/complete`
3. **Downloads → Keep incomplete torrents in** `/srv/media/downloads/incomplete`

Those two paths are the same strings inside and outside the container. Do not
type `/downloads`.

---

## 8. SABnzbd first run

`https://usenet.brent-miles.com` opens a setup wizard.

1. Enter your Usenet provider's host, port 563, SSL on, username, password.
   Connections: start at 20.
2. **Config → Folders → Temporary Download Folder** `/srv/media/downloads/incomplete`
3. **Config → Folders → Completed Download Folder** `/srv/media/downloads/complete`
4. **Config → General → API Key** — copy it, you need it in step 10.

SABnzbd also has a hostname check that rejects proxied requests:

```bash
docker exec sabnzbd grep -n '^host_whitelist' /config/sabnzbd.ini
```

If `usenet.brent-miles.com` is not in that list, add it under
**Config → General → Host whitelist** rather than editing the file — SAB
rewrites its ini on shutdown and will discard a hand edit made while running.

---

## 9. Prowlarr first run

`https://indexers.brent-miles.com`.

1. Set authentication (Forms, and a real password) when prompted — it will
   demand this before letting you in.
2. **Settings → General → API Key** — copy it, you need it in step 10.
3. **Indexers → Add Indexer** — this is where the source question from
   `audiobooks.md` gets answered, and it's yours to answer. LibriVox is
   available here and costs nothing. If you bought a Usenet indexer, add it
   here as well, not in SABnzbd.

Confirm searches leave through the tunnel:

```bash
docker exec prowlarr curl -s https://api.ipify.org; echo   # the VPN address again
```

---

## 10. Shelfarr — wire the four services together

`https://request.brent-miles.com`. Create the admin account immediately, same
reasoning as Audiobookshelf.

Then **Settings**, in this order:

| Setting | Value |
|---|---|
| Prowlarr URL | `http://gluetun:9696` |
| Prowlarr API key | from step 9 |
| qBittorrent URL | `http://gluetun:8080` |
| SABnzbd URL | `http://sabnzbd:8080` |
| SABnzbd API key | from step 8 |
| Audiobookshelf URL | `http://audiobookshelf:80` |
| Audiobookshelf API key | ABS → Settings → Users → your account → API token |
| Audiobook library path | `/srv/media/audiobooks` |
| Download path | `/srv/media/downloads/complete` |

**`gluetun`, not `qbittorrent` or `prowlarr`.** Those two containers have no
name on any network — their ports belong to gluetun. This is the same thing the
Caddyfile does and it catches everyone once.

---

## 11. Verify hardlinking — the silent failure

If this is wrong, everything still works and every import quietly doubles your
disk usage. Test it from inside the container that does the linking:

```bash
docker exec shelfarr sh -c '
  touch /srv/media/downloads/complete/.hltest &&
  ln /srv/media/downloads/complete/.hltest /srv/media/audiobooks/.hltest &&
  echo "hardlinks OK" ||
  echo "EXDEV - separate mounts, imports will copy";
  rm -f /srv/media/downloads/complete/.hltest /srv/media/audiobooks/.hltest'
```

Repeat for `qbittorrent`. If either says EXDEV, the mount in `compose.yml` has
been split into per-directory binds — put it back to the single
`/srv/media:/srv/media`.

---

## 12. Libation — link the Audible account

The sidecar has no hostname and is not reachable from a browser. It is driven
entirely through Shelfarr's UI: **Settings → Libation → Link account**, which
runs the device-registration flow against Audible.

```bash
docker logs -f shelfarr-libation    # watch the registration land
```

Converted files stage in the `libation_books` volume and are imported into the
library by Shelfarr, not by appearing in the library folder. That is deliberate
— everything that reaches `/srv/media/audiobooks` should get there through an
import that names and organises it.

---

## 13. Add it to Komodo

Third stack on the Komodo path, after beszel and audiobookshelf. Same routine
as `audiobookshelf.md` step 6: build the Stack in the UI using
`komodo/shelfarr.toml` as the reference, export to TOML, reconcile, deploy from
the UI, then:

```bash
readlink -f ~/home-containers/stacks/shelfarr/.env | xargs ls -l
# should fail with "No such file" - post_deploy cleaned the tmpfs target

./scripts/deploy.sh shelfarr    # the manual path must still work
```

---

## Still open

- **`bootstrap.sh`** creates none of the directories in step 4, and does not
  create the `media` user. A rebuild from bare metal misses all of it.
- **`docs/decisions.md`** has no entry for this stack. Two decisions in it are
  worth writing down properly: SABnzbd outside the tunnel while Prowlarr is
  inside it, and the single `/srv/media` mount over upstream's three.
- **Audiobookshelf still runs as root** and writes `root:media` 644 into a tree
  the rest of the stack wants group-write on. Not biting yet. The fix is a
  `umask` on that container or a periodic fixup, and it should be decided
  rather than discovered.
- **Backups.** `/srv/shelfarr/shelfarr` holds the request history and every API
  key typed into the UI, and is small. The other five directories are
  regenerable config. None of it is in the backup set.
- **The library ownership assumption.** Everything above depends on uid/gid
  3000 not colliding with anything else on forge. `id media` before you trust
  it.
