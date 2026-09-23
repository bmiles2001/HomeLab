# Valheim punchlist

Ordered steps to get `stacks/valheim` running and a friend joined. Tick them off
and delete this file when done. Roughly 20 minutes, most of it waiting.

Image: [community-valheim-tools/valheim-server-docker](https://github.com/community-valheim-tools/valheim-server-docker) ·
why it publishes ports: [decisions.md](decisions.md#valheim-publishes-ports-for-the-same-reason)

---

## 0. Commit and push (on your PC)

- [ ] Committed and pushed from the PC.

The Ollama removal (`03c1d27`) is already in `main`. If Ollama is still running
on forge, stop it **before** `git pull` - the pull deletes the compose file:

```bash
cd ~/home-containers/stacks/ollama && docker compose down
```

Already pulled? Then remove the orphans by name instead:
`docker rm -f ollama open-webui`.

## 1. Pull and bootstrap (forge)

```bash
cd ~/home-containers && git pull
./bootstrap.sh
```

- [ ] bootstrap reports `directory /srv/valheim/config` and `/srv/valheim/server`.

## 2. Password into Infisical

At least 5 characters, and it must **not** contain the server name (`forge`) -
the server refuses to start otherwise.

```bash
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/valheim \
  SERVER_PASS='pick-something'
./scripts/deploy.sh --required-vars valheim     # prints SERVER_PASS
```

- [ ] Secret set.

Optional, same path: `VALHEIM_SERVER_NAME`, `VALHEIM_WORLD_NAME`, and
`VALHEIM_ADMINLIST_IDS` (your SteamID64 - makes you admin for kick/ban).

## 3. Deploy and watch it come up

```bash
./scripts/deploy.sh valheim
docker logs -f valheim
```

First start downloads ~1GB through SteamCMD, then generates the world. Wait
for `Game server connected` in the log, then Ctrl-C.

- [ ] `Game server connected` appears.

## 4. Open the firewall (forge)

`ufw-docker`, not plain `ufw` - Docker's rules sit ahead of UFW's.

```bash
sudo ufw-docker allow valheim 2456/udp
sudo ufw-docker allow valheim 2457/udp
```

- [ ] Both rules in `sudo ufw status numbered`.

## 5. Forward on the router

**2456-2457 UDP → 10.0.0.4**, same ports in and out. UDP only; no TCP needed.

- [ ] Forward saved.

## 6. You join first (from the house)

Valheim → Join Game → **Join IP** → `10.0.0.4:2456` → password.

Use the LAN address, not the public one - most routers don't loop the public
address back inside the house, so it fails from here while working for everyone
outside.

- [ ] You're in, character loaded.

## 7. Your friend joins

Get the public address from forge:

```bash
curl -s https://ifconfig.me; echo
```

Send him `<that IP>:2456` and the password. He uses the same **Join IP** button.

Worth trying while you're both online: right-click you in his Steam friends list
→ **Join Game**. If Steam offers it, it takes him straight to the password
prompt. If it does nothing, Join IP is the reliable path.

- [ ] Friend is in.

If he can't connect: check steps 4 and 5 first (that's almost always it), then
confirm the public IP hasn't changed.

## 8. Confirm backups (next hour)

```bash
ls -la /srv/valheim/config/backups
```

- [ ] A zip appears at five past the hour.

---

Done. Delete this file and commit.
