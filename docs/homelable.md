# Homelable

A visual canvas for the house's network. You draw the map — routers, switches,
servers, VMs, containers, IoT, Zigbee and Z-Wave meshes — and it keeps the
nodes coloured by whether they are actually up. A scanner fills in the first
draft for you.

`https://lab.brent-miles.com` — LAN only, permanently.

Two containers in one stack:

| Container | Network | Publishes | Job |
|---|---|---|---|
| `homelable-backend` | `homelable` | nothing | FastAPI + SQLite, scanning, status checks |
| `homelable` | `homelable`, `proxy` | nothing | nginx: serves the SPA, proxies `/api` to the backend |

Upstream also ships an `mcp` service on port 8001 that exposes the topology to
AI clients. It is not deployed here — see [The MCP service](#the-mcp-service).

---

## Why this rather than the HACS integration

Homelable ships two independent implementations of the same idea, and this is
the thing to understand before installing either. There is the Docker stack
above, and there is a Home Assistant custom integration
([Pouzor/homelable-hacs](https://github.com/Pouzor/homelable-hacs)) that
reimplements the panel inside HA, using HA's own auth and HA's own storage.

**They do not share data.** Not a sync problem, not an eventual-consistency
problem — two separate databases with two separate maps, and drawing the house
twice is exactly the kind of thing that gets done once and then abandoned.

The container was picked because the integration is the smaller of the two:
it scans in pure Python with no nmap, so it discovers hosts but not service
versions, and it does not have the rack canvas, the floor plans, OIDC, or the
Proxmox and MQTT importers. The one thing it has that the container does not is
free authentication, and Caddy plus a bcrypt hash covers that here.

The other reason: this repo already has a rule that
[Home Assistant partially escapes git](decisions.md#home-assistant-partially-escapes-git),
and HACS integrations live in `.storage` and `custom_components` — outside the
repo, invisible to `deploy.sh`, updated by clicking a button in a web UI. That
is the failure mode
[the whole repo is built to avoid](decisions.md#git-is-the-source-of-truth-with-no-ui-allowed-to-compete).
A pinned container image is the version-controlled option.

If the integration is ever wanted anyway, it is additive — install it in HACS
and treat it as a second, throwaway map. It does not conflict with this stack.

---

## First deploy

Ordinary. One phase, unlike Beszel.

### 1. Secrets into Infisical

Under `prod`, path `/homelable`:

```
SECRET_KEY           openssl rand -hex 32
AUTH_USERNAME        brent
AUTH_PASSWORD_HASH   see below
DOMAIN               brent-miles.com
```

`AUTH_PASSWORD_HASH` is a bcrypt hash, not a password. Generate it from the
image so you are using the same bcrypt the backend will verify with:

```bash
docker run --rm ghcr.io/pouzor/homelable-backend:3.2.0 \
  python -c 'import bcrypt; print(bcrypt.hashpw(b"yourpassword", bcrypt.gensalt()).decode())'
```

Paste the output into Infisical **verbatim**. Upstream's install guide says to
wrap it in single quotes, and also says to escape every `$` as `$$`. Both of
those are about writing a hash into a `.env` or into a compose file's
`environment:` block. Neither applies here: the value goes into Infisical, is
injected as an environment variable, and compose substitutes `${...}` once
without re-scanning what it substituted. Quote it or escape it and you will
have locked yourself out of a service whose lockout looks exactly like a typo'd
password.

Confirm it arrived intact after the first deploy, because this is the one
mistake here with no self-service recovery — there is no change-password
endpoint, only this hash:

```bash
docker exec homelable-backend printenv AUTH_PASSWORD_HASH
```

Single `$` separators, 60 characters, identical to what Infisical holds. Note
that `docker compose config` will show it as `$$2b$$12$$...` and that is *not*
a bug — `config` escapes every `$` so its output can be fed back in as a valid
compose file. `printenv` inside the container is the honest answer.

The image will start perfectly happily with none of this, on `admin`/`admin`.
That is why all four keys are in `deploy.sh`'s `required_vars` table even
though only two are secrets — the failure mode is not a container that won't
boot, it is a map of your network behind a default credential.

### 2. The data directory

```bash
sudo mkdir -p /srv/homelable/data
```

Docker would create it anyway; doing it by hand keeps `/srv` looking like the
[storage layout](storage-expansion.md#layout) rather than like whatever the
daemon happened to do.

### 3. Deploy

```bash
./scripts/deploy.sh homelable
```

### 4. The hostname

Add the Caddy block — it is already in `stacks/caddy/Caddyfile` in this repo —
and make sure Caddy is actually running the version you think it is:

```bash
docker exec caddy grep -c homelable /etc/caddy/Caddyfile   # 0 after a git pull?
./scripts/deploy.sh caddy -- --force-recreate
```

That is not paranoia, it is
[the single-file bind mount problem](decisions.md#single-file-bind-mounts-need-a-recreate-not-a-reload).
`caddy reload` will report success while serving the old file.

No DNS record and no certificate work. The wildcard covers `lab`.

---

## What the scanner misses

Read this before concluding the first scan is broken.

The backend is on a bridge network, so its view of the LAN goes through the
host's NAT. Ping sweeps, nmap and reverse DNS all work fine through that. The
ARP cache does not. The scanner reads `/proc/net/arp`, and inside a bridged
container that file describes the *container's* network — the docker gateway
and nothing else.

Two things are lost:

- **MAC addresses, and vendor identification with them.** Every discovered node
  comes back with `mac=n/a`. If you were hoping to tell the Ecobee from the
  Sonos by OUI, you can't.
- **Devices that answer ARP but drop ICMP.** Printers, some IoT, anything with
  a defensive firmware default. They simply do not appear.

Everything else works: hosts that answer ping are found, nmap identifies open
ports and service versions on them (as root with `NET_RAW`, so `-sS` rather
than the slower `-sT`), and the status checker keeps them coloured.

**Why `network_mode: host` is not the fix.** It would work — the host's real
ARP table, every MAC, every silent device. It would also put the backend's
uvicorn listener on 0.0.0.0:8000 across every interface on `forge`. This repo
has exactly one host-networked container, Beszel's agent, and
[the entire reason it is acceptable](decisions.md#beszels-agent-is-on-the-host-network)
is that it binds a unix socket and publishes no TCP port at all. The Homelable
backend speaks only TCP; there is no equivalent trick, and "an authenticated
API on the LAN" is a materially different claim from "no port at all".

**The actual fix, if MACs start to matter,** is a macvlan network. The
container gets its own address on 10.0.0.0/24 and a real ARP table, without
putting a listener on the host's interfaces. It costs a reserved IP outside the
Orbi's DHCP pool and the usual macvlan annoyance that the host cannot talk to
the container directly — which matters here, because Caddy is on the host.
Realistically that means the frontend stays where it is and only the backend
moves, which is a second network on the backend and a real evening's work. Not
done, and not needed until someone actually wants vendor names.

---

## Updating

Both images are built and published together and are not meant to be mixed.
Bump one variable:

```bash
# check the changelog first — https://github.com/Pouzor/homelable/releases
$EDITOR stacks/homelable/compose.yml   # HOMELABLE_VERSION default
./scripts/deploy.sh homelable -- --pull always
```

Pinned rather than `latest` for the reason everything here is pinned: a
`docker compose pull` should be a decision, not a side effect of restarting the
box. Currently on **3.2.0** (released 2026-08-10).

The SQLite database and any uploaded floor plans live in
`/srv/homelable/data` and survive an image change. They are not backed up —
same gap as [Home Assistant and Beszel](decisions.md#still-open), lower stakes,
because the scanner can redraw most of it and a hand-drawn rack layout is an
evening rather than a photo library.

---

## The MCP service

Upstream's compose has a third service, `ghcr.io/pouzor/homelable-mcp`, which
publishes port 8001 and lets an AI client query the topology over MCP. It is
left out.

Adding it later is small and deliberate rather than automatic:

1. Two keys into Infisical under `/homelable` — `MCP_API_KEY` (client → MCP)
   and `MCP_SERVICE_KEY` (MCP → backend), both `openssl rand -hex 32`.
2. Add them to `required_vars()` in `deploy.sh`.
3. The upstream service block, on the `homelable` network only, with
   `BACKEND_URL: http://backend:8000`.

Do not publish 8001 to the LAN when you do. Give it a hostname in the LAN-only
Caddy block like everything else, or it becomes the one thing in this repo that
publishes a port for convenience.

---

## Troubleshooting

**UI loads, then every API call 502s.** The frontend's nginx has
`proxy_pass http://backend:8000` compiled into the image — the name is not
configurable. Something removed the `backend` network alias from
`homelable-backend`. Put it back.

**nginx exited at startup and is restart-looping.** Same cause, earlier: nginx
resolves `backend` once when it starts and gives up if the name does not exist
yet. The `depends_on: condition: service_healthy` is what prevents this; if it
was removed, this is the symptom.

**"400: Bad Request" or a CORS error in the console.** `CORS_ORIGINS` is built
from `DOMAIN` as `https://lab.<domain>`. If `DOMAIN` is missing from
`/homelable` in Infisical, `deploy.sh` catches it — if it is *wrong*, nothing
does.

**Login fails with the password you are certain is right.** The hash was
mangled on its way in. Check Infisical holds it with no surrounding quotes and
no `$$`:

```bash
infisical secrets --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/homelable
```

**Scan finds nothing at all.** `SCANNER_RANGES` defaults to `["10.0.0.0/24"]`,
which is an assumption about the Orbi — the same assumption the
[Caddyfile's LAN guard](../stacks/caddy/Caddyfile) makes. If the house is on
192.168.x, both are wrong and both need correcting.

**Scan finds hosts but no MACs.** Working as designed. See
[What the scanner misses](#what-the-scanner-misses).
