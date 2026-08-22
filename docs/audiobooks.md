# Audiobooks

Written 2026-08-22. **Plan only — nothing here is built yet.** No compose files,
no Infisical paths, no DNS records. This is the shape of the thing and the order
to build it in.

---

## Read this first: it does not replace PocketFM

PocketFM is not an audiobook store. It sells *original serialized audio series* —
content Pocket FM commissions and owns, released chapter by chapter, that exists
nowhere else. There is no file to buy, no DRM to legitimately strip, and no
catalogue overlap to speak of.

So the honest framing is: **this becomes the house's library for real
audiobooks, and PocketFM stays on her phone for her serials.** Two apps. If the
pitch is "I'll replace the app you already like," it fails on day one and the
server never gets used. If the pitch is "the Sanderson and the Kingfisher and
the twelve books your sister keeps recommending now live here, for free, forever,"
that lands.

---

## The stack

| Container | Job | Zone |
|---|---|---|
| `audiobookshelf` | Library, streaming, per-user progress sync | **PUBLIC** — `books.{domain}` |
| `shelfarr` | Request UI + automation glue | LAN-only |
| `prowlarr` | Indexer aggregator, feeds Shelfarr | LAN-only |
| `qbittorrent` | Download client | LAN-only, inside Gluetun |
| `gluetun` | VPN with kill-switch, owns qBittorrent's network | LAN-only |
| `libation` *(later)* | Audible library → DRM-free m4b | not a service; runs on demand |

Five containers for the automated version. **Audiobookshelf alone is one
container**, and it is worth being clear-eyed that the one container delivers
most of the value while the other four deliver most of the maintenance.

### Audiobookshelf is the durable piece

It is the right answer and there is not a close second. Purpose-built for
audiobooks rather than a music server with books bolted on: chapter support,
per-user playback position that survives switching devices, sleep timer,
variable speed, Audible metadata matching, series and author browsing, and
genuine multi-user — her progress, your progress, and the kids' progress are
independent accounts on one library. It also serves epubs if you ever want them,
which keeps the door open on the ebook question without paying for it now.

Data lives in a plain folder tree of plain files. If Audiobookshelf disappeared
tomorrow the library would still be a library. That is the property that makes it
safe to build on.

### The automation layer is the churn risk, and you should know why

**Readarr is retired.** The Servarr team pulled the plug: its metadata source
became unusable, nobody had the time to rebuild it on Open Library, and the
community migration stalled. The wiki's own advice is to go find something else.
There is no Sonarr-for-books with Sonarr's maturity, and in August 2026 there is
no sign of one arriving.

What actually exists:

| Option | State | Notes |
|---|---|---|
| **Shelfarr** | v0.32.3, Jul 2026, ~230 stars | Best current fit. Request UI, Prowlarr/Jackett/NZBHydra2, every major download client, and **native Audiobookshelf library sync**. Ruby/Rails. Young, but shipping. |
| **Listenarr** | beta, ~840 stars | Audiobook-specific, more popular, but self-described beta with an explicit "expect security holes, don't expose it" warning. No Prowlarr integration. ABS integration is still roadmap. |
| **Readarr + rreading-glasses** | zombie | Third-party metadata proxy that revives the retired codebase. Works today. It is a dead project on life support and the ebook side is what it was built for. |
| **LazyLibrarian** | alive, ancient | Does audiobooks. Looks and behaves like 2015. Genuinely stable, which counts for something. |

Recommendation: **Shelfarr**, and treat it as replaceable from the start. Keep
its config in the stack directory, keep zero library state in it, and assume you
will swap it inside two years. Audiobookshelf is the thing that has to last;
this is plumbing.

### The download client is the part that needs real care

qBittorrent goes **inside Gluetun** — `network_mode: "service:gluetun"` — with
the VPN's kill-switch on, so the container physically cannot reach the internet
if the tunnel drops. Not optional, and for a reason specific to this house: 443
is already forwarded to `forge` and `photos.{domain}` publishes your WAN address
to the world every five minutes. Adding a torrent client that advertises that
same address in tracker swarms is a materially different exposure story than
adding one behind a residential IP nobody has a name for.

Two consequences of `network_mode: "service:gluetun"` that will bite:

- qBittorrent publishes **no ports of its own**. Its WebUI port is published by
  the `gluetun` service. Get this wrong and the container starts fine and is
  simply unreachable.
- Caddy must proxy to **`gluetun:8080`**, not `qbittorrent:8080`. The
  qBittorrent container has no address on the proxy network.
- The healthcheck still targets `127.0.0.1` per
  [compose-conventions](decisions.md) — that rule is if anything more important
  here, because the shared netns makes name resolution one more thing that can
  lie to you.

---

## The iPhone problem — settle this before building anything

