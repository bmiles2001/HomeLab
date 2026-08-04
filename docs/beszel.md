# Beszel

Monitoring for `forge`. CPU, memory, load, temperatures, disk usage and I/O,
network throughput, per-container stats, GPU utilisation, and history for all of
it, with alerts when something crosses a line.

`https://status.brent-miles.com` — LAN only, permanently.

Two containers in one stack:

| Container | Network | Publishes | Job |
|---|---|---|---|
| `beszel` | `proxy` | nothing | web UI, database, alerting |
| `beszel-agent` | **host** | nothing | reads the metrics, answers on a unix socket |

The split is Beszel's design, not a complication of this repo's: one hub can
watch many machines, each running an agent. Today there is exactly one agent and
it watches the box the hub is on.

---

## Why this is worth having here

Three things this repo already knows are unwatched:

- **The NVMe.** Everything is on one disk — OS, containers, the photo library,
  and the directory called "backups". `docs/storage-expansion.md` says the root
  volume hit 92% before it was extended, and nothing would have said so.
- **The 3080.** Frigate and Immich now share one card
  (`decisions.md#amendment-frigate-moves-to-the-3080`), and the contention
  question there — "watch for this during a large Immich import" — is currently
  answered by remembering to run `nvidia-smi` at the right moment.
- **Containers that die quietly.** `restart: unless-stopped` means a container
  that crash-loops looks identical to one that is fine, until you look.

Beszel is a 30MB Go binary and a SQLite file. It is not Prometheus and Grafana,
and the reason to pick it is that it is not: there is no scrape config, no
exporter per service, no dashboard JSON to maintain. The tradeoff is that you
get the metrics it decided to collect and no others.

---

## First deploy

**Two phases, and the second is not optional.** The agent authenticates to the
hub with a public key and a token that the hub itself generates. They cannot be
in Infisical before the hub has run once, so `deploy.sh` — which fails closed on
a missing secret, correctly — cannot be what starts this stack the first time.

### Phase 1 — the hub, alone

```bash
cd ~/home-containers
git pull
./bootstrap.sh                 # creates /srv/beszel/{data,agent,socket} and /srv/.beszel

cd stacks/beszel
docker compose up -d beszel    # the hub only. It has no secrets of its own.
docker compose logs -f beszel  # expect "Server started"
```

Naming the service is what keeps the agent down: bring the whole stack up here
and the agent starts with an empty `KEY`, fails to authenticate, and restart-
loops. Harmless, but it makes phase 2 read like debugging.

This is the second and last place in this repo where a stack is started without
`deploy.sh`. The other is Infisical, for the same shape of reason — it cannot
fetch its own secrets either.

### Phase 2 — create the account and mint the credentials

Caddy does not know about `status.` yet, so reach the hub directly from your PC
over the SSH tunnel, or add the Caddy block first (below) and come back. Then:

1. Open the hub and **create the admin account**. First visitor wins, same as
   Infisical — do it now, not tomorrow.
2. **Add System**, top right. Fill in:
   - **Name**: `forge`
   - **Host / IP**: `/beszel_socket/beszel.sock` — the literal path, not an
     address. This is the field people get wrong; `localhost` cannot work,
     because the hub and the agent are not on the same network.
   - **Port**: leave it.
3. Copy the **public key** and the **token** shown in the dialog. Leave the
   dialog open.
4. Put both in Infisical under `/beszel`, along with a copy of `DOMAIN`:

   ```
   KEY       ssh-ed25519 AAAA...
   TOKEN     <token>
   DOMAIN    brent-miles.com
   ```

   `DOMAIN` is duplicated from `/caddy` because `deploy.sh` reads one Infisical
   path per stack. `/ddns` does the same thing.

   `KEY` and `TOKEN` keep Beszel's own names rather than becoming `BESZEL_*`.
   `bootstrap.sh` check 6d compares the names in `deploy.sh`'s table against
   the names in the running container's environment; anything it cannot find,
   it skips. Renaming them would not make the check fail — it would make the
   check quietly stop applying to this stack.

### Phase 3 — the real deploy

```bash
cd ~/home-containers
./scripts/deploy.sh beszel
```

Both containers come up, the agent binds the socket, and clicking **Add System**
in the still-open dialog turns the row green within a few seconds. Red means
check `docker logs beszel-agent` — nearly always a mistyped key or a socket path
that is not the literal `/beszel_socket/beszel.sock`.

### Phase 4 — the hostname

```bash
./scripts/deploy.sh caddy -- --force-recreate
docker exec caddy grep -c status /etc/caddy/Caddyfile    # 0 means stale
```

