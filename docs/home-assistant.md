# Home Assistant

Two jobs. It is the **iPhone app for the cameras** — the thing Frigate doesn't
have and the reason this stack exists at all — and it is where house automation
will live.

Reached at `https://home.brent-miles.com`, LAN-only, on the wildcard
certificate.

---

## Why Container and not HA OS

HA ships in two shapes and they are genuinely different products:

| | HA OS | HA Container |
|---|---|---|
| What it is | A whole operating system, in a VM | One container, like everything else here |
| Add-on store | Yes | No |
| Built-in backups | Yes | No |
| Fits this repo | No — a VM outside the compose model | Yes |

HA OS is the better product in isolation. It loses here because a VM sits
outside everything this repo is built on: no `compose.yml`, no `deploy.sh`, no
`git pull && deploy` story. One machine running one deployment model is worth
more than the add-on store.

**What you actually give up:**

- **The Frigate add-on** — irrelevant. The add-on and the container are the
  same software packaged differently, and Frigate already runs as its own stack.
- **The backup UI** — this one is real. See [Backups](#backups) below.
- **Supervisor-managed updates** — replaced by `docker compose pull`.

---

## First run

Order matters. Both Frigate and HA retry a missing broker forever rather than
failing, so getting this wrong produces no error — just a Home Assistant with
no cameras in it.

```bash
./bootstrap.sh                          # creates the iot network, /srv/homeassistant
./scripts/deploy.sh mosquitto
./scripts/deploy.sh frigate             # needs its model - see frigate.md
./scripts/deploy.sh homeassistant
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

First start takes several minutes. Watch `docker logs -f homeassistant` until
it stops moving.

Then, in the browser at `https://home.brent-miles.com`:

**1. Onboarding.** Create your account. This first account is the owner and
can't be demoted later, so make it yours rather than a shared family one.

**2. MQTT.** Settings → Devices & Services → Add Integration → **MQTT**.

| Field | Value |
|---|---|
| Broker | `mosquitto` |
| Port | `1883` |
| Username / Password | the values from Infisical under `/mosquitto` |

Container name, not an IP — both containers are on the `iot` network and
Docker's embedded DNS resolves it. If this fails, the broker is almost
certainly not running yet.

**3. HACS.** The Frigate integration isn't in core HA and has to come through
HACS, which isn't in core HA either. Bootstrap it inside the container:

```bash
docker exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -"
docker restart homeassistant
```

Then Settings → Devices & Services → Add Integration → **HACS**, and follow the
GitHub device-code prompt.

**4. Frigate.** HACS → search "Frigate" → download → restart HA. Then Settings
→ Devices & Services → Add Integration → **Frigate**:

```
URL:  http://frigate:8971
```

`http://`, not `https://` — Frigate's TLS is disabled in `config.yml` precisely
so this works. 8971 is the authenticated port; **do not** point this at 5000,
which is unauthenticated. And do not point it at
`https://security.brent-miles.com` — the integration wants the direct container
address, not the proxy.

You should now have camera, image, sensor, switch and binary_sensor entities
for each camera.

**5. The iPhones.** Install "Home Assistant" from the App Store, point it at
`https://home.brent-miles.com`, log in. Create a separate HA user per family
member rather than sharing yours — notifications are per-device and per-user,
and a shared login makes them impossible to target.

---

## Notifications, and what LAN-only means for them

This is the part people get wrong, so it's worth being precise.

HA's iOS push notifications go out through Home Assistant's own hosted push
gateway. That is **free and does not require Nabu Casa** — the only requirement
is that `forge` has outbound internet, which it does. So:

- **The notification itself arrives anywhere.** On cellular, at work, abroad.
- **The attached snapshot does not.** The phone fetches that image from
  `https://home.brent-miles.com`, which only resolves and only answers on the
  LAN. Away from home you get the text and a broken image.
- **Tapping through to live view doesn't work off-LAN either**, for the same
  reason.

That is the honest state of things until either Tailscale goes in — the
intended answer, already on the list in the README — or HA gets a public
hostname, which it should not.

Frigate's integration deliberately exposes unauthenticated notification
endpoints under `/api/frigate/notifications/<event-id>/` so images can load in
a push notification without a session. Worth knowing that surface exists. It's
behind the same LAN guard as everything else.

### Building the automation

Don't write it by hand. Import
[SgtBatten's Frigate Notifications blueprint](https://github.com/SgtBatten/HA_blueprints),
which is the de-facto standard and handles cooldowns, zone filtering, per-object
rules and silencing — all the things that make the difference between a useful
alert and one the family mutes in a week.

**With recording disabled, notifications carry a still image only.** The
blueprint's clip and GIF options will produce nothing. That's expected — see
[frigate.md](frigate.md#recording-is-off-and-what-that-costs).

---

## What bridge networking costs you

Most HA-in-Docker guides tell you to use `network_mode: host`. This stack
doesn't, because that would publish 8123 straight onto the LAN and bypass Caddy
— breaking the one rule the whole repo is built on.

The cost is real and worth stating: **mDNS and SSDP discovery won't work.**
Chromecasts, Sonos, HomeKit accessories and anything else found by broadcast
will not appear on their own. Devices reachable by IP — Frigate, the cameras,
every cloud integration — are unaffected, and many integrations let you enter
an address by hand.

If something later turns out to be discovery-only, the fix is giving HA a
macvlan interface on the LAN, not host networking. That keeps port 8123 off the
host while putting HA on the broadcast domain.

---

## Backups

HA Container has no backup UI, and this is the sharpest edge of choosing it.

Everything that matters is in `/srv/homeassistant/config`, and most of it is in
`.storage/` as JSON — including every integration's credentials, your users,
and long-lived access tokens. `configuration.yaml` is the small part.

Nothing backs this up yet. It is not in the OneDrive mirror, which is scoped to
the photo library. Until that changes, treat a rebuild as "set HA up again from
this document," which is survivable precisely because the document exists.

The obvious fix is a second rclone target or a nightly tarball into
`/srv/backups`, alongside `infisical-backup.sh`. Stop the container first — HA's
SQLite database does not appreciate being copied mid-write.

---

## Getting rid of the play button

HA's built-in camera cards show a static thumbnail with a play overlay and only
start streaming when clicked. That is deliberate — otherwise every dashboard
load starts a video stream per camera — but it feels clunky on a wall display.

**The one-line fix**, no install required. Works on `picture-entity` and
`picture-glance`:

```yaml
type: picture-entity
entity: camera.bedroom
camera_view: live      # <- default is "auto", which is the thumbnail + play button
show_state: false
show_name: false
```

This streams immediately, but still through HA's `stream` integration, which
means HLS — typically 5–10 seconds behind real time and a second or two to
start. Fine for a glance, poor for "who is at the door right now".

**The proper fix** is the [Advanced Camera Card](https://github.com/dermotduffy/frigate-hass-card)
(formerly the Frigate card), installed through HACS. It is built for this: live
by default, no play button, and it can pull from go2rtc directly instead of
going through HA's HLS pipeline, which takes latency from seconds to
sub-second. It also gets you event browsing and a timeline in the same card.

### The /security dashboard

Create it at **Settings → Dashboards → + Add Dashboard → New dashboard from
scratch**, title `Security`, URL `security`. Then open it, pencil icon →
three-dot menu → **Raw configuration editor**, and paste:

```yaml
views:
  - title: Cameras
    path: cameras
    # panel mode gives the card the whole viewport instead of a column
    type: panel
    cards:
      - type: custom:advanced-camera-card
        cameras:
          - camera_entity: camera.bedroom
            live_provider: go2rtc
          - camera_entity: camera.garage
            live_provider: go2rtc
          - camera_entity: camera.street
            live_provider: go2rtc
        view:
          # This is the setting that removes the play button.
          default: live
        dimensions:
          aspect_ratio_mode: static
          # All three cameras are 2048x1536. Without this the card letterboxes.
          aspect_ratio: '4:3'
```

`live_provider: go2rtc` with a Frigate `camera_entity` needs no URL — the card
reaches go2rtc through the Frigate integration. A `go2rtc.url` is only required
for a go2rtc server that isn't Frigate's own, and would hit mixed-content
blocking behind HTTPS.

Confirm the entity IDs first in **Developer Tools → States**; the Frigate
integration names them after the camera, but a rename would break the above
silently.

Single-camera versus grid is a menu button on the card, not config — the
default is single with a camera carousel.

### Keeping the dashboard in git

The above lives in HA's `.storage`, outside this repo, like everything else HA
owns. It can be pulled back in by declaring the dashboard in
`configuration.yaml` and pointing it at a file in the repo:

```yaml
lovelace:
  mode: storage      # leaves existing UI dashboards alone
  dashboards:
    security:
      mode: yaml
      title: Security
      icon: mdi:cctv
      show_in_sidebar: true
      filename: security.yaml
```

`security.yaml` would then be mounted read-only from this repo alongside
`configuration.yaml`. The cost is that the dashboard becomes read-only in the
UI — every change goes through git. Worth it for a wall display that shouldn't
change; annoying while still iterating on it.

### Which stream to put on a dashboard

Use the **sub** streams for any view showing more than one camera at a time,
and Main only for single-camera views. Three 2048×1536 streams decoding
continuously in a browser tab is what makes dashboards stutter, and continuous
streaming removes the bandwidth saving that made smart streaming the default.

### Why WebRTC is not set up here

WebRTC is the lowest-latency option and the card supports it, but it needs the
browser to reach Frigate on port 8555 directly, plus `webrtc.candidates` in the
go2rtc config. That means publishing a port from the Frigate stack — which
breaks [only Caddy publishes ports](../README.md#the-two-rules).

MSE through go2rtc is close enough for a camera wall and costs nothing
architecturally. If two-way talk ever becomes interesting, that is when this
tradeoff is worth reopening — deliberately, and written down.

## When mosquitto restart-loops

The broker generates its password file at startup from the injected secrets,
which means a failure there kills the container before MQTT ever listens. The
symptom is `Restarting (1)` in `docker ps` and Frigate and Home Assistant both
sitting quiet, because both retry a missing broker forever rather than failing.

```bash
docker logs mosquitto --tail 20
```

| Log says | Cause |
|---|---|
| `Unable to open file /mosquitto/config/passwd for writing. File exists.` | `mosquitto_passwd -c` opens O_EXCL and will not overwrite. The entrypoint deletes the file first for exactly this reason — if you see this, that `rm -f` is missing. |
| `Permission denied` on the same path | Running as the `mosquitto` user rather than root. `user: root` in compose.yml fixes it; the broker still drops privileges itself via `user mosquitto` in mosquitto.conf. |
| `Unable to open pwfile` | The file exists but the broker can't read it after dropping privileges — the `chown` line didn't run. |
| Nothing, container exits 0 | Wrong config path in the `exec` line. |

Note that recreating the container does **not** clear the password file — it
lives in the `mosquitto_config` volume and outlives containers. To start
genuinely clean:

```bash
docker compose -f stacks/mosquitto/compose.yml down -v
./scripts/deploy.sh mosquitto
```

## Rotating the MQTT password

One credential, stored in three places, because `deploy.sh` scopes each stack to
its own Infisical path. All three have to move together:

1. Infisical `/mosquitto` → `MQTT_PASSWORD`
2. Infisical `/frigate` → `FRIGATE_MQTT_PASSWORD`
3. Home Assistant's MQTT integration → reconfigure, by hand in the UI

Then `./scripts/deploy.sh mosquitto && ./scripts/deploy.sh frigate`.

Get it half-done and Frigate logs "Unable to connect to MQTT server" every few
seconds while HA quietly shows nothing. There is no single place that reports
the mismatch.

---

## Upgrades

`HA_VERSION` is `stable` rather than a pinned number, because HA ships a
breaking-change release every month and pinning would mean editing that file
twelve times a year to stand still.

The tradeoff: `docker compose pull` can carry you across a breaking change
without warning. Read the release notes first, and note that **HA does not
support downgrades** — once the database has migrated, going back means
restoring a backup you don't currently have. See above.

## Sources

- [Frigate — Home Assistant Integration](https://docs.frigate.video/integrations/home-assistant/)
- [Frigate — Home Assistant notifications](https://docs.frigate.video/guides/ha_notifications)
- [Home Assistant — HTTP integration (trusted_proxies)](https://www.home-assistant.io/integrations/http/)
- [Home Assistant — Container installation](https://www.home-assistant.io/installation/linux#docker-compose)
- [HACS](https://hacs.xyz/)
