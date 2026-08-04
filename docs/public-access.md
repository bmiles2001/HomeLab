# Public access

Written 2026-07-29, alongside the Caddyfile split. Describes how
`photos.brent-miles.com` becomes reachable from the internet, and — more
importantly — how everything else stays unreachable.

The decision itself, and the alternatives that were rejected, live in
[decisions.md](decisions.md#public-exposure-chosen-over-the-alternatives).
This is the mechanism.

---

## The exposure model, in one table

| Hostname               | Resolves to | Reachable from      | Guarded by                          |
| ---------------------- | ----------- | ------------------- | ----------------------------------- |
| `photos.brent-miles.com` | WAN IP    | anywhere            | Immich's own auth, then CrowdSec    |
| `secrets.brent-miles.com` | 10.0.0.4 | LAN only            | Caddy `@notlocal`, then Infisical   |
| `cameras.brent-miles.com` | 10.0.0.4 | LAN only            | Caddy `@notlocal`, then Frigate auth |
| anything else `*.`     | 10.0.0.4    | LAN only            | Caddy `@notlocal`, then nothing     |

One public hostname. Everything else falls through the wildcard to a block
whose first action is to drop non-LAN traffic.

**The wildcard A record must not move.** It stays at `10.0.0.4`. Pointing it at
the WAN address would make every internal name resolve publicly and route
through the router, which is both slower and the exact failure the split was
built to prevent.

---

## What changed in the Caddyfile

It used to be one `*.{env.DOMAIN}` block with a `handle` per app. That shape
can't express "public" and "LAN-only" at the same time: a guard at the top of
the block applies to everything in it, so uncommenting `@notlocal` would have
locked out the internet along with the attackers.

Now there are two site blocks. `photos.<domain>` is exact; the rest is the
wildcard. Caddy sorts site blocks by **specificity, not file position**, so the
exact hostname always wins and the wildcard never sees a request for it. The
LAN guard can therefore be unconditional.

Two details in there that are easy to get wrong:

**The guard is a `handle`, not a bare `abort`.** `handle` blocks are mutually
exclusive and run in the order written, so placing it first is a guarantee. A
top-level `abort @notlocal` is positioned by Caddy's directive-ordering rules
instead, which is a subtle dependency for the one line whose entire job is to
not be bypassed.

**`X-Forwarded-For` is overwritten, not appended.** Caddy's default is to
append the connecting address to whatever header arrived. That's correct
behaviour for a proxy behind another proxy, and wrong for an edge — a public
attacker can prepend anything they like. Replacing it outright means Immich
sees exactly one address and it's the one that opened the connection.

That's true *only while Caddy is the edge*. When Cloudflare's proxy goes in
front later, this line starts discarding the real client IP and must change at
the same time.

---

## Rate limiting, and why it doesn't work by default

Immich is Express underneath. Express's `trust proxy` is off unless you set it,
so `req.ip` is the socket that connected — always `immich_server`'s view of
Caddy, on the Docker network, identical for every request in the world.

The consequence isn't subtle. Immich's login rate limiter buckets by that
address. One counter for the entire internet means either an attacker trips it
and locks out the whole family, or the limit is loose enough to avoid that and
therefore isn't limiting anyone. Session records and audit logs show `172.x`
for every user as a bonus.

`IMMICH_TRUSTED_PROXIES` fixes it. It's set in `stacks/immich/compose.yml` and
defaults to `172.18.0.0/16`, which is the `proxy` network's actual subnet on
forge:

```bash
docker network inspect proxy -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
# -> 172.18.0.0/16
```

A CIDR rather than an address, because container IPs change on restart.

### The subnet is now pinned, and this is why

Docker allocates network subnets from its address pool in creation order —
`172.17.0.0/16` to the default bridge, then `172.18`, `172.19` and so on. So
`proxy` got `172.18.0.0/16` because it happened to be created first. A rebuild
that created networks in a different order would give it a different range,
`IMMICH_TRUSTED_PROXIES` would no longer match, and **nothing would say so**.
No error, no warning — the rate limiter would just quietly go back to seeing
one address for the entire internet.

`bootstrap.sh` therefore creates it with `--subnet 172.18.0.0/16` explicitly,
and warns if an existing `proxy` network doesn't match. The two values have to
agree, so they're both written down rather than one being inferred.

Setting `IMMICH_TRUSTED_PROXIES` in Infisical is optional now that the compose
default is correct — but if you do set it there, it overrides the default, and
a stale value in Infisical will silently win over a corrected one in git.

**Verify it, don't assume it.** This setting has silently done nothing in some
releases ([immich-app/immich#14886](https://github.com/immich-app/immich/issues/14886)).
Fail a login deliberately from a phone on cellular, then:

```bash
docker logs immich_server 2>&1 | grep -i "failed login" | tail -5
```

The address should be your carrier's. If it's `172.x`, the variable isn't
taking effect and the rate limiter is still useless — worth knowing before you
rely on it rather than after.

Frigate has the identical problem and the identical fix (`auth.trusted_proxies`
plus `failed_login_rate_limit` in its config). It isn't set, because Frigate
isn't public and its login endpoint only ever sees LAN traffic. If that ever
changes, it changes first.

---

## DNS

Two records, and the difference between them is the whole design.

| Type | Name     | Content    | Proxy  | Managed by                    |
| ---- | -------- | ---------- | ------ | ----------------------------- |
| A    | `*`      | `10.0.0.4` | grey   | you, by hand, once, forever   |
| A    | `photos` | WAN IP     | grey   | `stacks/ddns`, every 5 min    |

A more specific record beats a wildcard in DNS, so `photos` overrides `*`
without the wildcard needing to know.

Both stay grey-clouded for now. Orange cloud is a later phase and brings its
own problems — Cloudflare's terms discourage proxying bulk media, and their
proxy would break the `X-Forwarded-For` handling above.

### The hairpin consequence

Because `photos` resolves to the WAN address for *everyone*, including a phone
sitting on the sofa, all Immich traffic inside the house goes out to the
router's WAN interface and back in. This is NAT loopback, and it is a
deliberate accepted cost — the alternative was a second internal-only hostname,
which was considered and declined.

Two things to know about it:

**It might not work at all.** Not every consumer router does hairpin NAT, and
the Orbi's is reportedly inconsistent. If `photos.brent-miles.com` breaks on
the LAN after the DNS change, that's what happened. Test it the same day you
change the record, not a week later when three phones have quietly stopped
backing up.

**It caps throughput.** Hairpinned traffic goes through the router's CPU rather
than the switch fabric. Fine for browsing; noticeable when three iPhones are
pushing 4K video into a fresh library.

The escape hatch, if either bites, is one commit: add
`photos-lan.brent-miles.com` (already covered by the wildcard record and the
wildcard cert) as a second site block in the LAN-only zone, and set it as the
local URL in the Immich app's automatic URL switching. Not built now, but
nothing here forecloses it.

A smaller note: if the Orbi source-NATs hairpinned traffic, every LAN client
will appear to Immich as `10.0.0.1`. Harmless — the rate limiter that matters
is protecting against the internet — but it'll look odd in the logs.

---

## The DDNS updater

`stacks/ddns` runs [favonia/cloudflare-ddns](https://github.com/favonia/cloudflare-ddns),
which detects the public IP and writes it to Cloudflare. It manages the
`photos` record and nothing else.

The router can't do this job: the RBR750's built-in dynamic DNS only speaks
NETGEAR's own service and No-IP.

### Setup

Create a **separate** Cloudflare token — not the one Caddy uses. Same
permissions, different token, so revoking one doesn't take TLS renewal down
with it. Use the **Edit zone DNS** template at
<https://dash.cloudflare.com/profile/api-tokens>, scoped to the one zone; it
includes the `Zone > Read` permission the updater needs to find the zone from
the hostname.

```bash
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/ddns \
  CF_DDNS_TOKEN=... DOMAIN=brent-miles.com TZ=America/Chicago

./scripts/deploy.sh ddns
docker logs cloudflare_ddns
```

Read that log rather than trusting the deploy. The updater prints its resolved
configuration at startup, and an environment variable it doesn't recognise is
ignored quietly rather than refused.

Then confirm the record actually moved:

```bash
dig +short photos.brent-miles.com @1.1.1.1
curl -s https://api.ipify.org; echo
```

Those two must match.

### It is now a dependency

If this container stops, nothing breaks immediately — the record stays as it
was. It breaks the next time the ISP hands out a different address, at which
point `photos.brent-miles.com` points at a stranger's connection and remote
access fails in a way that looks like a server problem. Worth a glance
whenever you're checking the mirror timer.

---

## Cutover order

Each step is safe to stop at. Nothing is exposed until the last one.

**1. Confirm there's no CGNAT.** Already checked — the Orbi's WAN address
matches `curl ifconfig.me`. Re-check if the ISP ever changes plan or
equipment; a WAN address in `100.64.0.0/10` means port forwarding cannot work
at all and the whole approach needs rethinking.

**2. Deploy the Caddyfile split.** Nothing is exposed by this — 443 is still
closed at the router. This is the point of doing it first: the config is
correct and tested before it's load-bearing.

```bash
ssh forge
cd ~/home-containers && git pull
./scripts/deploy.sh caddy
docker exec caddy caddy validate --config /etc/caddy/Caddyfile
```

Then from a machine on the LAN, confirm all three still work:
`photos`, `secrets`, `cameras`.

**3. Set `IMMICH_ALLOW_SETUP=false`.** Non-negotiable. Immich hands admin to
whoever loads the site first, and "first" stops meaning "you" the moment the
port opens. This is step 2 of [immich-punchlist.md](immich-punchlist.md); if
it's already done, confirm rather than assume:

```bash
docker exec immich_server printenv IMMICH_ALLOW_SETUP   # must print false
```

**4. Set `IMMICH_TRUSTED_PROXIES`** and redeploy Immich, as above.

**5. Stand up DDNS** and watch it write the record.

**6. Forward 443 at the router.** TCP *and* UDP — Caddy publishes `443/udp` for
HTTP/3 and it'll silently fall back to HTTP/2 without it. Orbi: Advanced →
Advanced Setup → Port Forwarding, to `10.0.0.4`.

Do **not** forward 80. Certificates are issued over DNS-01, so nothing inbound
needs it, and an open 80 is one more thing answering.

**7. Test from outside**, on cellular with wifi off:

```
https://photos.brent-miles.com     -> Immich login
https://cameras.brent-miles.com    -> connection closed, no response
https://secrets.brent-miles.com    -> connection closed, no response
https://nonsense.brent-miles.com   -> connection closed, no response
```

The last three matter more than the first. A working Immich proves the forward;
three closed connections prove the guard. If any of them returns a login page,
a 403, or anything at all, stop and fix it before going to bed.

**8. Test from inside.** Load `photos.brent-miles.com` on the LAN — this is the
hairpin check. Then upload a photo from a phone on home wifi and watch it land.

**9. Watch the log for a day.**

```bash
docker exec caddy tail -f /var/log/caddy/photos-access.log
```

Scanners will find it within hours. That's expected and not alarming; it's also
the raw material CrowdSec needs, and worth looking at once before it's
automated away.

---

## What this doesn't cover yet

**CrowdSec.** The whole point of the separate `photos-access.log`. Detection is
straightforward — a CrowdSec container reading that file with the
`crowdsecurity/caddy` collection. Remediation is where it gets awkward: the
Caddy bouncer is a Caddy module, so it needs an `xcaddy` build, and the image
is currently pinned to `ghcr.io/caddybuilds/caddy-cloudflare` precisely because
Caddy needs the Cloudflare DNS module compiled in. Owning that Dockerfile means
losing the bump-the-tag upgrade path, which deserves its own entry in
`decisions.md` rather than happening by accident. Geo-filtering has the same
shape and the same cost, so if both are wanted, build the image once.

Also worth knowing: the stock Caddy collection catches scanners and generic
probing. Nothing in it understands Immich. Failed logins are `401`s on
`/api/auth/login`, and a custom scenario on those is the part that actually
protects the library.

**Cloudflare's orange cloud**, and Cloudflare Access in front of anything.
Deferred until the direct path is working. Note that Access assumes a browser
that can complete an interactive login, which the Immich iOS app cannot — so it
was never going to be the answer for `photos` regardless.

**Tailscale**, for administration. Still the right answer for everything that
should never be public, and complementary to this rather than an alternative.
