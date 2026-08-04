# Storage expansion

`forge` — Samsung SSD 970 EVO Plus 2TB (`nvme0n1`), Ubuntu 26.04 "resolute".
Done 2026-08-03.

The Ubuntu installer built a 100G root inside a 1.8TB volume group and left the
rest unallocated. Root was at 92% before this. Everything below was an online LVM
operation — no repartitioning, no unmount, no reboot.

---

## Layout

| Volume | Size | Used | Mount | Purpose |
|---|---|---|---|---|
| `ubuntu-vg/ubuntu-lv` | 394G | 86G (23%) | `/` | OS, Docker images and layers |
| `ubuntu-vg/data` | 984G | 49G (6%) | `/srv` | all app data — immich, caddy, infisical, backups |
| *(unallocated)* | ~463GiB | — | — | snapshot space + extend-on-demand reserve |

Data volume UUID `6218e7de-b002-456b-864f-9b8acf83356d`
Root volume UUID `d9cd2123-bf8c-4a05-95fe-96c4e460b457`

**Why ~463GiB was left unallocated.** LVM extends in seconds; shrinking is offline
and unpleasant. Free VG space is the reserve that lets you grow whichever volume
actually fills, and it is what makes LVM snapshots possible before a risky upgrade.
Allocating everything up front is the mistake that produced the 100G root.

---

## Mount point — resolved 2026-08-04

The volume was originally mounted at `/srv/data`, which was wrong.
`bootstrap.sh` creates its data directories directly under `/srv`:

```
/srv/immich/data      /srv/caddy      /srv/infisical      /srv/backups/infisical
```

Those all lived on **root**, with the 984G volume sitting empty beside them as
`/srv/data`. The 49G photo library was filling the 394G root while the big volume
held nothing.

Mounting the volume at `/srv` itself was chosen over relocating individual
directories: every existing path lands on the big volume with **no changes to
`bootstrap.sh`, no changes to any compose file, and no changes to this repo**. The
alternative — keeping `/srv/data` and moving only the bulk consumers — would have
meant editing the bind-mount paths in `stacks/immich/compose.yml` and maintaining
two layout conventions, and buys nothing on a single physical disk where both
volumes are on the same NVMe anyway.

Verified after the move:

```
/dev/mapper/ubuntu--vg-data       984G   49G  885G   6%  /srv
/dev/mapper/ubuntu--vg-ubuntu--lv 394G   86G  292G  23%  /
```

### Procedure that was used

**1. Stop everything.**

```bash
docker stop $(docker ps -q)
docker ps                      # expect empty
```

Plain `docker stop`, not `docker compose down` — compose parses the stack files and
dies on `required variable DOMAIN is missing` without `infisical run` around it, the
same trap documented in `scripts/deploy.sh`. Containers are restarted through
`deploy.sh` at the end anyway.

**2. Disarm the old fstab entry, then unmount.**

```bash
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i 's|^\(UUID=6218e7de.*\)$|#\1|' /etc/fstab
sudo umount /srv/data
```

Commenting it out first means a power cut mid-migration doesn't remount the volume
over a half-copied tree.

**3. Copy `/srv` onto the volume.**

```bash
sudo mkdir -p /mnt/newsrv
sudo mount /dev/ubuntu-vg/data /mnt/newsrv
sudo rsync -aHAX --numeric-ids --info=progress2 /srv/ /mnt/newsrv/
sudo diff -r --brief /srv /mnt/newsrv
sudo umount /mnt/newsrv
```

`/srv/data` must be unmounted before this runs — otherwise rsync descends into the
destination volume through its own mount point. `--numeric-ids` preserves the uid/gid
that the containers expect.

**4. Mount it at `/srv`.**

```bash
echo "UUID=6218e7de-b002-456b-864f-9b8acf83356d  /srv  ext4  defaults  0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount -a
df -h /srv        # expect 984G
ls -la /srv       # expect immich, caddy, infisical, backups
```

**5. Bring the stacks back.**

```bash
cd ~/home-containers/stacks/infisical && docker compose up -d
cd ~/home-containers
./scripts/deploy.sh caddy
./scripts/deploy.sh immich
./bootstrap.sh        # confirms dirs, network, no stray ports
```

Infisical first and with plain compose — it can't fetch its own secrets, and
everything else needs it up to deploy.

**6. Reboot before trusting it.**

```bash
sudo reboot
df -h /srv && docker ps
```

