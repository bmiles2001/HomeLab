# The OneDrive mirror

Offsite copy of the photo library. Written 2026-07-29, after Immich went live.

Target: **Microsoft 365 Personal/Family OneDrive, 1TB, unencrypted.** Readable
directly in the OneDrive app, which is the whole reason the Immich storage
template is set the way it is.

This closes the largest open risk in the build. Until it runs, every family
photo exists on exactly one NVMe in one house.

---

## What this is and isn't

A **one-way push**. Immich is the source of truth; OneDrive is a copy.

- Editing or deleting a file *in OneDrive* does nothing to Immich, and gets
  undone on the next run.
- Deleting a photo *in Immich* eventually removes it from OneDrive too — this is
  a mirror, not an archive. It takes about 90 days and passes through three
  holding areas on the way. See the next section, because the short version is
  misleading in both directions.
- `thumbs/` and `encoded-video/` are skipped. Immich regenerates both from
  originals, and syncing them can double your storage use for zero recovery
  value.

It is **not** a versioned backup and **not** protection against ransomware that
has your OneDrive credentials. It is protection against the NVMe dying, the
house burning down, and `rm -rf` on the wrong path.

---

## What actually happens when you delete a photo

Worth reading once, because "it's a mirror, so deletions propagate" and
"deletions are safe for 30 days" are both too simple, and the real answer is
what makes pruning usable.

Delete a photo in Immich and it passes through **four** stages:

| Stage | Where the file is | How long | Reclaims space? |
|---|---|---|---|
| 1 | Immich trash — still on the NVMe, still in OneDrive | 30 days (Immich default, configurable) | no |
| 2 | Immich empties trash; next nightly run moves the OneDrive copy to `Immich-deleted/<date>/` | until stage 3 | frees the NVMe, not OneDrive |
| 3 | `Immich-deleted/<date>/` on OneDrive | `DELETED_RETAIN_DAYS`, default 30 | no |
| 4 | OneDrive's own recycle bin, after the script purges stage 3 | 30 days | **no** |

Roughly **90 days end to end**, with three separate chances to change your mind.

Two consequences that aren't obvious:

**rclone cannot permanently delete from OneDrive Personal.** Microsoft exposes
no permanent-delete API for consumer accounts, so everything the prune step
removes lands in the recycle bin and stays there. `--onedrive-hard-delete`
exists but only works for Business/SharePoint. There is no way to automate
stage 4.

**The OneDrive recycle bin counts against your 1TB.** So pruning photos in
Immich to reclaim offsite space does work — that's the point of a mirror rather
than an archive — but the space doesn't come back for about 90 days. If you're
pruning *because* you're near the quota, that's too slow to help. Empty the
recycle bin yourself at <https://onedrive.com> → Recycle bin → Empty, and the
space returns immediately.

If you'd rather have a longer safety margin, `DELETED_RETAIN_DAYS` is the one
knob — it only affects stage 3:

```bash
sudo systemctl edit immich-onedrive-sync.service
# [Service]
# Environment=DELETED_RETAIN_DAYS=180
```

---

## Read this before you start

**Turn off OneDrive desktop sync for this folder, on every Windows PC in the
house, before the first upload.** Otherwise the moment `Immich/` appears in your
OneDrive, the desktop client starts pulling hundreds of gigabytes of photos down
onto your desktop — filling that disk and saturating your upload while it
fights the sync going the other way.

On each PC: OneDrive tray icon → Settings → Account → **Choose folders** →
untick `Immich` and `Immich-deleted`. Do it after the first run creates the
folders, or create them yourself first (step 3) so you can untick them ahead of
time. This is the single most annoying mistake available here.

**The 1TB ceiling is shared** with everything else in that OneDrive. Step 4's
first line of output tells you where you stand; the script warns at 85% and the
whole mirror simply stops working when the quota fills. It will still log
success-looking lines up until it doesn't, which is why the quota check exists.

---

## 1. Install rclone on forge

```bash
ssh forge
sudo -v ; curl https://rclone.org/install.sh | sudo bash
rclone version
```

---