Recreate, not reload — `git pull` replaced the Caddyfile's inode and the running
container is still reading the old one. This is the trap in
`decisions.md#single-file-bind-mounts-need-a-recreate-not-a-reload`, and a new
hostname returning a closed connection is exactly its symptom.

---

## The two things that are unusual about this stack

### The agent is on the host network

Rule 2 says only Caddy publishes ports. The agent is on the host network, which
is a bigger deviation than it needs to be and a smaller one than it looks.

It needs host networking because network throughput is read from the host's
interfaces. A bridged agent still reports a number — the traffic across its own
veth pair — which is the worst kind of wrong, because it is plausible.

What it does **not** do is publish a port. Upstream's config sets
`LISTEN=45876`, and combined with host networking that puts the agent's listener
on every interface the box has. This stack sets `LISTEN` to a unix socket path
instead, on a bind mount both containers share. The agent binds no TCP port at
all, `docker ps` shows an empty Ports column, and `bootstrap.sh`'s check 6 needs
no allow-list entry for it — which matters, because an allow-list entry is a
permanent hole and this needed none.

### The docker socket is the real cost

The agent mounts `/var/run/docker.sock`. That is what draws the per-container
CPU and memory charts, and it is the most privileged thing in this stack by a
wide margin.

**The `:ro` on that mount is decoration, not a control.** This is worth being
blunt about because it is the single most common misreading of a compose file.
A read-only bind mount makes the socket *file* unmodifiable — it cannot be
replaced, deleted or chmod'd from inside the container. It does nothing to the
socket as a channel, because `connect()` and `send()` are not filesystem
writes. Every Docker API call still works through it, including
`POST /containers/create`.

So the accurate statement is not "it can read secrets". It is:

> **Anything that can speak to that socket is root on forge.** It can create a
> container with `privileged: true` and `/` bind-mounted, and step straight out
> onto the host.

Reading every secret `deploy.sh` injects — via `inspect`, which prints
environment variables — is merely the quietest thing it could do on the way.

The `:ro` is kept because it costs nothing and matches upstream's config, but
nothing in this repo should be built on the assumption that it constrains
anything.