**There is no official Audiobookshelf app on the App Store.** The official iOS
build is TestFlight-only, TestFlight betas cap at 10,000 testers, and the
Audiobookshelf beta has repeatedly been full. Android gets a real Play Store
listing; iOS does not. In a house of iPhones this is the single most important
fact on this page, and it is the one that would have blown up in your face on
demo night.

The ecosystem solved it with third-party clients, and they are good — better
than the official app, in most people's telling:

| App | Cost | CarPlay | Offline | Notes |
|---|---|---|---|---|
| **Plappa** | Free, optional IAP | Yes | Paid unlock | Best default. Native, well-reviewed, iCloud + server progress sync. |
| **ShelfPlayer** | $5.99 once | Yes | Yes | No upsell, no tiers. Buy-once-and-forget. |
| **SoundLeaf** | Free + one-time under $10 | Yes | Paid unlock | Polished, actively marketed. |
| **CLAUDIO** | Free tier + paid | Yes | Paid tier | Remote servers are behind the paywall — which is exactly your use case. |

**Do this before you write a single compose file:** install Plappa on her phone,
point it at the public Audiobookshelf demo server, and let her drive it for ten
minutes in the car. If she hates the player, none of the rest matters and you've
spent nothing. If she likes it, you now know which app you're building for and
you can buy ShelfPlayer instead if Plappa's download unlock annoys you.

---

## Storage

Space is not a concern. `/srv` has 885G free and the volume group has another
~463GiB unallocated, per [storage-expansion.md](storage-expansion.md).

The arithmetic: a 64kbps mono m4b runs about 30 MB/hour, so a typical ten-hour
book is ~300 MB and a chunky 128kbps release is maybe double that. **500 books
lands between 150 and 300 GB.** That is a rounding error next to Frigate's
retention and it will never be the thing that fills the disk.

Proposed layout:

```
/srv/audiobookshelf/config      # ABS database and settings
/srv/audiobookshelf/metadata    # covers, cached artwork
/srv/media/audiobooks           # THE LIBRARY - the only irreplaceable path
/srv/media/downloads            # qBittorrent's incomplete + complete
```

**`audiobooks/` and `downloads/` must be on the same filesystem, mounted into
every container at the same path.** This is the classic \*arr footgun. If the
download client sees `/downloads` and the importer sees `/media/downloads`, the
importer cannot hardlink — it falls back to a full copy, which doubles the disk
usage of everything you seed and turns instant imports into multi-minute ones.
Both are under `/srv/media`, both get bind-mounted as `/srv/media`, no
exceptions and no clever per-container shortcuts.

Library naming, which Audiobookshelf reads structurally:

```
/srv/media/audiobooks/Author Name/Series Name/1 - Book Title/book.m4b
/srv/media/audiobooks/Author Name/Standalone Title/book.m4b
```

Single-file `.m4b` with embedded chapters is the format to normalise on. Folders
of 200 numbered mp3s work but chapter navigation is worse and the metadata is
usually garbage.

---

## Exposure

`books.{domain}` becomes the **second** public hostname, following the
`photos.{domain}` precedent exactly. Everything else in this stack stays behind
the wildcard's LAN guard, permanently.

Per the Caddyfile's own rule — *a new app goes in the LAN-ONLY block unless
exposing it was a deliberate decision written down in decisions.md* — this needs
an entry in [decisions.md](decisions.md) before the site block is written.

What has to happen:

1. **A new exact site block** for `books.{domain}` in the PUBLIC zone, with its
   own `books-access.log` for CrowdSec to parse later. Exact hostnames beat the
   wildcard on specificity, so file position doesn't matter.
2. **`header_up X-Forwarded-For {remote_host}`** — overwrite, not append, same
   as Immich, same reasoning, same "revisit if Cloudflare's orange cloud ever
   goes in front" caveat.
3. **Websockets need nothing.** Caddy v2's `reverse_proxy` handles the upgrade
   automatically. Audiobookshelf leans on websockets heavily for progress sync,
   so this is worth knowing you don't have to do.
4. **Add `books` to the DDNS updater's managed records.** `favonia/cloudflare-ddns`
   takes a list; this is one variable, not a second container.
5. **Turn off open registration in Audiobookshelf immediately.** This is the
   `IMMICH_ALLOW_SETUP=false` lesson in a different shirt: the first account
   created is the admin, and "first" stops meaning "you" the moment 443 answers
   for this hostname. Create the accounts on the LAN, verify registration is
   closed, *then* add the DNS record.
6. **Verify the client IP reaches the app.** Audiobookshelf is Node/Express
   underneath, the same architecture that made `IMMICH_TRUSTED_PROXIES`
   necessary. Do not assume it inherits Immich's fix — fail a login from
   cellular and read the logs for the carrier address, exactly as
   [public-access.md](public-access.md) prescribes.