## 2. Authorise OneDrive — the headless dance

Forge has no browser, and OneDrive's OAuth flow needs one. rclone handles this
by having you run one command on a machine that *does* have a browser and paste
the result back.

**Run `rclone config` as root, not as `netto`.** The systemd unit sets
`HOME=/root`, so it reads `/root/.config/rclone/rclone.conf`. Configure it as
`netto` and the nightly timer will report an unreachable remote while it works
perfectly by hand — an unpleasant hour to debug.

### On forge

```bash
sudo rclone config
```

Answer:

| Prompt | Answer |
|---|---|
| `n) New remote` | `n` |
| `name>` | `onedrive` |
| `Storage>` | `onedrive` |
| `client_id>` | *(blank)* |
| `client_secret>` | *(blank)* |
| `Edit advanced config?` | `n` |
| `Use web browser to automatically authenticate?` | **`n`** |

It now prints a command to run elsewhere, something like:

```
rclone authorize "onedrive" "eyJ..."
```

### On your Windows PC

Install rclone (download the zip from <https://rclone.org/downloads/>, or
`winget install Rclone.Rclone`), then run **that exact command, copied
verbatim** — the base64 blob matters. A browser opens, you sign in to the
Microsoft account that owns the 1TB, and it prints a JSON token.

### Back on forge

Paste the whole JSON blob at the `config_token>` prompt. Then:

| Prompt | Answer |
|---|---|
| `Your choice> ` (drive type) | `1` — *OneDrive Personal or Business* |
| `Found drive 'root' of type 'personal' ... Is that okay?` | `y` |
| `Keep this "onedrive" remote?` | `y` |
| | `q` to quit |

Verify — as root, because that's whose config you just wrote:

```bash
sudo rclone about onedrive:
sudo rclone lsd onedrive:
```

`about` must print a Total around 1TiB. If it errors here, nothing downstream
will work.

---

## 3. Pre-create the folders so you can exclude them

```bash
sudo rclone mkdir onedrive:Immich
sudo rclone mkdir onedrive:Immich-deleted
```

Now go do the **Choose folders** step from the warning above on each Windows PC,
before there's anything in them worth downloading.

---

## 4. Dry run, and read it properly

```bash
cd ~/home-containers && git pull
sudo install -m 755 scripts/immich-onedrive-sync.sh /usr/local/bin/
sudo /usr/local/bin/immich-onedrive-sync.sh --dry-run
```

A dry run skips the database dump and the pruning, and asks rclone to report
without transferring. What you're checking:

- The `onedrive:` and `local:` size lines are both plausible, and local fits
  inside the OneDrive free space with room to spare.
- rclone lists files it would **copy**, and lists **nothing under
  `library/` that it would delete**. Deletions on a first run mean the
  destination has content that shouldn't be there.
- No `--track-renames ignored` warning. If you see one, you're on a stale
  commit — the fix is in `git pull`.

---

## 5. First real run — not via the timer

The first upload moves your entire library and can run for many hours. The timer
gives up after 6h (`TimeoutStartSec`), so do the first one by hand, in a
detached session that survives your laptop closing:

```bash
sudo apt install -y tmux
tmux new -s mirror
sudo /usr/local/bin/immich-onedrive-sync.sh
```

`Ctrl-B D` to detach, `tmux attach -t mirror` to come back. Watch progress:

```bash
tail -f /var/log/immich-onedrive-sync.log
```

Expect throttling. `--tpslimit 10` and `--transfers 4` are set deliberately low
because OneDrive Personal rate-limits aggressively and rclone retrying into a
429 wall is slower than going gently in the first place. Don't raise them to
speed up the first run; you'll finish later, not sooner.

---

## 6. Enable the nightly timer

Only after a successful manual run:

```bash
sudo cp scripts/immich-onedrive-sync.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now immich-onedrive-sync.timer
systemctl list-timers immich-onedrive-sync.timer
```

02:30 nightly with up to 30m of jitter, `Persistent=true` so a missed run
happens when the box comes back. The script takes a lock, so a long run
overlapping the next trigger is refused rather than allowed to collide.