The fix, when it is worth building, is a socket proxy: a small container that
holds the real socket and re-exposes it over HTTP on the `proxy` network with
everything but `GET /containers/*/stats` returning 403.
[Tecnativa/docker-socket-proxy](https://github.com/Tecnativa/docker-socket-proxy)
is the usual one — HAProxy and a config file, `POST=0` by default. The agent
would then get `DOCKER_HOST=tcp://dockerproxy:2375` and no socket mount at all.

It is not built yet because it moves the root-equivalent mount from the
monitoring agent to a proxy container that must then be trusted instead, and
that only pays off if the proxy is genuinely smaller attack surface than the
agent. It probably is. It is still a decision, and it is listed in
`decisions.md#still-open` rather than assumed.

---

## The second disk

`/srv` is `ubuntu-vg/data` — 984G, a different filesystem from root's 394G. An
agent in a container charts only the filesystems it can see from inside its own
mount namespace, so without help the 984G volume holding the entire photo
library simply would not appear.

The mechanism is `/extra-filesystems`: mount any directory that *lives on* a
filesystem into `/extra-filesystems/<label>` and that filesystem gets its own
chart, labelled `srv`.

`bootstrap.sh` creates `/srv/.beszel` for this, and it stays empty on purpose.
Mounting `/srv` itself would work identically and would also mount the photo
library into the monitoring agent, read-only, for no gain.

Root needs no equivalent entry: the container's own `/` is an overlay backed by
the root filesystem and already reports its size and usage.

If a volume is ever added — an external disk for the backups
`storage-expansion.md` asks for — it needs a marker directory and one more line
here, or it will be the one filesystem nothing is watching.

---

## The GPU

The image is `beszel-agent-nvidia`, not the base agent. The base image runs
perfectly well and shows no GPU at all, with no error — it simply has no
`nvidia-smi`.

The `deploy` block asks for `capabilities: [utility]`, which is the management
libraries and nothing else. Frigate and Immich ask for the full `gpu`
capability because they compute on the card. A monitoring agent that reads
sensors should not be in the same privilege class as the workloads it watches.

`GPU_COLLECTOR=nvml` (commented, in the compose file) is the alternative
collector. Its advantage is that it lets the card drop into its RTD3 low-power
state between samples, which `nvidia-smi` polling can prevent. Not worth
chasing while Frigate keeps the 3080 busy anyway, and it is still experimental
upstream.

Requires the NVIDIA Container Toolkit on the host, which is already there for
Frigate and Immich.

---

## S.M.A.R.T., if you want it

`storage-expansion.md` lists drive health under "Still to do": one NVMe carries
everything, and `Percentage Used` and `Media Errors` are the two numbers worth
knowing before they matter. Beszel parses `smartctl` output and, if any drive
reports failure, alerts on it automatically as long as one notification channel
is configured.

The `-nvidia` image already contains `smartctl`, so enabling it is uncommenting
two blocks at the bottom of the agent service:

```yaml
devices:
  - /dev/nvme0:/dev/nvme0
cap_add:
  - SYS_RAWIO
  - SYS_ADMIN
```

`/dev/nvme0` is the **controller**. `/dev/nvme0n1`, the block device named
everywhere else in this repo, returns nothing useful and no clear error.

It is off by default — but **not** because `SYS_ADMIN` compounds with the
docker socket. It doesn't. The socket is already root-equivalent, so `SYS_ADMIN`
plus a raw NVMe controller grants this container nothing it cannot already
reach. They are alternative routes to the same place, not two locks on one
door.

The reason to leave it off is about the socket proxy above. That work exists to
take this container *out* of the root-equivalent class. `SYS_ADMIN` and
`/dev/nvme0` would keep it there — NVMe admin passthrough can issue Format and
Sanitize, and raw controller access reads any block on the disk regardless of
file permissions. Enabling SMART today costs nothing; enabling it and then
building the proxy would be effort spent for no change in blast radius.

So: turn it on if drive health matters more to you than a mitigation that isn't
built. Just don't turn it on and also believe the proxy fixed something.

---

## Alerts

Configure at least one notification channel before trusting any of this —
without one, Beszel is a dashboard you have to remember to open, which is the
thing it was installed to replace.

Options that fit the house: **ntfy** (self-hostable, iPhone app, no account),
**Pushover** (one-off purchase, most reliable on iOS), or SMTP through Outlook.
Per-system alert rules — CPU, memory, disk, temperature, and *system down* —
are set in the UI, per system, and live in the SQLite database rather than in
this repo. That is the same gap Home Assistant has
(`decisions.md#home-assistant-partially-escapes-git`): back up
`/srv/beszel/data` or accept re-creating the rules by hand.

Start with **system down** and **disk above 85%**. Alerting on CPU on a box that
runs an NVR teaches you to ignore alerts.

---

## Updating

```bash
cd ~/home-containers
$EDITOR stacks/beszel/compose.yml       # bump BESZEL_VERSION's default
git commit -am "beszel: 0.18.7 -> x.y.z" && git push
# on forge:
git pull && ./scripts/deploy.sh beszel
```

Both images share one version variable and should be bumped together. A hub
newer than its agent generally works; the reverse is not promised.

---

## Adding another machine later

The Windows desktops can run the agent as a service (WinGet or Scoop, plus NSSM
to keep it running). That agent talks to the hub over the network rather than a
socket, which means the hub needs to be reachable from the desktop — it already
is, on the LAN, at `status.brent-miles.com`.

Two things to know before starting:

1. Those installs are host state on machines this repo does not manage. Write
   down what was done, in here, or it is lost at the next Windows reinstall.
2. A remote agent listens on a TCP port and is authenticated by key. On the
   house LAN that is fine. It is not something to forward at the router.

---

## Troubleshooting

**System stuck red immediately after Add System.** Almost always the Host / IP
field. It must be `/beszel_socket/beszel.sock`, not `localhost`, not `127.0.0.1`.

**System goes red after a redeploy.** The socket file is recreated when the
agent restarts, and the hub reconnects on its own within a minute. If it does
not, `docker restart beszel`.

**No GPU section on the system page.** Check the image is `beszel-agent-nvidia`
and that the `deploy` block survived — `docker compose config | grep -A5 devices`.
`docker exec beszel-agent nvidia-smi` is the direct test.

**`/srv` missing from the disk charts.** `/srv/.beszel` does not exist on the
host; run `./bootstrap.sh`.

**Hostname returns a closed connection.** Caddy is reading a stale Caddyfile.
`docker exec caddy grep -c status /etc/caddy/Caddyfile` — if that prints 0,
`./scripts/deploy.sh caddy -- --force-recreate`.

**Agent restart-looping with an auth error.** `KEY` or `TOKEN` in
Infisical does not match what the hub issued. Re-copy them from the system's
edit dialog in the UI; the key must include the `ssh-ed25519 ` prefix.
