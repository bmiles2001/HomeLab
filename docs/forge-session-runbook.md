# `forge` — first session runbook

Ubuntu Server, Docker, bare metal. Written 2026-07-28 for a ~2 hour window.

The order below is deliberate: nothing that touches the network happens before
the box can survive being on it, and nothing gets exposed to the internet today.

| Phase | Minutes | What |
|---|---|---|
| 0 | 5 | Confirm SSH key access before changing anything |
| 1 | 25 | Harden: SSH, firewall, updates, root |
| 2 | 15 | Docker, plus the UFW trap |
| 3 | 20 | Repo restructure + Infisical |
| 4 | 45 | Caddy + Immich, LAN only |
| — | later | External exposure, Komodo, backups |

**Stop at the end of phase 4 today.** Exposing 443 is the step that punishes
being rushed, and it deserves its own session with a clear head.

---

## Phase 0 — the SSH question, answered

> *I set up OpenSSH during the install using the key from my GitHub account. Do
> I need to configure OpenSSH to use the same public key for SSH from the PC?*

**No. It's already done.** The installer's "Import SSH identity from GitHub"
option fetches every public key on your GitHub account and writes them into
`~/.ssh/authorized_keys` for the user you created. Your Windows PC's key is on
GitHub, so your Windows PC can already log in.

*Why it mattered:* it means you have working key-based login **before** you ever
need password login — so you can disable passwords in phase 1 without any risk
of locking yourself out. That's the whole point.

Verify it from your PC before touching anything else:

```powershell
ssh netto@<forge-ip>
```

If that lands you at a shell without a password prompt, proceed. If it asks for
a password, **stop and fix that first** — do not run phase 1.

```bash
# on forge
cat ~/.ssh/authorized_keys
```

### The gap this leaves

The GitHub import gets your PC **into** forge. It does nothing for forge pulling
**from** GitHub. Forge needs its own keypair:

```bash
ssh-keygen -t ed25519 -C "forge" -f ~/.ssh/id_ed25519 -N ""
cat ~/.ssh/id_ed25519.pub
```

Add that as a **deploy key** on the `home-containers` repo (Settings → Deploy
keys), read-only. A repo deploy key, not another account-wide key — if forge is
ever compromised you revoke one repo's access, not your whole GitHub identity.

Add a host alias on your PC (`~/.ssh/config`) so the rest of this is `ssh forge`:

```
Host forge
    HostName 10.0.0.4
    User netto
```

Give forge a **DHCP reservation** on the router now, while you're thinking about
it. Everything downstream assumes the address doesn't move.

---

## Phase 1 — harden (25 min)

### Rule for this phase

**Keep your current SSH session open the entire time.** Open a *second* terminal
to test each change. If you lock yourself out with the first session still live,
you can undo it. If you close it first, you're walking to the machine with a
keyboard.

### 1.1 SSH

The trap: Ubuntu's `/etc/ssh/sshd_config` has `Include /etc/ssh/sshd_config.d/*.conf`
at the **top**, and sshd uses **first-obtained-value-wins**. The installer often
leaves a `50-cloud-init.conf` in there setting `PasswordAuthentication yes`. A
file named `99-hardening.conf` is read *after* it and is therefore **silently
ignored**. Name yours low.

```bash
ls -la /etc/ssh/sshd_config.d/
sudo tee /etc/ssh/sshd_config.d/01-hardening.conf >/dev/null <<'EOF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowUsers netto
EOF
```

Verify the **effective** config rather than trusting the file — this is the step
people skip and then wonder why passwords still work:

```bash
sudo sshd -t                              # syntax check; must be silent
sudo sshd -T | grep -Ei 'passwordauth|permitroot|kbdinteractive|allowusers'
```

You want `passwordauthentication no`. If it says `yes`, something numerically
lower is overriding you — go read the file `ls` showed.

```bash
sudo systemctl restart ssh
```

Now, **from a second terminal**, confirm you can still get in, and confirm
passwords are refused:

```bash
ssh forge
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no netto@10.0.0.4
# expected: "Permission denied (publickey)."
```

### 1.2 Accounts

```bash
sudo passwd -l root        # lock root's password; sudo still works
sudo passwd -S netto       # should show P (a password is set) — keep it for sudo
```

Keep a real password on `netto` and **do not** add a `NOPASSWD` sudo rule. Key
for the door, password for the escalation — two different secrets, and a stolen
laptop key alone doesn't get root.

### 1.3 Firewall

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow OpenSSH
sudo ufw enable
sudo ufw status verbose
```

80/443 stay closed today.

### 1.4 Automatic security updates

```bash
sudo apt update && sudo apt install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

Then in `/etc/apt/apt.conf.d/50unattended-upgrades`, enable:

```
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
```

A homelab that reboots itself at 4am is strictly better than one that runs a
vulnerable kernel for six weeks because you never got around to it.

### 1.5 fail2ban — skip it, for now