Check it after the first automatic run:

```bash
systemctl status immich-onedrive-sync.service
journalctl -u immich-onedrive-sync.service --since yesterday
```

---

## 7. Verify you actually have a backup

A backup nobody has verified is a hypothesis. Four checks:

```bash
# 1. Both sides agree on file count and size, for one month's folder.
sudo rclone check /srv/immich/data/library onedrive:Immich/library \
  --size-only --one-way --exclude '/thumbs/**' --exclude '/encoded-video/**'

# 2. The structure is human-readable, which was the point of the template.
sudo rclone lsf onedrive:Immich/library/admin/ | head

# 3. A database dump is present and recent.
sudo rclone lsl onedrive:Immich/backups/

# 4. Open the OneDrive app on your phone and look at a photo.
```

`rclone check --size-only` is the right check here rather than a full hash
comparison: local and OneDrive share no hash algorithm, so a hash check would
have to re-download everything.

---

## 8. Test the restore, now, while it's small

**This is the step everyone skips and it's the only one that proves anything.**

The OneDrive copy gives you back your *files*. Albums, faces, shared links and
users live in Postgres. A real restore is three moves:

```bash
# On a throwaway location - do NOT point this at the live library.
mkdir -p /srv/restore-test
sudo rclone copy onedrive:Immich /srv/restore-test --progress

# Bring up a second Immich against it, then load the newest dump:
gunzip -c /srv/restore-test/backups/manual-dump-YYYYMMDD.sql.gz \
  | docker exec -i immich_postgres psql -U postgres -d immich
```

Then check that an album you made survived. If it didn't, you've learned that
now rather than in the worst week of your life.

Immich's own guidance is worth reading once:
<https://docs.immich.app/administration/backup-and-restore>

---

## The failure modes, and what they look like

| Symptom | Cause | Fix |
|---|---|---|
| `remote 'onedrive' unreachable` after months of working | OneDrive refresh tokens expire after 90 days of disuse; also revoked on password change | `sudo rclone config reconnect onedrive:` |
| Works by hand, fails from the timer | rclone config in `/home/netto`, unit reads `/root` | reconfigure with `sudo rclone config` |
| `--max-delete` aborted the run | source lost files, or `UPLOAD_LOCATION` is wrong | **investigate before raising the limit** — this guard is the whole point |
| Transfers crawl, log full of 429 | OneDrive throttling | leave it; lower `--tpslimit` if persistent |
| `can't have two files with the same name` | OneDrive is case-insensitive; Immich produced `IMG_1.HEIC` and `img_1.heic` | rename one in Immich |
| Quota warnings in the log | 1TB filling up | prune in Immich, **then empty OneDrive's recycle bin by hand** — pruning alone takes ~90 days to free space |
| Pruned a lot in Immich, OneDrive usage unchanged | deleted files are still in one of the four holding stages, all of which count against quota | wait, or empty the recycle bin at onedrive.com |
| Desktop PC disk filling up | OneDrive desktop client syncing `Immich/` down | Choose folders → untick it |

---

## When 1TB isn't enough

It will happen eventually. In rough order of preference:

0. **Empty the OneDrive recycle bin.** Do this first and for free — it may be
   holding months of pruned photos that still count against the 1TB.
1. **Stop mirroring `backups/`** and keep database dumps somewhere separate.
   Small win, no risk.
2. **Backblaze B2 instead**, at roughly $6/TB/month. rclone speaks it natively,
   so the script needs one variable changed. No 1TB ceiling and no desktop
   client trying to sync it down.
3. **Both** — OneDrive for the recent years you want browsable on your phone,
   B2 for the full archive. This is the 3-2-1 shape and the honest answer.

Don't solve it by dropping originals from the mirror. Derived data is
regenerable; originals are the thing you're protecting.

---

## Sources

- [rclone — Microsoft OneDrive](https://rclone.org/onedrive/)
- [rclone — remote setup for headless machines](https://rclone.org/remote_setup/)
- [Immich — Backup and restore](https://docs.immich.app/administration/backup-and-restore)
