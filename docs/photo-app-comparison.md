# Photo app comparison

Evaluated 2026-07-28, against the requirements as stated:

1. Native iOS app, background auto-backup of the camera roll — for three people
2. Wi-Fi-only sync as an option, but not forced
3. Reachable at `photos.brent-miles.com` from outside the house
4. Shareable album for coworkers who have no account
5. Separate libraries per person, with a shared space we opt into
6. Sleek UI is nice; **the mobile side is what matters**

Requirement 1 is the one that eliminates most of the field.

---

## The short version

**Immich.** It's the only option that satisfies every hard requirement without a
third-party app bolted on. Latest stable is v3.1.0 (2026-07-29), on top of the
v3.0.0 release from 2026-07-01. The project left the "expect breaking changes"
era behind with its first stable release in October 2025.

---

## Scorecard

| | Immich | Ente (self-hosted) | PhotoPrism | Nextcloud Memories |
|---|---|---|---|---|
| Native iOS app | Yes | Yes | **No — PWA only** | Yes (Nextcloud app) |
| Background camera-roll backup | Yes | Yes | Needs PhotoSync (paid, WebDAV) | Yes |
| Wi-Fi-only toggle | Yes, with caveats | Yes | n/a | Yes |
| Per-user libraries | Yes | Yes | **Plus tier only** | Yes |
| Shared albums between users | Yes | Yes | Plus tier | Yes |
| Public link for non-users | Yes — password + expiry | Yes | Yes | Yes |
| Full-library share with spouse | Yes — Partner Sharing | No | No | No |
| Face recognition / semantic search | Yes, server-side, free | On-device only | Plus tier for some | Basic |
| UI quality | Best in class | Very good | Good | Dated |
| RAM floor | ~8 GB | ~130–500 MB | ~2 GB | ~4 GB |

---

## Why not the others

### PhotoPrism — eliminated on requirement 1

Still has no native mobile app in 2026; the mobile story is a PWA you add to
your home screen. iOS will not let a PWA upload in the background, so the
standard workaround is buying PhotoSync and pointing it at PhotoPrism over
WebDAV. That's a paid third-party app in the critical path of "my daughter's
photos get backed up," for three phones.

Multi-user is also a Plus (paid) feature. Two strikes against the two things
that matter most here.

### Ente — the real runner-up, rejected on fit

End-to-end encrypted, genuinely good iOS app, by far the lightest server. If
E2EE were a hard requirement this would be the answer.

It isn't the answer here because:

- Self-hosting needs S3-compatible object storage (MinIO) alongside the server,
  so it's *more* infrastructure than Immich, not less.
- Pointing the App Store iOS build at a custom server is a developer-menu flow,
  not a first-class setup path. Three family phones is three times that friction.
- E2EE means the server can't index anything. Face recognition and search run
  on-device, which is heavier on the phones and weaker on the web UI — you have
  a 2 TB NVMe and a real CPU sitting idle, and E2EE prevents you using them.
- Sharing a whole library with a partner isn't a feature; you'd share albums.

### Nextcloud Memories — works, but you're installing Nextcloud

If Nextcloud were already running for files this would be a strong contender.
It isn't — files are in OneDrive — so this means standing up a large PHP
application to get a photo gallery. The UI is noticeably behind, and the iOS
experience is the general-purpose Nextcloud app rather than a photo app.

### LibrePhotos, Photoview, Piwigo

No maintained native iOS backup app between them. Not viable for requirement 1.

---

## Immich against each requirement

**1. Native app, three people.** Native iOS app with background backup. Each
person gets their own account. On iOS you must turn on Settings → General →
Background App Refresh for Immich or background backup silently never runs —
this is the single most common "it isn't working" cause.

**2. Wi-Fi-only.** The setting exists per-user in the app and can be left off.
Be aware of a known rough edge: there are open reports of background uploads
using cellular despite "only on Wi-Fi" being set. If any of the three phones is
on a metered plan, set a data alert rather than trusting the toggle alone.

**3. External access.** Nothing app-specific — Caddy terminates TLS at
`photos.brent-miles.com` and reverse-proxies to the `immich-server` container.
Immich has no built-in brute-force protection, so exposure hardening is our job,
not Immich's. See the runbook.

**4. Coworker sharing.** Public shared links, per-album or per-selection, with
optional password, optional expiry, optional download permission, and custom
slugs since v2.6. No account needed on the other end.

**5. Separate libraries, shared space.** Each user's uploads live under their own
user ID inside `UPLOAD_LOCATION`, isolated by default. The shared space is a
**shared album**, with per-person editor or viewer permissions — everyone adds to
the same album while their originals stay in their own library. There's also
**Partner Sharing**, which shares your entire library with one other user
read-only; that's the natural fit for you and your wife.

One limitation worth knowing up front: an **external library** (a folder on disk
Immich reads in place, rather than owns) can only belong to a single user. So
"one shared folder on the filesystem that all three of us write to" is not a
thing Immich models. The shared album is the supported answer, and it's the
better one — but if you were picturing a literal shared directory, adjust now
rather than after importing 40,000 photos.

---

## Costs accepted

- **No E2EE.** Photos sit decrypted on the NVMe. Acceptable for a box you own in
  a house you own; not acceptable if the threat model were a hostile host.
- **8 GB RAM floor**, mostly for machine learning. If `forge` has 16 GB you're
  fine; if it has 8 GB total, plan to run the ML container with a smaller CLIP
  model or offload it.
- **Postgres with pgvecto.rs** is a real dependency with real backup obligations.
  The photo files are the irreplaceable part; the database is rebuildable but
  expensive to rebuild (all faces and embeddings re-run).
- **Release cadence is fast.** Pin an explicit version tag in compose, never
  `:latest`, and read release notes before bumping.

## Sources

- [Immich vs PhotoPrism vs Ente 2026 (Contabo)](https://contabo.com/blog/immich-vs-photoprism-vs-ente/)
- [Self-Hosted Photo Library 2026 (TechFuel)](https://techfuelhq.com/tutorials/self-hosted-photo-library-immich-photoprism-ente-2026/)
- [Best Self-Hosted Photo Manager 2026 (HomeNode)](https://homenode.tech/best-self-hosted-photo-manager-2026/)
- [Immich — Sharing](https://docs.immich.app/features/sharing/)
- [Immich — Partner Sharing](https://docs.immich.app/features/partner-sharing/)
- [Immich — External Libraries](https://docs.immich.app/features/libraries/)
- [Immich — Custom Locations](https://docs.immich.app/guides/custom-locations/)
- [Immich 2.6 release notes](https://alternativeto.net/news/2026/3/immich-2-6-improves-map-side-panel-asset-viewer-shared-link-slugs-and-presets-and-more)
- [PhotoPrism — Mobile App (PWA)](https://docs.photoprism.app/user-guide/pwa/)
- [PhotoPrism — Partners (PhotoSync)](https://www.photoprism.app/partners/)
- [Ente self-hosting announcement](https://linuxiac.com/ente-cloud-based-photos-app-unveils-self-hosting/)
- [Immich wifi-only background backup issue #12628](https://github.com/immich-app/immich/issues/12628)
- [Immich iOS background backup discussion #1694](https://github.com/immich-app/immich/discussions/1694)