With password auth off, fail2ban on SSH protects against approximately nothing;
`publickey`-only means there's no credential to guess. It becomes worth
installing the day something is exposed on 443, and at that point **CrowdSec**
is the better choice because it covers the Caddy logs where the actual attacks
will be. Defer to the exposure session.

---

## Phase 2 — Docker (15 min)

Use Docker's own repo, not the `docker.io` package from Ubuntu — you want
current Compose v2 and current engine.

```bash
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
newgrp docker          # or log out and back in
docker compose version
```

Note what you just did: `docker` group membership is **root-equivalent**. Anyone
who can run `docker` can mount `/` into a container. That's the accepted cost of
not running rootless; it's fine for a single-admin home box, and it's the thing
that makes Komodo and every other Docker-ecosystem tool work out of the box.

### The UFW trap — read this before publishing any port

Docker writes its own iptables rules into `PREROUTING`/`FORWARD`, so published
ports **never traverse the `INPUT` chain UFW controls**. A container started with
`-p 8080:80` is reachable from your entire LAN even with `ufw deny 8080` active.
This is documented Docker design, not a bug, and it is the single most common
way self-hosters accidentally expose a service.

Two defences, use both:

**1. Bind to localhost in compose.** `"127.0.0.1:8080:80"` instead of
`"8080:80"`. Docker only DNATs from loopback and the port is unreachable from
the network regardless of firewall state.

**2. Install `ufw-docker`,** which stitches UFW's chains into `DOCKER-USER` so
Docker traffic actually passes through your rules:

```bash
sudo wget -O /usr/local/bin/ufw-docker \
  https://github.com/chaifeng/ufw-docker/raw/master/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker
sudo ufw-docker install
sudo systemctl restart ufw
```

Your architecture already helps here: **only Caddy publishes ports.** Everything
else joins the `proxy` network and is reached by container name. Keep that rule
and the blast radius stays one container.

Verify from your PC, not from forge:

```bash
nmap -Pn 10.0.0.4        # expect 22 only
```

---

## Phase 3 — repo restructure + Infisical (20 min)

The repo currently assumes Podman-on-WSL. The compose files themselves are
portable; the wrappers around them aren't.

- `bootstrap.sh` — replace podman machine checks with a Docker check; keep the
  `proxy` network creation and directory scaffolding
- `scripts/deploy.sh` — `podman compose` → `docker compose`
- `docs/wsl-host.md` — delete; every constraint in it is gone
- `docs/remote-access.md` — rewrite; no more `RemoteCommand wsl -d ...`, SSH now
  lands you where you actually want to be
- `README.md` — drop "Podman on a Windows box"; volumes on `C:/` is no longer a
  concept that exists
- `scripts/immich-onedrive-sync.*` — revisit. It was written against Windows
  paths. `rclone` to OneDrive from Linux is the replacement.

Data lives on the NVMe:

```bash
sudo mkdir -p /srv/{immich,caddy,infisical,frigate}
sudo chown -R $USER:$USER /srv
```

### Phase 2.5 — NVIDIA driver, then the Container Toolkit

Do this before deploying Immich, because `stacks/immich/compose.yml` now asks
for a GPU and the stack won't come up without it.

**Two separate installs, in this order.** The toolkit is only a bridge — it
exposes a driver that must already exist on the host. Installing the toolkit
alone gets you:

```
nvidia-container-cli: initialization error: load library failed:
libnvidia-ml.so.1: cannot open shared object file
```

which means exactly one thing: no driver.

#### 1. The driver (host)

Full detail in [`home-server-build-plan.md`](../home-server-build-plan.md) §7.

```bash
ubuntu-drivers devices          # see what's recommended for the 3080
sudo ubuntu-drivers install nvidia:595-open
sudo reboot
```

The 3080 is Ampere, so the `-open` kernel modules are supported and preferred.
Take whatever version `ubuntu-drivers devices` marks `recommended` — it must be
**>= 545** for Immich's CUDA 12.3 image, and anything current comfortably is.

After the reboot:

```bash
nvidia-smi                      # must print the 3080
```

If it prints nothing or says it can't communicate with the driver, check Secure
Boot before reinstalling anything:

```bash
mokutil --sb-state
```

If it's enabled, the DKMS module is built but unsigned, so the kernel silently
refuses to load it — the failure looks identical to the driver not being
installed. Either enroll the MOK (reboot, catch the blue MOK Manager screen,
"Enroll MOK", enter the password the installer asked for) or disable Secure
Boot in the BIOS, which is what §2 of the build plan recommends for this box.

#### 2. The toolkit (docker)

