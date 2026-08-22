# Audiobookshelf

Reference for `stacks/audiobookshelf`. The ordered set of things to *do* is
[audiobooks-punchlist.md](audiobooks-punchlist.md) — this is the why, and the
handful of things that will bite.

The ecosystem question — where books come from, which iPhone client, whether the
automation is worth building at all — is [audiobooks.md](audiobooks.md).

One container, no secrets, no database beyond a SQLite file. The simplest stack
in the repo. The only interesting parts are where it touches things that already
exist: Caddy, Komodo, and the filesystem the download client will later share.

---

## What it is

Library, streaming, per-user playback position, chapter navigation, Audible
metadata matching, and an API the iPhone clients speak. Multi-user with
independent progress, which is the reason your wife gets her own account rather
than sharing one.

Everything it holds is plain files in a plain folder tree. If Audiobookshelf
disappeared tomorrow the library would still be a library — that property is
what makes it safe to build the rest of the ecosystem on top of.

---

## The library lives at `/srv/media/audiobooks`, not under `/srv/audiobookshelf`

This looks like a naming preference and is not.

The download client will eventually need to hardlink a completed file into the
library rather than copy it. A hardlink cannot cross a filesystem **or a
bind-mount boundary**, and two separate bind mounts of the same filesystem are
two boundaries. So downloads and library have to sit under one directory that
gets mounted into every container as one unit, at the same path inside as out.

Getting this wrong is silent: imports still succeed, they just become full
byte-for-byte copies forever. Fixing it later means re-copying the whole
library. `/srv/media` is the answer and it is decided now, while the tree is
empty.

---

## It runs as root, and that is not configurable

Audiobookshelf explicitly does not support `PUID`/`PGID`. Files it writes into
the library are root-owned.

Fine with one container. It stops being fine the moment qBittorrent — running as
uid 3000 in the shelfarr stack — needs to write into the same tree. The
mitigation is a `media` group and a setgid tree, set up once in punchlist step 4
before Audiobookshelf ever runs; new files it creates then land `root:media` 644,
readable by the rest of the stack but not group-writable.

That residue is listed under *Still open* in the punchlist rather than solved,
because the honest fix is a `umask` on this container or a periodic fixup and
neither has been decided.

---

## Why a stack with no secrets still gets the Komodo hooks

This is the one non-obvious thing in `komodo/audiobookshelf.toml`, and it was
nearly missed.

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

The cost is one Infisical path, `/audiobookshelf`, holding `TZ`.
`komodo-env.sh render` calls `infisical export --path=/<stack>` and needs
somewhere to export from. `TZ` is not a secret; it is there so the path is not
empty, and the compose file's `${TZ:-America/Chicago}` means a wrong value
degrades rather than breaks.

Rejected alternative: no `pre_deploy`, and a `post_deploy` of
`/usr/bin/rm -f .../.env`. Shorter, but `post_deploy` is gated on
`if res.deployed`, so a *failed* deploy leaves the empty file behind and blocks
`deploy.sh` at exactly the moment you want to fall back to it.

**This generalises.** Any future stack added to `komodo/` gets the hooks and an
Infisical path whether or not it has secrets.

---

## Exposure

`books.{$DOMAIN}` is the **only** hostname in this ecosystem that is ever
intended to leave the LAN-only block, and it is the first block written in that
zone with the intention of promoting it — every other one there says
"permanently" and means it.

The promotion is its own commit and its own evening; punchlist step 18 has the
checklist and [audiobooks.md](audiobooks.md#exposure) has the reasoning. The
prerequisite that cannot be skipped is claiming the root account first.
Audiobookshelf hands admin to whoever loads the site first, exactly like Immich,
and there is no `IMMICH_ALLOW_SETUP=false` equivalent here to fall back on.

Two things carried over from the Immich work that apply unchanged: overwrite
`X-Forwarded-For` rather than appending it, and do not assume the real client IP
reaches the app — Audiobookshelf is Node/Express underneath, the same
architecture that made `IMMICH_TRUSTED_PROXIES` necessary, and it does not
inherit Immich's fix.

---

## The iOS problem

**There is no official Audiobookshelf app on the App Store.** The official iOS
build is TestFlight-only, TestFlight betas cap at 10,000 testers, and that beta
has repeatedly been full. Android gets a real Play Store listing; iOS does not.

In an all-iPhone house this is the single most important fact about the project.
Use **Plappa** (free, CarPlay) or **ShelfPlayer** ($5.99 once) — both are better
than the official app in most people's telling. Punchlist step 7 puts this
before any of the automation work on purpose: it is the cheapest possible way
for the whole idea to fail.

---

## Sizing

Not a concern, and worth writing down so it stops being a question. A 64kbps
mono m4b is about 30 MB/hour, so a ten-hour book is ~300 MB and a chunky
128kbps release is maybe double. **500 books lands between 150 and 300 GB** — a
rounding error next to Frigate's retention on a volume with 885G free.

Single-file `.m4b` with embedded chapters is the format to normalise on. A
folder of 200 numbered mp3s works, but chapter navigation is worse and the
metadata is usually wrong.
