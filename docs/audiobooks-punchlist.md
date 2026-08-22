# Audiobook ecosystem punchlist

Ordered set of things to do to get audiobooks working, with the commands to do
them. Written 2026-08-22, with both stacks committed but never deployed. Delete
this file once it's all ticked — it's a working list, not reference material.

Detail lives in [audiobooks.md](audiobooks.md) (why this shape),
[audiobookshelf.md](audiobookshelf.md) and [shelfarr.md](shelfarr.md).

**Four hard ordering constraints:**

1. **beszel goes through Komodo first (step 3), before either of these stacks
   does (step 17).** `komodo.md` step 6 says the first Komodo-managed stack must
   be one that already works. Make a brand new app the guinea pig and a red
   deploy could be the app, the compose file, the periphery agent, the PKI
   handshake, the secret render, or the sync — six candidates and no way to
   bisect them.
2. **The `media` user and `/srv/media` (step 4) must exist before Audiobookshelf
   is deployed (step 5).** Audiobookshelf runs as root and cannot be told
   otherwise. Let it build the library tree first and you spend step 8 chasing
   ownership across files that are already there.
3. **The root account (step 6) before `books.<domain>` ever leaves the LAN-only
   block (step 18).** Audiobookshelf hands admin to whoever loads the site
   first, exactly like Immich, and there is no `IMMICH_ALLOW_SETUP=false`
   equivalent to fall back on.
4. **Verify the tunnel (step 11) before adding a single indexer (step 13).** An
   indexer query that leaves on the house address cannot be un-sent.

---

## 0. Commit and push from your PC

Nothing below works on forge until this lands.

```powershell
cd $HOME\Claude\Projects\"Podman Home Containers"
git add -A
git commit -m "audiobookshelf and shelfarr stacks, komodo resources, caddy blocks"
git push
```

---

## 1. Find out where you actually are

Several of these are easy to have half-done. Run the block and read the output —
it tells you which steps below to skip.

```bash
ssh forge
cd ~/home-containers && git pull

echo "--- komodo core up? ---"
docker ps --filter name=komodo --format '{{.Names}}  {{.Status}}'

echo "--- has beszel ever deployed? ---"
docker ps -a --filter name=beszel --format '{{.Names}}  {{.Status}}'

echo "--- uid/gid 3000 free? (want: NO output) ---"
getent passwd 3000; getent group 3000

echo "--- proxy subnet (must be 172.18.0.0/16) ---"
docker network inspect proxy -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'

echo "--- /dev/net/tun present? gluetun cannot start without it ---"
ls -l /dev/net/tun 2>/dev/null || echo "MISSING - sudo modprobe tun"

echo "--- space on /srv ---"
df -h /srv | tail -1

echo "--- anything from these stacks already running? ---"
docker ps -a --format '{{.Names}}  {{.Status}}' \
  | grep -E 'audiobookshelf|gluetun|qbittorrent|prowlarr|sabnzbd|shelfarr' \
  || echo "none - clean slate"
```

If the proxy subnet is anything other than `172.18.0.0/16`, stop and fix
`GLUETUN_OUTBOUND_SUBNETS` in `stacks/shelfarr/compose.yml` before step 10 —
gluetun's kill switch will otherwise drop Caddy's reply packets and every
tunnelled web UI times out, which presents as an application fault.

---

## 2. Verify the image tags — all seven

The tags in both compose files are best-known values, **not** values confirmed
against the registries. Anything that prints `MISSING` gets corrected in a
commit before you deploy.