Named Docker volumes (`caddy_data`, Immich's database) live in
`/var/lib/docker/volumes` on root and are untouched by any of this. Only bind-mounted
paths under `/srv` move.

---

## Cleanup after the move

### Stale fstab entries

Two commented copies of the old `/srv/data` entry are left in `/etc/fstab`. Delete
both — a commented duplicate is exactly the sort of thing that gets uncommented by
mistake a year later.

```bash
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i '/^#UUID=6218e7de.*\/srv\/data/d' /etc/fstab
grep -n srv /etc/fstab       # expect one active line, mounting /srv
```

### Leftover directories on the volume

`/srv/containers`, `/srv/media`, and `/srv/data` are artefacts of the original
`/srv/data` layout. `/srv/frigate` is left from the removed stack. All are empty.

```bash
sudo rmdir /srv/containers /srv/media /srv/data
sudo rm -rf /srv/frigate
```

**Leave `lost+found` alone.** It belongs to the ext4 filesystem itself and `fsck`
uses it to park orphaned inodes during recovery.

### Reclaiming the shadowed copy on root

The pre-migration `/srv` still exists on the root filesystem, hidden underneath the
mount — which is why root still reports 86G used. Reach it by bind-mounting the root
filesystem somewhere else, which exposes the underlying directory without submounts:

```bash
sudo mkdir -p /mnt/rootfs
sudo mount --bind / /mnt/rootfs
sudo du -sh /mnt/rootfs/srv/*        # the shadowed originals
```

Verify that what you see there is genuinely the old copy and that `/srv` has the live
data, then:

```bash
sudo rm -rf /mnt/rootfs/srv/*
sudo umount /mnt/rootfs
df -h /
```

This is preferable to rebooting with the fstab line commented out — no reboot, no
window where the machine could come up with the wrong mount. But do it only **after**
the new mount has survived a reboot and the stacks are healthy, and read the paths
twice: `rm -rf` under a bind mount of `/` is unforgiving of a typo.

---

## What was run

### Extend root

```bash
sudo lvextend -L 400G /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h /
```

100.00 GiB (25600 extents) → 400.00 GiB (102400 extents), resized live while mounted
on `/`.

### Create the data volume

```bash
sudo lvcreate -L 1000G -n data ubuntu-vg
sudo mkfs.ext4 -L data /dev/ubuntu-vg/data
```

ext4 over XFS deliberately: ext4 can be shrunk offline if the layout needs
rethinking, and it matches root so there is one set of tools to know. XFS is
marginally faster on large sequential media, not enough to justify a one-way door.

### Mount

```bash
sudo mkdir -p /srv/data
echo "UUID=$(sudo blkid -s UUID -o value /dev/ubuntu-vg/data)  /srv/data  ext4  defaults  0 2" | sudo tee -a /etc/fstab
sudo systemctl daemon-reload
sudo mount -a
df -h /srv/data
```

The UUID is interpolated by `blkid` rather than retyped. One transposed character in
`/etc/fstab` drops a headless box into emergency mode at next boot.

> **"already mounted or mount point busy" is expected, not an error.**
> `systemctl daemon-reload` runs systemd's fstab generator, which mounts the new
> entry immediately; the following `mount -a` then finds it already mounted. Confirm
> with `findmnt /srv/data`.

---

## Still to do

### 1. Reboot and confirm

The fstab entry has not survived a real boot yet, so this is unfinished.

```bash
findmnt /srv/data
sudo reboot
df -h /srv/data     # after it returns
```

Recovery from a bad fstab needs physical console access — append
`systemd.unit=emergency.target` at the GRUB prompt, `mount -o remount,rw /`, fix the
file. Which is the argument for testing it deliberately now rather than discovering
it during a power cut.

### 2. Backups onto something that isn't this disk

**The most important item here.** Everything on `forge` is on one NVMe: OS,
containers, the photo library, and anything called "backups". That covers accidental
deletion and nothing else — not drive failure, not controller failure, not theft or
fire.

`scripts/immich-onedrive-sync.sh` already mirrors the photo library offsite, which is
the single most irreplaceable thing on the box, and `scripts/infisical-backup.sh`
dumps the secrets database. Between them the two highest-value datasets are covered.
What isn't: container volumes, and the host config that lives outside this repo
(`/etc/fstab`, `/etc/cockpit/cockpit.conf`, netplan).

`restic` or `borgbackup` to an external USB disk would close that gap and handles
dedup, encryption, and incrementals from one tool.

### 3. Drive health

One NVMe carrying everything makes SMART worth watching:

```bash
sudo apt install smartmontools
sudo smartctl -a /dev/nvme0n1     # Percentage Used, Media Errors
```

The 970 EVO Plus 2TB is rated 1200 TBW, which a photo library will not come near.
A continuously-writing NVR would — worth a baseline reading now so there is
something to compare against if one is ever added back.

Beszel can chart and alert on both numbers rather than leaving them to be
remembered; it needs two commented blocks uncommented and a broad capability
granted, which is a decision in itself. See
[beszel.md](beszel.md#smart-if-you-want-it). Disk *usage* on both volumes —
the thing that hit 92% — is already covered by the same stack with no extra
privileges, see [beszel.md](beszel.md#the-second-disk).

### 4. Unattended security updates

```bash
sudo apt install unattended-upgrades
sudo dpkg-reconfigure --priority=low unattended-upgrades
```

### 5. Snapshots before risky changes

This is what the 463GiB reserve is for:

```bash
sudo lvcreate -s -L 20G -n root-snap /dev/ubuntu-vg/ubuntu-lv
# roll back:  sudo lvconvert --merge /dev/ubuntu-vg/root-snap && sudo reboot
# discard:    sudo lvremove /dev/ubuntu-vg/root-snap
```

Snapshots fill as the origin diverges. Delete them once a change is confirmed good —
a full snapshot goes invalid and is dropped.

---

## Host state lives outside this repo

`/etc/fstab`, the LVM layout, `/etc/cockpit/cockpit.conf`, and the NetworkManager
mask from [cockpit.md](cockpit.md) are all host configuration. `bootstrap.sh` covers
the host setup that is scriptable; none of the above is in it yet. On a rebuild these
are reapplied from these docs by hand, which is fine only as long as the docs stay
current — the same rule as README rule 1, one level down.

Cockpit's Storage page (`cockpit-storaged`, plus `udisks2-lvm2`) is now the GUI view
of all of this. See [cockpit.md](cockpit.md).
