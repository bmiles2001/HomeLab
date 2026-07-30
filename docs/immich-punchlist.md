# Immich punchlist

What's left to call Immich done. Written 2026-07-29, with the server up and
validated. Delete this file once it's all ticked — it's a working list, not
reference material.

Detail lives in [immich-deploy.md](immich-deploy.md) and
[onedrive-mirror.md](onedrive-mirror.md); this is the ordered set of things still
to do and the commands to do them.

**One hard ordering constraint:** the storage template (step 2) must be settled
*before* the first mirror upload (step 5). Change it afterwards and every file in
the library gets a new path, which the mirror then has to chase.

---

## 0. Commit what's on your PC

Three files are modified locally and not pushed. Nothing below works on forge
until they are.

```powershell
cd $HOME\Claude\Projects\"Podman Home Containers"
git add -A
git commit -m "onedrive mirror: safety guards, rename strategy, deletion docs"
git push
```

---

## 1. Find out which of these you already did

You said Immich validates clean, but several of these are easy to have skipped.
Run the block and read the output — it tells you which steps below to skip.

```bash
ssh forge
cd ~/home-containers && git pull

echo "--- version actually running ---"
docker exec immich_server cat /build/package.json 2>/dev/null | grep '"version"' \
  || docker logs immich_server 2>&1 | grep -i "listening on" | tail -1

echo "--- is admin signup still open? (want: false) ---"
docker exec immich_server printenv IMMICH_ALLOW_SETUP

echo "--- storage template in use? (want: 2026/2026-07/ dirs, not UUIDs) ---"
sudo ls /srv/immich/data/library/*/ 2>/dev/null | head -5

echo "--- how many users? ---"
docker exec immich_postgres psql -U postgres -d immich -tAc \
  'select email, "isAdmin" from users order by "createdAt";' 2>/dev/null

echo "--- immich's own scheduled DB backups landing? ---"
sudo ls -la /srv/immich/data/backups/ 2>/dev/null | tail -5

echo "--- infisical backup timer (README claims this covers your secrets) ---"
systemctl list-timers 'infisical*' --all 2>/dev/null | head -3

echo "--- rclone configured for root yet? ---"
sudo rclone listremotes 2>/dev/null || echo "rclone not installed"
```

---

## 2. Close the admin signup hole

Skip if step 1 printed `false`.

Immich hands admin to whoever loads the site first. Harmless behind a closed
router; a live vulnerability the day you forward 443.

```bash
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/immich \
  IMMICH_ALLOW_SETUP=false
./scripts/deploy.sh immich
docker exec immich_server printenv IMMICH_ALLOW_SETUP   # must say false
```

---

## 3. Settle the storage template — before any mirroring

Skip if step 1 showed `2026/2026-07/`-shaped directories rather than UUIDs.

**Administration → Settings → Storage Template**, enable, and set:

```
{{y}}/{{y}}-{{MM}}/{{filename}}
```

If the library already has files under the old layout, run
**Administration → Jobs → Storage Template Migration** and let it finish before
moving on. Confirm:

```bash
sudo ls /srv/immich/data/library/*/ | head
```

While you're in the admin UI, also enable **Settings → Backup** (scheduled
database backups) if step 1 found `backups/` empty.

---

## 4. Set up rclone against OneDrive

Full walkthrough with every prompt: [onedrive-mirror.md](onedrive-mirror.md) §1–3.
The parts that bite:

- Configure as **root** (`sudo rclone config`) — the systemd unit sets
  `HOME=/root`. Configure it as `netto` and it works by hand and fails nightly.
- Answer **`n`** to "use web browser to authenticate", then run the
  `rclone authorize "onedrive"` command it gives you **on your Windows PC** and
  paste the JSON back.

```bash
sudo -v ; curl https://rclone.org/install.sh | sudo bash
sudo rclone config          # see onedrive-mirror.md §2 for the answers
sudo rclone about onedrive: # must show ~1TiB total
sudo rclone mkdir onedrive:Immich
sudo rclone mkdir onedrive:Immich-deleted
```

**Then, on every Windows PC in the house:** OneDrive tray icon → Settings →
Account → Choose folders → untick `Immich` and `Immich-deleted`. Do this now,
while those folders are empty. Skip it and the desktop client starts pulling the
whole library onto your desktop.

---

## 5. Dry run, then the first real upload

```bash
sudo install -m 755 scripts/immich-onedrive-sync.sh /usr/local/bin/
sudo /usr/local/bin/immich-onedrive-sync.sh --dry-run
```

Check the dry run for: plausible size lines, files it would **copy**, nothing
under `library/` it would **delete**, and no `--track-renames ignored` warning.

Then the first real run by hand — not via the timer, which gives up after 6h:

```bash
sudo apt install -y tmux
tmux new -s mirror
sudo /usr/local/bin/immich-onedrive-sync.sh
# Ctrl-B D to detach; tmux attach -t mirror to return
tail -f /var/log/immich-onedrive-sync.log
```

---

## 6. Enable the nightly timer

Only after step 5 finished successfully.

```bash
sudo cp scripts/immich-onedrive-sync.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now immich-onedrive-sync.timer
systemctl list-timers immich-onedrive-sync.timer
```

Check it again tomorrow:

```bash
systemctl status immich-onedrive-sync.service
journalctl -u immich-onedrive-sync.service --since yesterday
```

---

## 7. Verify you have a backup, rather than assuming

```bash
sudo rclone check /srv/immich/data/library onedrive:Immich/library \
  --size-only --one-way --exclude '/thumbs/**' --exclude '/encoded-video/**'
sudo rclone lsf onedrive:Immich/library/admin/ | head
sudo rclone lsl onedrive:Immich/backups/
```

Then open the OneDrive app on your phone and look at an actual photo.

---

## 8. Test the restore — the only step that proves anything

Do this **while the library is small**. Everything above is a hypothesis until
this passes.

```bash
sudo mkdir -p /srv/restore-test
sudo rclone copy onedrive:Immich /srv/restore-test --progress
gunzip -c /srv/restore-test/backups/manual-dump-*.sql.gz | head -50   # sanity check it's real SQL
```

Then bring up a throwaway Immich against that data, load the dump, and confirm
an album you created still exists. Procedure in
[onedrive-mirror.md](onedrive-mirror.md) §8.

---

## 9. The family

Do one phone completely before touching the other two.

1. Immich from the App Store → server `https://photos.brent-miles.com`
2. **iOS Settings → Immich → Background App Refresh: ON** — backup silently
   never runs without it, with no warning
3. Backup screen (cloud icon) → select albums → Enable Backup
4. Take a photo, watch it appear in the web UI, confirm it lands in the right
   folder on disk

Everyone needs iOS 15+ — v3.1.0 dropped iOS 14.

Create their accounts under **Administration → Users** first if step 1 showed
only yours.

---

## Then Immich is done

What's left after this belongs to other sessions, in risk order:

1. **Public 443** — forward the port, CrowdSec on Caddy's logs, and set
   `IMMICH_TRUSTED_PROXIES` or Immich's rate limiting sees only Caddy's address.
2. **Komodo** — the stated precondition (Immich working) is now met.
3. **Frigate** — its stack exists in the repo but has never been deployed, and
   its image pin is unverified.