Only once `nvidia-smi` works:

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
sudo apt update && sudo apt install -y nvidia-container-toolkit
sudo nvidia-ctk runtime configure --runtime=docker
sudo systemctl restart docker
```

Verify from inside a container, not from the host:

```bash
docker run --rm --gpus all nvidia/cuda:12.6.0-base-ubuntu24.04 nvidia-smi
```

If that prints your 3080, Immich's ML container will start. `./bootstrap.sh`
also checks this and warns if the toolkit isn't registered.

> **Verified on forge, 2026-07-29:** `nvidia-driver-595-open`, driver 595.84,
> CUDA 13.2, RTX 3080 10GB, idle at 11W. Container passthrough confirmed with
> the command above. Secure Boot was not an issue.

#### If you're short on time today

This is a reboot and a BIOS trip, and it is not on the critical path for having
photos working. To keep moving, drop Immich's ML back to CPU — in
`stacks/immich/compose.yml`, remove the `-cuda` suffix from the image tag and
delete the `deploy.resources` block. Everything works; face detection and smart
search just take longer on the first import. Put it back when the driver is in.

**Note on `unattended-upgrades`:** NVIDIA driver packages updating out from
under a running container is a classic 3am failure. If ML starts breaking after
a reboot, a version mismatch between host driver and container is the first
thing to check.

Infisical first — it holds everyone else's secrets and has no dependencies of
its own. Same bootstrap chain as before: `stacks/infisical/.env` on disk, machine
identity in `~/.infisical-identity`, chain terminating in your password manager.
`scripts/infisical-backup.sh` must be running **before** anything real goes in.

---

## Phase 4 — Caddy + Immich, LAN only (45 min)

Caddy first, because Immich needs somewhere to be proxied from.

- Caddy is still the only stack that publishes ports — but now publish
  `"443:443"` properly, since the box is Linux and there's no WSL port-proxy
  nonsense in the middle
- Wildcard cert over Cloudflare DNS-01, same as before. This works today with
  443 closed on the router, which is exactly why DNS-01 was the right call
- `photos.brent-miles.com` → A record at forge's **LAN** address for now. Cloudflare
  grey cloud (DNS only). Resolves usefully only from inside the house

Immich:

- Pin an explicit version tag — `v3.1.0` as of 2026-07-29. Never `:latest`.
  The pin lives in Infisical under `/immich`; see
  [immich-deploy.md](immich-deploy.md) for the bump procedure
- `UPLOAD_LOCATION=/srv/immich/data`
- Postgres and Redis stay on the stack's private network; **only** `immich-server`
  joins `proxy`
- **No** request body limit in the Caddyfile. Caddy has none by default, which
  is what iPhone video uploads need. (If you've used nginx you'll reach for
  `client_max_body_size` — that's an nginx directive and adding Caddy's
  equivalent here would *create* the problem it's meant to solve.)
- The ML container now uses the `-cuda` image and declares a GPU reservation,
  so it will fail to start without the toolkit from phase 2.5 below

Then, in order: create your account, create your wife's and daughter's accounts,
install the iOS app on one phone, and **turn on Background App Refresh for
Immich in iOS Settings** — background backup silently never runs without it.

Test one photo end to end before you install anything on anyone else's phone.

---

## Not today

**External exposure.** Forward 443 (and 80 only if you want HTTP→HTTPS
redirects), add CrowdSec against the Caddy logs, decide whether Immich is the
*only* thing on a public hostname. Immich has no built-in brute-force
protection — that's your job at the proxy. Its own docs are candid about the
risks of exposing it.

**Komodo.** `docs/decisions.md` rejected it because its periphery agent needs
`/var/run/docker.sock` and podman-under-WSL made that a stack of unsupported
workarounds. **That objection is now void** — this is a real Docker socket on a
real Linux box, the configuration Komodo is actually built and tested for.

It fits what you asked for: stacks defined in git, webhook on push triggers
redeploy, and it polls for image updates and can auto-update containers. Adopt it
*after* Immich works, so its first job is importing a stack you already trust,
not debugging two new things at once.

Doing this shifts one of the two rules in the README. "Never edit on the host"
was a discipline you had to hold in your head; with Komodo, git push *is* the
deployment mechanism, so the rule enforces itself.

**Backups.** Photos on the NVMe are irreplaceable and currently exist in exactly
one place. `rclone` to OneDrive covers offsite. The Immich Postgres needs its
own dump — rebuildable, but re-running face detection over the whole library is
an expensive way to spend an evening.

## Sources

- [ufw-docker](https://github.com/chaifeng/ufw-docker)
- [Docker container published port ignoring UFW rules](https://www.baeldung.com/linux/docker-container-published-port-ignoring-ufw-rules)
- [How to configure UFW with Docker on Ubuntu](https://oneuptime.com/blog/post/2026-03-02-ufw-docker-fix-bypassing-ufw-ubuntu/view)
- [cloud-init 50-cloud-init.conf PasswordAuthentication issue](https://github.com/canonical/cloud-init/issues/5934)
- [Disabling password login on Ubuntu — why it didn't work at first](https://www.thadaw.com/posts/disable-password-ubuntu-2025)
- [Immich — Sharing](https://docs.immich.app/features/sharing/)
- [Immich — FAQ](https://docs.immich.app/FAQ/)
