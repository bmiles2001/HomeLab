# Home Server Build Plan
**Target:** Ubuntu Server 26.04 LTS "Resolute Raccoon" on bare metal, Docker Engine on top
**Hardware:** i9-12900KS · 32GB DDR5-4800 · RTX 3080 10GB + Intel UHD 770 iGPU · 1.82TB storage
**Date:** July 2026

---

## Table of contents

1. [Before you wipe](#1-before-you-wipe)
2. [BIOS setup](#2-bios-setup)
3. [Install Ubuntu Server 26.04](#3-install-ubuntu-server-2604)
4. [Storage layout](#4-storage-layout)
5. [First-boot hardening](#5-first-boot-hardening)
6. [Install Docker](#6-install-docker)
7. [GPU setup](#7-gpu-setup)
8. [Directory structure for containers](#8-directory-structure-for-containers)
9. [Networking: Tailscale + Cloudflare Tunnel](#9-networking-tailscale--cloudflare-tunnel)
10. [Satisfactory dedicated server](#10-satisfactory-dedicated-server)
11. [What your GPUs can actually do](#11-what-your-gpus-can-actually-do)
12. [Backups](#12-backups)
13. [Power and noise](#13-power-and-noise)
14. [Suggested build order](#14-suggested-build-order)

---

## 1. Before you wipe

You said the 451GB is disposable — good. Still worth thirty seconds of thought on the things people routinely forget:

- Podman/Docker **volumes** (not just the compose files — the actual data inside them)
- Any `compose.yaml` files you've written and want to reuse
- Game saves, especially local Satisfactory saves you might want to seed the dedicated server with
- Browser profiles, SSH keys, `.env` files with API tokens
- Windows license — irrelevant here, it's an OEM/digital entitlement tied to the board. If you ever reinstall Windows it'll reactivate on its own.

**Existing Satisfactory saves:** if you want to continue an existing world on the new dedicated server, grab the `.sav` files from
`C:\Users\brent\AppData\Local\FactoryGame\Saved\SaveGames\`
before wiping. You can upload them to the server later.

You'll need a USB stick (4GB+) and [Rufus](https://rufus.ie) or [balenaEtcher](https://etcher.balena.io) to write the Ubuntu ISO. Grab the **Server** ISO, not Desktop:
https://ubuntu.com/download/server

---

## 2. BIOS setup

Reboot, mash `Delete` to enter the MSI BIOS. Set these:

| Setting | Value | Why |
|---|---|---|
| **XMP / EXPO profile** | Enabled | Your DDR5 runs at 4800 stock. XMP gets you rated speed. Free performance. |
| **VT-x / Intel Virtualization** | Enabled | Needed if you ever add VMs |
| **VT-d / IOMMU** | Enabled | Needed for GPU passthrough later |
| **Secure Boot** | Disabled | Simplifies NVIDIA driver install (see §7 for the alternative) |
| **Restore on AC Power Loss** | Power On | Server comes back up after an outage without you touching it |
| **Wake on LAN** | Enabled | Optional, lets you wake it remotely |
| **iGPU / Integrated Graphics** | Enabled + "Auto" or "Force" | **Critical** — you need the UHD 770 active for transcoding even with the 3080 installed |
| **Primary Display** | PEG / PCIe | Boot output goes to the 3080 |
| **CPU C-States** | Enabled | Meaningful idle power savings on a 24/7 box |

The iGPU one catches people out. Many boards disable integrated graphics automatically when a discrete card is detected. You want both alive.

---

## 3. Install Ubuntu Server 26.04

Boot the USB. The installer is text-based and takes about ten minutes.

Choices that matter:

- **Type of install:** Ubuntu Server (not minimized)
- **Network:** configure a **static IP** now, or set a DHCP reservation on your router afterward. You do not want this box changing address.
- **Profile:** pick a username that isn't `root`. Server name something like `hearth` or `forge` — anything but `Docker`, which will get confusing fast.
- **SSH:** ✅ **Install OpenSSH server**. If you have a GitHub account with your public key uploaded, the installer can import it directly — take that option.
- **Featured snaps:** select **nothing**. Especially not Docker. You'll install Docker from the official apt repo, and the snap version causes permission headaches with volumes.

After install, pull the machine's monitor and keyboard if you want — everything from here is over SSH.

---

## 4. Storage layout

Your box reports 1.82TB total, which suggests either a single 2TB drive or a 1TB NVMe plus a second disk. Check what you actually have:

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINT
```

### If it's one drive

Use LVM (the installer offers this — take "Use an entire disk and set up LVM"). Then **don't let the installer allocate the whole volume group.** By default Ubuntu's guided LVM leaves free space; if it didn't, you can shrink later, but it's easier to get right now.

Sensible split:

| Mount | Size | Notes |
|---|---|---|
| `/` | 100GB | OS, packages, container images |
| `/srv` | rest | All container data, game servers, media |

Keeping `/srv` separate means a runaway log or image cache can't fill your root filesystem and wedge the machine.

### If it's two drives

Better outcome:

- **NVMe** → OS + `/var/lib/docker` (images) + game server files + databases. Speed matters here; Satisfactory autosaves are I/O bursty.
- **Second drive** → `/srv/media`, backups, anything bulk.

### Either way

Check free space on the volume group and extend as needed:

```bash
sudo vgs                      # see free space
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
```

**A note on filesystems:** ext4 is the default and is completely fine. ZFS gives you snapshots and checksumming, which are genuinely nice for a server, but it's a bigger learning curve and eats RAM you'd rather give to Satisfactory. Given 32GB, stick with ext4 for now.

---

## 5. First-boot hardening

SSH in and run through these. None of it is optional on a machine you'll expose to the internet.

```bash
# Update everything
sudo apt update && sudo apt full-upgrade -y

# Useful basics
sudo apt install -y curl git vim htop btop tmux unzip ncdu \
  ca-certificates gnupg lsb-release
```

### SSH keys, then disable passwords

From your Windows machine (PowerShell):

```powershell
ssh-keygen -t ed25519 -C "netto@brent-miles.com"
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh netto@<server-ip> "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

**Test that key login works before locking password auth out.** Open a second terminal, confirm you get in without a password prompt, *then*:

```bash
sudo vim /etc/ssh/sshd_config.d/99-hardening.conf
```

```
PasswordAuthentication no
PermitRootLogin no
KbdInteractiveAuthentication no
```

```bash
sudo systemctl restart ssh
```

### Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw enable
```

You'll open specific ports as you add services. Docker has a well-known habit of punching through ufw by publishing ports directly to iptables — the fix is to bind container ports to `127.0.0.1` or your Tailscale IP rather than `0.0.0.0` wherever a service doesn't need to be publicly reachable.

### Automatic security updates

```bash
sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

### Fail2ban (optional but cheap)

```bash
sudo apt install -y fail2ban
```

Defaults are sensible and will start banning SSH brute-forcers immediately.

---

## 6. Install Docker

Ubuntu 26.04 has official Docker repo support from day one — no pinning to older codenames needed.

```bash
# Remove anything conflicting
sudo apt remove -y docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc

# Add Docker's GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repo
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Add yourself to the docker group so you don't need `sudo` for everything:

```bash
sudo usermod -aG docker $USER
newgrp docker    # or just log out and back in
docker run hello-world
```

> **Worth understanding:** membership in the `docker` group is effectively root access — a user in that group can mount the host filesystem into a container. On a single-admin home server that's a reasonable trade. Just don't add accounts you wouldn't give sudo to.

### Move Docker's data directory (optional)

If you want images and volumes on a specific disk:

```bash
sudo systemctl stop docker
sudo vim /etc/docker/daemon.json
```

```json
{
  "data-root": "/srv/docker-data",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

The log options aren't optional in spirit — default Docker logging is unbounded and *will* eventually fill your disk.

```bash
sudo rsync -aP /var/lib/docker/ /srv/docker-data/
sudo systemctl start docker
```

---

## 7. GPU setup

You have two GPUs and they should do different jobs:

- **Intel UHD 770 (iGPU)** → media transcoding. QuickSync on 12th-gen is excellent, handles AV1 decode, and uses a fraction of the power of waking the 3080.
- **RTX 3080** → AI inference, game streaming, anything CUDA.

### NVIDIA driver

```bash
ubuntu-drivers devices          # see what's recommended
sudo ubuntu-drivers install     # note: 'autoinstall' is gone in 26.04
```

Your 3080 is Ampere, so it's supported by the open kernel modules — currently `nvidia-driver-595-open`. To pin that explicitly:

```bash
sudo ubuntu-drivers install nvidia:595-open
sudo reboot
nvidia-smi                      # should print your 3080
```

> **If you left Secure Boot enabled:** the installer will prompt you to set a MOK (Machine Owner Key) password. You must then reboot, catch the blue MOK Manager screen, choose "Enroll MOK," and enter that password. Miss this and the driver silently won't load. This is why §2 suggests just disabling Secure Boot on a home server.

### NVIDIA Container Toolkit

This is what lets containers see the GPU.

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update
sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify:

```bash
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
```

### Intel iGPU for transcoding

```bash
sudo apt install -y intel-media-va-driver-non-free vainfo
vainfo                          # should list H.264/HEVC/AV1 profiles
sudo usermod -aG render,video $USER
```

Containers get access by mapping the device:

```yaml
devices:
  - /dev/dri:/dev/dri
group_add:
  - "993"   # your 'render' group GID — check with: getent group render
```

---

## 8. Directory structure for containers

Pick a convention now and you'll thank yourself in a year. Suggested:

```
/srv/
├── docker/
│   ├── satisfactory/
│   │   ├── compose.yaml
│   │   └── .env
│   ├── jellyfin/
│   │   ├── compose.yaml
│   │   └── .env
│   ├── ollama/
│   │   └── compose.yaml
│   └── immich/
│       ├── compose.yaml
│       └── .env
├── appdata/          # persistent config volumes, one subdir per service
│   ├── satisfactory/
│   ├── jellyfin/
│   └── immich/
└── media/            # bulk storage
    ├── movies/
    ├── tv/
    └── photos/
```

**Why split `docker/` from `appdata/`:** the `docker/` tree is pure configuration — small, text-only, and perfect for a private git repo. The `appdata/` tree is state that needs real backups. Different backup strategies, so keep them apart.

```bash
sudo mkdir -p /srv/{docker,appdata,media}
sudo chown -R $USER:$USER /srv
cd /srv/docker && git init
```

Add a `.gitignore` with `.env` in it, so you never commit secrets.

### Shared network

Create one user-defined bridge so containers can reach each other by name:

```bash
docker network create homelab
```

Then reference it in each compose file with `networks: [homelab]` and `external: true`.

---

## 9. Networking: Tailscale + Cloudflare Tunnel

These solve different problems and you want both.

### Tailscale — for you and your family

A private WireGuard mesh. Install it natively (not in a container):

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-exit-node
```

Install the Tailscale app on the iPhones and Windows machines. Now every device can reach the server at a stable `100.x.x.x` address with zero ports open on your router. This is the correct way to reach admin interfaces, file shares, and **game servers**.

Enable MagicDNS in the Tailscale admin console and you get `hearth.your-tailnet.ts.net` hostnames for free.

### Cloudflare Tunnel — for anything genuinely public

You own `brent-miles.com` on Cloudflare, so this is easy. A tunnel gives you `https://something.brent-miles.com` with a valid cert and **no open inbound ports**.

```yaml
# /srv/docker/cloudflared/compose.yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${TUNNEL_TOKEN}
    networks: [homelab]

networks:
  homelab:
    external: true
```

Create the tunnel in the Cloudflare Zero Trust dashboard, copy the token into `.env`, and map hostnames to internal services (e.g. `jellyfin.brent-miles.com` → `http://jellyfin:8096`).

> ⚠️ **Do not route game traffic through Cloudflare.** Cloudflare's proxy only handles HTTP/HTTPS. Satisfactory needs raw UDP, so any DNS record pointing at your game server must be **DNS-only (grey cloud)**, never proxied (orange cloud). Proxying it will simply break the connection. Cloudflare Spectrum does proxy arbitrary TCP/UDP, but it's a paid enterprise-tier product and overkill here — use Tailscale or a plain port forward instead.

### Rule of thumb

| Traffic | Route |
|---|---|
| Admin UIs, dashboards, SSH | Tailscale only |
| Game servers | Tailscale, or a deliberate port forward |
| Public websites, sharing a photo album with family | Cloudflare Tunnel |
| Anything you're unsure about | Tailscale |

---

## 10. Satisfactory dedicated server

### The container

```yaml
# /srv/docker/satisfactory/compose.yaml
services:
  satisfactory:
    image: wolveix/satisfactory-server:latest
    container_name: satisfactory
    restart: unless-stopped
    volumes:
      - /srv/appdata/satisfactory:/config
    ports:
      - "7777:7777/udp"
      - "7777:7777/tcp"
      - "8888:8888/tcp"         # server API / management
    environment:
      - MAXPLAYERS=4
      - PGID=1000
      - PUID=1000
      - STEAMBETA=false
      - SKIPUPDATE=false
    mem_limit: 16G
    healthcheck:
      test: ["CMD-SHELL", "ss -tulpn | grep -q 7777 || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 3
```

```bash
cd /srv/docker/satisfactory
docker compose up -d
docker compose logs -f          # first run downloads ~15GB, be patient
```

Check `PUID`/`PGID` match your user (`id -u` and `id -g`).

### Firewall

```bash
sudo ufw allow 7777/udp
sudo ufw allow 7777/tcp
sudo ufw allow 8888/tcp
```

Older builds also wanted UDP 15777 and 15000 (query and beacon ports). Post-1.0 the server consolidated onto 7777, but if clients can't discover the server, open those two as well.

### Connecting

In-game: **Server Manager → Add Server**, then enter the server's address. Over Tailscale that's the `100.x.x.x` address or MagicDNS name — which means friends need to be on your tailnet. If you'd rather they just connect directly, forward UDP/TCP 7777 on your router to the server and hand out your public IP or a `satisfactory.brent-miles.com` **DNS-only** (grey cloud, *not* proxied) A record.

You'll set an admin password on first connect, then claim the server and either start a new save or upload an existing `.sav`.

### Tuning notes

- **Turn on "Auto Pause" in the in-game server settings** (Server Manager → Settings), not via an environment variable. An idle server otherwise keeps simulating your whole factory and burning a CPU core for nobody. This is the single most useful setting on the box.
- Check the [image's README](https://github.com/wolveix/satisfactory-server/blob/main/README.md) for the current full environment variable list — it changes between releases. `SKIPUPDATE=true` is worth knowing about: it stops the container updating the game on restart, which is what you want once mods are pinned to a version.
- **Pin the image tag** once you're running mods. `:latest` will happily update into a version your mods don't support. Change to something like `wolveix/satisfactory-server:1.1.x` once you're settled.
- `mem_limit: 16G` prevents a runaway save from OOM-killing your other containers. Raise it if you hit the cap, but on 32GB total you don't want this unbounded.

### Mods

Satisfactory does **not** use Steam Workshop — mods live at [ficsit.app](https://ficsit.app) and are managed with **Satisfactory Mod Manager (SMM) v3+**, which can push to a remote server over SFTP.

Three rules:

1. **Stop the server before changing mods.** Hot-swapping corrupts things.
2. **Every client must have an identical mod list and versions**, or they can't connect.
3. **Filter for the "Server" checkmark** on ficsit.app — many mods are client-side only and won't work server-side.

To use SMM's SFTP mode you'll need SSH access into the container's config directory. Simplest approach is to point SMM at the host path `/srv/appdata/satisfactory` over regular SFTP, since that's where the container's `/config` lives.

---

## 11. What your GPUs can actually do

You said you weren't sure what's possible — here's the honest menu, roughly in order of effort-to-payoff.

### Easy wins

**Media transcoding (iGPU, not the 3080).** Jellyfin or Plex serving your library to the TVs and iPhones. QuickSync handles several simultaneous 4K→1080p transcodes without breaking a sweat, at maybe 10W. Use the 3080 for this only if you somehow saturate the iGPU.

```yaml
# Jellyfin, abbreviated
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    devices:
      - /dev/dri:/dev/dri
    volumes:
      - /srv/appdata/jellyfin:/config
      - /srv/media:/media
    ports:
      - "8096:8096"
```

Then enable VAAPI hardware acceleration in Jellyfin's dashboard.

**Local LLMs (3080).** Ollama plus Open WebUI gives you a private ChatGPT-style interface. 10GB VRAM comfortably runs quantized 7B–14B models — good enough for summarizing, drafting, code help, and question answering. Not GPT-5 class, but it's yours, it's free, and it works offline.

```yaml
services:
  ollama:
    image: ollama/ollama:latest
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    volumes:
      - /srv/appdata/ollama:/root/.ollama
    ports:
      - "11434:11434"
```

Start with `ollama pull llama3.1:8b` or `qwen2.5:14b-instruct-q4_K_M`.

**Photo management (3080).** [Immich](https://immich.app) is a self-hosted Google Photos replacement with iOS apps that auto-back-up your camera roll. The machine-learning features — face recognition, object search, "show me photos of the dog at the beach" — run on the 3080. Given the household is iPhone-based and currently on OneDrive, this is probably the highest-value thing on this list after the game server.

### Medium effort

**Frigate NVR.** If you have or want security cameras, Frigate does real-time object detection — "person in driveway" rather than "motion detected," which cuts false alerts to near zero. Runs on the 3080, or on a $25 Coral TPU if you'd rather leave the GPU free.

**Image generation.** ComfyUI or Automatic1111 in a container. 10GB VRAM handles SDXL fine. Fun, occasionally useful, big disk consumer.

**Whisper transcription.** Self-hosted speech-to-text. Pairs nicely with a media library for auto-generating subtitles.

### Hard — set expectations here

**Game streaming (Sunshine + Moonlight).** This is the one with real friction, and I'd rather flag it now than have you discover it at 1am.

Sunshine streams a desktop session, so on a *headless* Ubuntu Server there's no display to capture. Your options:

1. **Virtual display** — configure a dummy X/Wayland session, or plug in a ~$10 HDMI dummy plug so the GPU thinks a monitor is attached. Then Sunshine captures that. Works, but it's fiddly and NVIDIA + Wayland + headless is the least well-trodden combination of the three.
2. **Windows VM with GPU passthrough** — pass the 3080 through to a Windows guest and run Sunshine there. Most reliable for Windows games, but this is the setup where I'd tell you to have installed Proxmox instead of bare-metal Ubuntu. Doable with KVM/libvirt on Ubuntu, just more work.
3. **Steam's built-in Remote Play** on Linux with Proton. Fine for Linux-native and Proton-compatible titles, doesn't cover everything.

None of this is impossible, but it's a weekend project rather than an evening one. **My suggestion: get the server, containers, and Satisfactory running first. Come back to game streaming once the box is stable and you're comfortable on Linux.** If it turns out to be the feature you care most about, that's a strong argument for rebuilding on Proxmox with a Windows VM — which is exactly why the iGPU matters (it keeps the host running while the 3080 goes to the guest).

### Not worth it

Running your *own* gameplay on this box while it also serves Satisfactory. The i9 is fast but you'll be fighting yourself for cores and RAM, and any crash takes down the server for everyone. Keep your gaming PC separate.

---

## 12. Backups

The uncomfortable truth of self-hosting: nobody regrets setting up backups, everybody regrets not having.

**What actually needs backing up:**

| Data | Priority | Notes |
|---|---|---|
| `/srv/docker/` (compose files) | Critical | Tiny. Push to a private GitHub repo. |
| `/srv/appdata/` | Critical | Container state, databases, game saves |
| Satisfactory `.sav` files | High | Your factory. Back these up separately and often. |
| `/srv/media/` | Low | Re-acquirable. Back up if convenient. |

**Recommended tooling:** `restic` for encrypted, deduplicated, incremental backups, with `rclone` fronting OneDrive since you already pay for it.

```bash
sudo apt install -y restic rclone
rclone config          # add OneDrive as a remote, interactive wizard
restic -r rclone:onedrive:server-backups init
```

A nightly systemd timer or a cron entry running:

```bash
restic -r rclone:onedrive:server-backups backup /srv/appdata /srv/docker \
  --exclude-caches --tag nightly
restic -r rclone:onedrive:server-backups forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
```

**Test your restore.** A backup you've never restored from is a hypothesis, not a backup. Pick a random file, restore it to `/tmp`, confirm it's intact. Do this once a quarter.

---

## 13. Power and noise

An i9-12900KS and a 3080 running 24/7 is not a low-power NAS. Realistic idle is somewhere in the 60–110W range depending on how aggressively you tune it, which at typical US residential rates lands roughly in the $100–200/year territory. Worth knowing, not worth panicking about.

To trim it:

```bash
sudo apt install -y powertop
sudo powertop --auto-tune
```

- Enable C-states in BIOS (§2)
- Set the CPU governor to `powersave` — the 12900KS boosts fine on demand anyway:
  ```bash
  sudo apt install -y linux-tools-generic
  echo 'GOVERNOR="powersave"' | sudo tee /etc/default/cpufrequtils
  ```
- The 3080 idles around 15–20W. `nvidia-smi -pl 250` caps its power limit if you want a ceiling during AI workloads.
- Set a quiet fan curve in BIOS. A server that lives in a cupboard doesn't need aggressive cooling at idle, and you'll notice the noise more than you expect.

---

## 14. Suggested build order

Don't do all of this in one sitting. Sensible sequence:

**Evening 1 — foundation**
1. BIOS settings
2. Install Ubuntu Server 26.04
3. SSH keys, ufw, unattended-upgrades
4. Install Docker, run `hello-world`

**Evening 2 — the fun part**
5. Directory structure + `homelab` network
6. Satisfactory server, connect from your PC, verify it works
7. Tailscale, verify you can reach the server from your phone

**Evening 3 — GPU**
8. NVIDIA driver + Container Toolkit, verify `nvidia-smi` in a container
9. iGPU/VAAPI, install Jellyfin, confirm hardware transcoding
10. Ollama + Open WebUI

**Evening 4 — durability**
11. restic + rclone to OneDrive, run first backup
12. Cloudflare Tunnel if you want anything public
13. Immich, point the family's iPhones at it

**Later**
14. Mods on the Satisfactory server
15. Game streaming, once you're comfortable

---

## Quick reference

```bash
# Container management
docker compose up -d              # start (from a service dir)
docker compose down               # stop and remove
docker compose pull && docker compose up -d    # update
docker compose logs -f            # follow logs
docker ps                         # what's running
docker stats                      # live resource usage

# System
btop                              # everything, at a glance
ncdu /srv                         # what's eating disk
nvidia-smi                        # GPU status
sudo journalctl -u docker -f      # docker daemon logs
docker system prune -a            # reclaim space (careful — removes unused images)
```

---

## Sources

- [Ubuntu 26.04 LTS release notes](https://documentation.ubuntu.com/release-notes/26.04/)
- [Docker Engine install on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [NVIDIA drivers on Ubuntu Server](https://ubuntu.com/server/docs/how-to/graphics/install-nvidia-drivers/)
- [NVIDIA Container Toolkit docs](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html)
- [Satisfactory Wiki — Dedicated servers](https://satisfactory.wiki.gg/wiki/Dedicated_servers)
- [Satisfactory Modding — Dedicated Server Setup](https://docs.ficsit.app/satisfactory-modding/latest/ForUsers/DedicatedServerSetup.html)
- [wolveix/satisfactory-server](https://github.com/wolveix/satisfactory-server)
- [Tailscale](https://tailscale.com/kb/1017/install)
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- [Immich](https://immich.app/docs/install/docker-compose)
