# Shelfarr — the audiobook automation stack

Reference for `stacks/shelfarr`. The ordered set of things to *do* is
[audiobooks-punchlist.md](audiobooks-punchlist.md) — this is the why, and the
four things that will bite.

Six containers, named after the one you actually look at:

| Container | Job | Network |
|---|---|---|
| `gluetun` | VPN tunnel + kill switch | `proxy` |
| `qbittorrent` | torrents | none of its own — gluetun's |
| `prowlarr` | indexer manager | none of its own — gluetun's |
| `sabnzbd` | usenet | `proxy` |
| `shelfarr` | request UI + importer | `proxy` + `shelfarr-internal` |
| `shelfarr-libation` | Audible → DRM-free m4b | `shelfarr-internal` only |

**Nothing here is ever public.** Four LAN-only hostnames, no published ports. A
torrent client with a web UI on the open internet is a compromise waiting for a
slow afternoon.

---

## Why it is a separate stack from audiobookshelf

`stacks/audiobookshelf` holds the library and every playback position in the
house, and should be boring for years. This stack is built on a project that is
eleven months old with one maintainer, and it will churn.

Splitting them means the churn is survivable: Shelfarr can be swapped for
whatever replaces it without touching the thing that holds the state. That is
also why Shelfarr keeps no library state of its own — it is plumbing, and it is
meant to be replaceable from the day it is installed.

Readarr, the obvious answer to this problem, is **retired** — the Servarr team
pulled it when its metadata source became unusable and the Open Library
migration stalled. There is no mature Sonarr-for-books in 2026 and no sign of
one arriving. See [audiobooks.md](audiobooks.md#the-automation-layer-is-the-churn-risk)
for what was compared.

---

## gluetun owns the network namespace

`qbittorrent` and `prowlarr` run with `network_mode: "service:gluetun"`. They
get gluetun's interfaces, routing table and firewall. If the tunnel drops they
have no route to anywhere — not a policy, a physical fact about their network
stack.

Four consequences, and they are the source of most confusion with this pattern:

- Those containers can have **no `networks:` key and no `ports:` key**. Compose
  rejects both alongside `network_mode`.
- **Caddy proxies to `gluetun:8080` and `gluetun:9696`**, never
  `qbittorrent:8080`. There is no such name on any network. Shelfarr's own
  settings need the same URLs.
- They reach `sabnzbd` and `shelfarr` by name **only because gluetun is on
  `proxy`**. Take gluetun off that network and they go deaf.
- A gluetun restart takes the indexer UI down along with the torrent UI.

### `FIREWALL_OUTBOUND_SUBNETS` is the one to check first

The kill switch is a firewall and it blocks in both directions. Caddy lives on
`proxy` at `172.18.0.0/16` — the subnet `bootstrap.sh` pins explicitly, for the
reasons in [public-access.md](public-access.md#the-subnet-is-now-pinned) — and
without that variable the reply packets to Caddy are dropped along with
everything else that is not the tunnel.

The symptom is a reverse-proxy timeout, which looks like an application fault.
If that pinned subnet ever moves, this breaks and nothing says so.

---

## Prowlarr is inside the tunnel; SABnzbd is deliberately outside it

**Prowlarr, inside.** It is the container that talks to indexers — searching,
authenticating, refreshing capabilities on a timer. Those queries are the part
of this stack that most obviously identifies the house, and they happen
continuously whether or not anything is downloading. Tunnelling the transfers
and not the queries would be protecting the loud half and leaving the persistent
half alone.

**SABnzbd, outside.** Three reasons, and the first is the real one:

1. **There is no swarm.** Usenet is a single authenticated TLS connection to a
   provider you pay, who already knows exactly who you are. Nobody else observes
   the transfer, so the VPN hides nothing that is not already disclosed — unlike
   a torrent, where the address is published to every peer.
2. **Throughput.** SABnzbd with 20–50 connections will saturate the line;
   userspace WireGuard in a container will not, and this is the one workload
   here that can actually notice.
3. **Blast radius.** Behind gluetun, a tunnel restart kills usenet downloads
   too — and then the fallback path fails at the same moment as the primary.

If that ever needs to change it is one `network_mode` line plus moving the Caddy
upstream from `sabnzbd:8080` to `gluetun:8081`.

---

## One mount, `/srv/media:/srv/media`, same path inside and out

Upstream Shelfarr's own example mounts `/audiobooks`, `/ebooks` and `/downloads`
as three separate binds. This repo does not follow it, and that divergence is
deliberate.

Three bind mounts are three mount boundaries. `link()` fails `EXDEV` across
them, so every import silently becomes a full byte-for-byte copy — everything
keeps working and the disk usage doubles. Punchlist step 16 is the test, and it
is worth actually running rather than assuming.

Same path inside as outside means the paths in qBittorrent's settings,
Shelfarr's settings and your ssh session are all the same string, which removes
the other classic failure: a path mapping that is right in two places out of
three.

If a future Shelfarr version turns out to hardcode those three container paths,
that is the moment to revisit. Not before.

---

## File ownership

Every container in this stack runs as uid/gid **3000** (`media`) with
`umask 002`. Audiobookshelf runs as root and cannot be told otherwise.

The setgid tree from punchlist step 4 is what lets those coexist: `chmod 2775`
on `/srv/media` means anything created below inherits group `media` regardless
of which container created it, and `umask 002` means this stack's files are
group-writable so Shelfarr can move, hardlink and delete what qBittorrent wrote.

`CHOWN_ON_START: never` on the shelfarr container is part of this. On the
default `auto` it walks and chowns every mounted path at startup — a slow boot
on a large library, and one that will happily rewrite ownership that was set
deliberately.

---

## qBittorrent returns "Unauthorized" through Caddy

Not a Caddy problem, and it will be your first symptom. qBittorrent rejects
requests whose `Host` header it does not recognise and presents that as a bare
*Unauthorized* with nothing in the UI explaining why.

There is no environment variable. The setting lives in
`/config/qBittorrent/qBittorrent.conf`, which does not exist until the container
has started once, so it has to be appended with the container stopped —
punchlist step 12.

`HostHeaderValidation=false` and `CSRFProtection=false` are safe here and would
not be if this were public: only Caddy can reach port 8080, and only the LAN can
reach Caddy on this hostname.

---

## Libation holds a real credential

`shelfarr-libation` is on `shelfarr-internal` and nothing else. It has no
hostname in the Caddyfile and is driven entirely through Shelfarr's UI.

It holds an authenticated Audible session — a real account with a payment method
attached. That is the strongest argument in this stack for keeping something
unreachable, and it is the same shape as homelable's backend sitting off the
proxy network behind its own frontend.

Converted files stage in the `libation_books` volume and reach the library
through an import that names and organises them, rather than by appearing in the
library folder. Nothing should arrive in `/srv/media/audiobooks` by materialising
there.

---

## Image tags are unverified

The six defaults in `compose.yml` are best-known values, not values confirmed
against the registries from here. Punchlist step 2 checks all of them with
`docker manifest inspect` and it should be run before the first deploy.

Shelfarr's is the most likely to be wrong — its release page and its repo page
disagree about the current version, and the `v` prefix on the git tag may or may
not carry into the container tag.

A tag that does not exist fails at pull time, which is loud and cheap. A tag
that exists and is wrong is neither.