7. **Prowlarr, qBittorrent and Shelfarr get no hostname outside the wildcard.**
   A torrent client with a web UI on the open internet is a compromise waiting
   for a slow afternoon. If you ever want them remotely, that is what Tailscale
   is for.

The hairpin-NAT caveat from `photos` applies here too: `books.{domain}` will
resolve to the WAN address on the sofa as well as in the car. Streaming audio is
light enough that the throughput cost is irrelevant, but if the Orbi's hairpin is
flaky it will be flaky for both hostnames at once.

---

## Where the books come from

Four legitimate sources, roughly in order of how much library they'll actually
produce:

**Libby / Hoopla — free, and needs nothing from you.** A library card gets her a
large audiobook catalogue at no cost. It is DRM'd, it will never live on your
server, and that is fine. This is genuinely the highest-value thing on this page
and it takes twenty minutes at the library's website. Set it up for her *first*,
before the server exists — worst case, she's happy and you build the server for
your own reasons.

**Libro.fm — DRM-free purchases that drop straight into the library.** You get
actual m4b files with no strings; the money routes to an independent bookstore
of your choosing. This is the paid path that requires zero engineering: buy,
download, drop in `/srv/media/audiobooks`, Audiobookshelf picks it up on scan.

**Audible + Libation — for what's already owned.** Libation logs into an Audible
account and converts owned titles to DRM-free m4b with chapters and cover art
intact. It is a desktop/CLI app rather than a service, so it runs on demand
rather than living in the stack. If either of you has an Audible history, this is
free library sitting in an account you already pay for.

**LibriVox — free public-domain readings.** Volunteer-narrated, quality is
uneven, but the classics are all there and it costs nothing. Shelfarr can search
it directly.

**On the automated indexers:** the stack above is neutral infrastructure —
Prowlarr, qBittorrent and Shelfarr are the same tools people use for Linux ISOs,
public-domain readings and their own purchases. What it becomes depends entirely
on which indexers you configure, and that choice is yours to make with open eyes.
I'll build the plumbing and wire up sources you tell me to; I'm not going to
research trackers for you. Worth knowing that the DRM-free paths above are less
work than most people expect, and that Libby covers more than most people assume.

---

## Build order

Each step is useful on its own and safe to stop at.

1. **Set up her library card** on Libby/Hoopla. Zero infrastructure. Possibly
   the end of the project.
2. **Test a client app** on her phone against the Audiobookshelf demo server.
   Ten minutes, no commitment, tells you whether any of this is worth doing.
3. **Audiobookshelf, LAN-only**, behind the wildcard like everything else. Seed
   it by hand with five or ten books from Libro.fm, Libation or LibriVox.
4. **Let her live with it for a week** on home wifi with downloads. If the
   library sits untouched, stop here — you've spent one container.
5. **Go public**: decisions.md entry, Caddy site block, DDNS record, registration
   closed, client-IP verification, cutover test from cellular.
6. **Only then, the automation**: Gluetun + qBittorrent, verified kill-switch,
   then Prowlarr, then Shelfarr last.

Steps 1–4 are a weekend of evenings. Step 6 is where the ongoing maintenance
lives, and it is the step most likely to be worth skipping.

---

## Repo conventions this must follow

Nothing here is new, but all of it applies:

- **`${VAR:-}` on every Infisical-injected variable**, plus the name in
  `required_vars()` in `deploy.sh`. Bare `${SECRET}` is a bug in this repo.
- **Healthchecks target `127.0.0.1`**, never `localhost`. Doubly true inside
  Gluetun's shared network namespace.
- **Anything that writes a `.env`** double-quotes and escapes `$` — the VPN
  credentials will contain characters that punish sloppiness here.
- **The Caddyfile is a single-file bind mount.** After a `git pull`,
  `caddy reload` re-reads the old inode and reports success. Use
  `./scripts/deploy.sh caddy -- --force-recreate`.

---

## Still open

- **Whether ebooks join later.** Audiobookshelf serves epubs; its reader is
  adequate rather than good. If ebooks become a real want, the fork is
  Calibre-Web-Automated or Kavita as a second stack — better management,
  Kindle/Kobo send, KOReader sync, at the cost of a second login. Deferred, not
  rejected.
- **CrowdSec on `books-access.log`.** Same unresolved dependency as Immich: the
  Caddy bouncer needs an `xcaddy` build, and the image is pinned to
  `caddy-cloudflare` for the DNS module. If both hostnames want protection, that
  is the argument for finally owning the Dockerfile.
- **Whether Shelfarr survives.** Re-evaluate in six months. If it stalls,
  Listenarr will likely have matured, and the library is unaffected either way —
  which is the whole point of keeping the state in Audiobookshelf.
- **Backups.** `/srv/media/audiobooks` is re-acquirable and large;
  `/srv/audiobookshelf/config` is small and holds every listening position in the
  house. Only one of those needs to be in the backup set.