```bash
for img in \
  ghcr.io/advplyr/audiobookshelf:2.35.1 \
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

Shelfarr's is the one most likely to be wrong — its release page and its repo
page disagree about the current version, and the `v` on the git tag may or may
not carry into the container tag.

```bash
curl -s https://api.github.com/repos/Pedro-Revez-Silva/shelfarr/releases/latest | grep tag_name
curl -s https://api.github.com/repos/advplyr/audiobookshelf/releases/latest | grep tag_name
```

---

## 3. Do beszel through Komodo

Skip if step 1 showed beszel running and you have already deployed it from the
Komodo UI.

This is constraint 1, and it is the step most worth not skipping. Follow
[komodo.md](komodo.md) steps 6 and 7 — build the stack in the UI from
`komodo/beszel.toml`, export it, reconcile the field spellings, deploy, run the
smoke test, then turn on the Resource Sync unmanaged before managed.

The reconcile is the point: the `pre_deploy` / `post_deploy` spelling in every
`komodo/*.toml` in this repo is inferred from upstream's Repo docs and not
confirmed for Stacks. Confirm it once, on a stack that already worked, and every
file after it is trustworthy.

---

## 4. The `media` user and the directory tree

Constraint 2. Do this before anything is deployed.

Audiobookshelf runs as root; every container in the shelfarr stack runs as
uid/gid 3000 with `umask 002`. A setgid tree is what lets those two coexist.

```bash
sudo groupadd -g 3000 media
sudo useradd -u 3000 -g 3000 -M -s /usr/sbin/nologin media

sudo mkdir -p /srv/media/{audiobooks,podcasts,downloads/{incomplete,complete}}
sudo mkdir -p /srv/audiobookshelf/{config,metadata}
sudo mkdir -p /srv/shelfarr/{gluetun,qbittorrent,prowlarr,sabnzbd,shelfarr}

sudo chown -R media:media /srv/media /srv/shelfarr
sudo chmod -R 2775 /srv/media
sudo chmod -R 0755 /srv/shelfarr
```

Verify the setgid bit took — some `chmod` invocations drop it silently:

```bash
stat -c '%A %U:%G %n' /srv/media /srv/media/audiobooks /srv/media/downloads
# want: drwxrwsr-x media:media   <- an `s` in the group triad, not an `x`
```

`/srv/media` is deliberately not under `/srv/audiobookshelf`. Downloads and
library have to share one bind-mount boundary or hardlinking fails and every
import silently becomes a full copy — step 15 is the test.

---

## 5. Deploy Audiobookshelf

```bash
cd ~/home-containers
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/audiobookshelf \
  TZ=America/Chicago

./scripts/deploy.sh audiobookshelf
```

The stack has no required secrets — the Infisical path exists only so
`scripts/komodo-env.sh render` has somewhere to export from in step 17. Reasons
in [audiobookshelf.md](audiobookshelf.md#why-a-stack-with-no-secrets-still-gets-the-hooks).

Then Caddy. **After a `git pull`, `caddy reload` is not enough** — the Caddyfile
is a single-file bind mount and Docker binds it by inode, so reload re-reads the
old content and reports success:

```bash
docker exec caddy grep -c audiobookshelf /etc/caddy/Caddyfile   # 0 means stale
./scripts/deploy.sh caddy -- --force-recreate
docker exec caddy caddy validate --config /etc/caddy/Caddyfile

curl -s -o /dev/null -w '%{http_code}\n' https://books.brent-miles.com   # 200
```

---

## 6. Claim the root account, and build the library

Constraint 3. **Do it in this session, not tomorrow.**

At `https://books.brent-miles.com`:

1. Create the root user.
2. **Settings → Users → Add User** for your wife. Role `user`, not `admin` —
   playback position is per account, which is the whole reason not to share one
   login.
3. **Libraries → Add Library**, type *Book*, folder `/audiobooks`.
4. **Settings → Item Metadata Utils → metadata provider: Audible.** The default
   is Google Books, which is a book database that happens to know some
   audiobooks exist.
5. Leave **Store metadata with item** off. On, it writes `metadata.json` beside
   the audio files, which is nice for portability and annoying once a download
   client is touching the same tree.

Then put five or ten real books in, matching the layout Audiobookshelf reads
structurally:

```
/srv/media/audiobooks/Brandon Sanderson/Mistborn/1 - The Final Empire/book.m4b
/srv/media/audiobooks/T Kingfisher/Nettle & Bone/book.m4b
```

Free sources that need nothing else built: LibriVox, and anything already
bought from Libro.fm. Hit **Scan**.

```bash
sudo chown -R media:media /srv/media/audiobooks   # re-run after any manual drop
```

---

## 7. Her phone — the cheapest possible failure

Do this before building the automation stack. If she doesn't like the player,
none of steps 8–16 matter and you've spent nothing.

**There is no official Audiobookshelf app on the iOS App Store** — TestFlight
only, and that beta repeatedly hits Apple's 10,000-tester cap.

1. Install **Plappa** (free, CarPlay) on her phone.
2. Server `https://books.brent-miles.com`, her account from step 6.
3. Download a book on home wifi, then turn wifi off and play it in the car.

That last part is the actual test. `books.<domain>` is LAN-only until step 18,
so downloading at home and listening anywhere is the state you are in — and it
is worth living in for a week before deciding a second public hostname is worth
it.

**Stop here for a week.** Everything below is optional and adds five containers
of maintenance.

---

## 8. Pick a VPN provider

Not commands — a decision to have made before the software matters.

| Provider | `VPN_TYPE` | Keys it needs | Port forwarding |
|---|---|---|---|
| **ProtonVPN** | `wireguard` | `WIREGUARD_PRIVATE_KEY` | Yes, gluetun supports it natively |
| **Mullvad** | `wireguard` | `WIREGUARD_PRIVATE_KEY`, `WIREGUARD_ADDRESSES` | **No** — removed 2023 |
| **PIA** | `openvpn` | `OPENVPN_USER`, `OPENVPN_PASSWORD` | Yes |

- [ ] ProtonVPN if you intend to seed; Mullvad if you don't. Port forwarding is
      the only real differentiator, and with SABnzbd carrying the primary load
      "seeds badly" is a smaller problem than it looks.
- [ ] Generate the WireGuard config in the provider's portal and keep the
      **private key** and the **address**. Do not download their `.conf` file
      and point gluetun at it — gluetun wants the values, not the file.
- [ ] A Usenet **provider** and a Usenet **indexer** are separate purchases,
      ~$50–80/yr together. The stack deploys fine without them; SABnzbd just
      sits idle.

---

## 9. Put the VPN secrets in Infisical

Single-quote every value. WireGuard keys are base64 and routinely contain `/`
and `+`; provider passwords contain whatever their generator felt like.
Unquoted, your shell eats part of it and gluetun reports an authentication
failure that reads like a wrong password rather than a truncated one.

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
# OpenVPN (PIA) - replace the two WIREGUARD_ lines above with these
  OPENVPN_USER='<username>' \
  OPENVPN_PASSWORD='<password>' \
  VPN_PORT_FORWARDING='on'
```

Confirm what landed, without printing values:

```bash
infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/shelfarr | awk '{print $1}'
```

---

## 10. Deploy the automation stack

```bash
cd ~/home-containers
./scripts/deploy.sh shelfarr

docker logs -f gluetun
# want: "healthy!"  -  Ctrl-C once it says so
```

The two tunnel containers are gated on gluetun's healthcheck and sit in
`Created` until it passes. That is correct, not a hang.

```bash
docker compose -f stacks/shelfarr/compose.yml ps    # all six Up (healthy)

docker exec caddy grep -c torrents /etc/caddy/Caddyfile   # 0 means stale
./scripts/deploy.sh caddy -- --force-recreate
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

---

## 11. Verify the tunnel — both tests

Constraint 4. Neither is optional and the second is the one people skip.

**a. Traffic actually leaves through the VPN:**

```bash
curl -s https://api.ipify.org; echo                          # forge's real WAN address
docker exec qbittorrent curl -s https://api.ipify.org; echo  # must be DIFFERENT
docker exec prowlarr    curl -s https://api.ipify.org; echo  # must be DIFFERENT
docker exec sabnzbd     curl -s https://api.ipify.org; echo  # must be the SAME, by design
```

If the qbittorrent line matches your WAN address, stop. Nothing else here
matters until it doesn't.

**b. The kill switch actually kills:**

```bash
docker exec gluetun ip link                       # find the tunnel iface, usually tun0
docker exec gluetun ip link set tun0 down

docker exec qbittorrent curl -s -m 5 https://api.ipify.org \
  && echo "LEAKING - stop and fix" \
  || echo "no route - kill switch holding"

docker restart gluetun
```

The result you want is a timeout, not an address.

---

## 12. qBittorrent

The linuxserver image prints a temporary password exactly once:

```bash
docker logs qbittorrent 2>&1 | grep -i 'temporary password'
```

`https://torrents.brent-miles.com` will return a bare **Unauthorized** rather
than a login page, and nothing in the UI explains why. It is Host header
validation, there is no environment variable for it, and the setting lives in
the file the container just wrote:

```bash
docker stop qbittorrent

sudo tee -a /srv/shelfarr/qbittorrent/qBittorrent/qBittorrent.conf >/dev/null <<'EOF'
WebUI\HostHeaderValidation=false
WebUI\CSRFProtection=false
EOF

docker start qbittorrent
```

Both are safe here and would not be if this were public: only Caddy can reach
port 8080, and only the LAN can reach Caddy on this hostname.

Then in the UI:

- [ ] **Tools → Options → Web UI** — change off the temporary password.
- [ ] **Downloads → Save files to** `/srv/media/downloads/complete`
- [ ] **Downloads → Keep incomplete torrents in** `/srv/media/downloads/incomplete`

Those are the same strings inside and outside the container. Do not type
`/downloads`.

---

## 13. SABnzbd

Skip if you didn't buy a Usenet provider in step 8.

`https://usenet.brent-miles.com` opens a wizard.

- [ ] Provider host, port 563, SSL on, username, password. Connections: start at 20.
- [ ] **Config → Folders → Temporary Download Folder** `/srv/media/downloads/incomplete`
- [ ] **Config → Folders → Completed Download Folder** `/srv/media/downloads/complete`
- [ ] **Config → General → Host whitelist** — add `usenet.brent-miles.com`, or
      proxied requests are rejected. Do it in the UI; SAB rewrites its ini on
      shutdown and discards a hand edit made while running.
- [ ] **Config → General → API Key** — copy it, you need it in step 14.

```bash
docker exec sabnzbd grep -n '^host_whitelist' /config/sabnzbd.ini
```

---

## 14. Prowlarr

`https://indexers.brent-miles.com`.

- [ ] Set authentication (Forms, real password) — it demands this before letting
      you in.
- [ ] **Settings → General → API Key** — copy it.
- [ ] **Indexers → Add Indexer.** This is where the sourcing question from
      [audiobooks.md](audiobooks.md#where-the-books-come-from) gets answered, and
      it is yours to answer. LibriVox is here and costs nothing. A paid Usenet
      indexer goes here too, not in SABnzbd.

Confirm searches leave through the tunnel — step 11 already proved it, but do it
again after the first indexer is added, because a misconfigured indexer with its
own proxy setting is a real thing:

```bash
docker exec prowlarr curl -s https://api.ipify.org; echo
```

---

## 15. Shelfarr — wire the four services together

`https://request.brent-miles.com`. Create the admin account immediately, same
reasoning as step 6.

Then **Settings**:

| Setting | Value |
|---|---|
| Prowlarr URL | `http://gluetun:9696` |
| Prowlarr API key | step 14 |
| qBittorrent URL | `http://gluetun:8080` |
| SABnzbd URL | `http://sabnzbd:8080` |
| SABnzbd API key | step 13 |
| Audiobookshelf URL | `http://audiobookshelf:80` |
| Audiobookshelf API key | ABS → Settings → Users → your account → API token |
| Audiobook library path | `/srv/media/audiobooks` |
| Download path | `/srv/media/downloads/complete` |

**`gluetun`, not `qbittorrent` or `prowlarr`.** Those two run in gluetun's
network namespace and have no name on any network — their ports belong to
gluetun. The Caddyfile does the same thing, and it catches everyone once.

---

## 16. Verify hardlinking — the silent failure

If this is wrong everything still works, and every import quietly doubles your
disk usage.

```bash
for c in shelfarr qbittorrent; do
  docker exec "$c" sh -c '
    touch /srv/media/downloads/complete/.hltest &&
    ln /srv/media/downloads/complete/.hltest /srv/media/audiobooks/.hltest &&
    echo "hardlinks OK" ||
    echo "EXDEV - separate mounts, imports will copy";
    rm -f /srv/media/downloads/complete/.hltest /srv/media/audiobooks/.hltest' \
  | sed "s/^/$c: /"
done
```

EXDEV means the single `/srv/media:/srv/media` mount in `compose.yml` has been
split into per-directory binds. Put it back.

Then request one book end to end and watch it land:

```bash
docker logs -f shelfarr
ls -l /srv/media/audiobooks/
```

---

## 17. Libation, and then Komodo

**Libation.** The sidecar has no hostname and is not reachable from a browser —
it is driven from **Shelfarr → Settings → Libation → Link account**, which runs
Audible's device registration.

```bash
docker logs -f shelfarr-libation
```

**Komodo.** Both stacks, in this order, and only now that beszel proved the path
in step 3. Same routine each time: build the Stack in the UI from
`komodo/<name>.toml`, export to TOML, reconcile, deploy from the UI, then:

```bash
for s in audiobookshelf shelfarr; do
  echo "--- $s ---"
  readlink -f ~/home-containers/stacks/$s/.env | xargs ls -l 2>&1 | tail -1
  # want: "No such file" - post_deploy cleaned the tmpfs target
done

./scripts/deploy.sh audiobookshelf    # the manual path must still work
./scripts/deploy.sh shelfarr
```

If either refuses with `.env exists`, a Komodo deploy failed and left a live
file behind. That is the guard working, not a bug.

---

## 18. Going public — later, and on purpose

Constraint 3 is a prerequisite: step 6 must be done. This is its own evening and
its own commit, and **only `books.<domain>` ever moves.** The four shelfarr
hostnames stay in the LAN-only block permanently.

Full checklist in [audiobooks.md](audiobooks.md#exposure). In order:

- [ ] A `decisions.md` entry, per the Caddyfile's own rule.
- [ ] Move the `books` block to the PUBLIC zone with its own
      `books-access.log`, and add `header_up X-Forwarded-For {remote_host}`.
- [ ] Add `books` to the DDNS updater's record list — one variable, not a second
      container.
- [ ] Verify the real client IP reaches the app. Audiobookshelf is
      Node/Express, the same architecture that made `IMMICH_TRUSTED_PROXIES`
      necessary, and it does not inherit Immich's fix. Fail a login from
      cellular and read the logs for your carrier's address.
- [ ] Test from outside on cellular: `books` answers; `request`, `torrents`,
      `indexers`, `usenet` all return closed connections.

That last line matters more than the first.

---

## What's deliberately still open afterwards

1. **`bootstrap.sh`** creates none of step 4 — not the `media` user, not
   `/srv/media`, not `/srv/shelfarr`. A rebuild from bare metal misses all of
   it. Highest-value follow-up here.
2. **`docs/decisions.md`** has no entry for either stack. Three decisions are
   worth writing down properly: SABnzbd outside the tunnel while Prowlarr is
   inside it, the single `/srv/media` mount over upstream's three, and
   Audiobookshelf as the second public hostname.
3. **Audiobookshelf runs as root** and writes `root:media` 644 into a tree the
   rest of the stack wants group-write on. Not biting yet; the fix is a `umask`
   on that container or a periodic fixup, and it should be decided rather than
   discovered.
4. **Backups.** `/srv/audiobookshelf/config` holds every playback position in
   the house and `/srv/shelfarr/shelfarr` holds every API key typed into a UI.
   Both are small, neither is in the backup set. `/srv/media` is large and
   re-acquirable and does not belong in it.
5. **CrowdSec on `books-access.log`**, if step 18 happens — same unresolved
   `xcaddy` dependency as Immich. If both hostnames want protection, that is the
   argument for finally owning the Dockerfile.
6. **Shelfarr itself.** Eleven months old, one maintainer. Re-evaluate in six
   months; the library is unaffected either way, which is the whole reason it
   lives in a different stack.
