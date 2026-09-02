# Ollama punchlist

Ordered set of things to do to get local models running, with the commands to do
them. Written 2026-09-01, with the stack committed but never deployed. Delete
this file once it's all ticked — it's a working list, not reference material.

Detail lives in [ollama.md](ollama.md).

**Three hard ordering constraints:**

1. **Caddy must be recreated, not reloaded**, after step 4, or the two new
   hostnames return a closed connection while everything else keeps working.
2. **`nomic-embed-text` must exist before you upload a document** (step 6).
   Without it the upload fails at the embedding step, and the error names a
   model rather than saying "you skipped a step".
3. **Create your own account first** (step 7). The first account to sign up
   becomes the admin, and there is no other way into the UI.

---

## 0. Commit and push from your PC

Nothing below works on forge until this lands.

```powershell
cd $HOME\Claude\Projects\"Podman Home Containers"
git add -A
git commit -m "ollama + open webui, third tenant on the 3080"
git push
```

- [ ] Pushed.

---

## 1. Baseline the card before you add anything to it

Do this **first**, and write the numbers down. Everything in
[ollama.md#the-vram-budget](ollama.md#the-vram-budget) is an estimate until you
have your own numbers, and after this stack is running you can no longer measure
what Frigate and Immich use on their own.

```bash
ssh forge
nvidia-smi --query-gpu=memory.total,memory.used,memory.free --format=csv
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

- [ ] Total, used and free recorded with the box **idle**.
- [ ] Per-process figures recorded — you should see Frigate, and Immich only if
      it happens to be working.
- [ ] Repeat the second command once **during** an Immich import if you can
      trigger one. That is the number that decides whether a 7.6GB model is ever
      viable here.

**Free minus about 1GB of slack is your model budget.** If it is under 5GB with
the box idle, stop and re-read the budget section before pulling anything —
something is holding more than expected.

---

## 2. Pull and bootstrap

```bash
cd ~/home-containers && git pull
./bootstrap.sh
```

- [ ] `bootstrap.sh` reports `directory /srv/ollama` and
      `directory /srv/openwebui`.

Expect no warnings from this stack. Unlike Frigate, nothing has to be built
before first start.

---

## 3. Secrets

Two keys, one path. `DOMAIN` is duplicated from `/caddy` because `deploy.sh`
reads one Infisical path per stack — the same duplication `/beszel` and
`/homelable` already have.

```bash
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/ollama \
  WEBUI_SECRET_KEY="$(openssl rand -hex 32)" \
  DOMAIN=brent-miles.com
```

- [ ] Both keys set.
- [ ] `./scripts/deploy.sh --required-vars ollama` prints
      `WEBUI_SECRET_KEY DOMAIN`.

Do not skip `WEBUI_SECRET_KEY` on the grounds that Open WebUI starts without it.
It does start — it generates a key into `.webui_secret_key` inside the data
directory, which is a credential Infisical cannot restore and nothing records.

---

## 4. Deploy, and recreate Caddy

```bash
./scripts/deploy.sh ollama
```

- [ ] `docker compose ps` shows `ollama` and `open-webui`.
- [ ] Both reach `(healthy)`. **Open WebUI takes up to three minutes on first
      start** — it builds its database and initialises the RAG components on a
      cold volume, and its `start_period` is set to 180s for exactly this. A
      container sitting in `(health: starting)` for two minutes is normal here
      and is not normal anywhere else in this repo.

Then Caddy. After a `git pull` the reload is a lie — the Caddyfile is a
single-file bind mount and git replaces files by rename, so the container keeps
reading the old inode:

```bash
docker exec caddy grep -c openwebui /etc/caddy/Caddyfile   # 0 means stale
./scripts/deploy.sh caddy -- --force-recreate
docker exec caddy grep -c openwebui /etc/caddy/Caddyfile   # now non-zero
```

- [ ] Grep returns non-zero after the recreate.

---

## 5. Pull the two models that matter

The embedding model is not optional — document search does not work without it,
and it is the cheapest thing in this stack at 274MB.

```bash
docker exec ollama ollama pull nomic-embed-text
docker exec ollama ollama pull qwen3.5:9b
docker exec ollama ollama list
```

- [ ] Both listed.
- [ ] `du -sh /srv/ollama` — sanity check on where the disk went.

`qwen3.5:9b` is a starting point, not a recommendation to keep. Trying others is
the whole point; see [ollama.md#picking-one](ollama.md#picking-one) for what fits
the budget.

---

## 6. First login — your account, before anyone else's

Open `https://ai.brent-miles.com` **from a machine on the LAN**.

- [ ] The page loads. If it returns a closed connection, go back to step 4 —
      that is the stale-Caddyfile symptom, not a broken app.
- [ ] Sign up. **This first account becomes the admin.** Use yours.
- [ ] The model picker lists `qwen3.5:9b`. An empty picker means Open WebUI
      enumerated models before Ollama was ready — `docker restart open-webui`
      and it repopulates.
- [ ] Send one message and get an answer.

Leave signup enabled. Everyone after you lands in a pending queue and can do
nothing until you approve them in **Admin Panel → Users**. Turning signup off
before an admin exists locks you out of a UI with no other way in — the same
shape of mistake as Homelable's password hash, with the same absence of a
recovery path.

- [ ] Family accounts created and approved, or deferred deliberately.

---

## 7. Prove the VRAM budget rather than assuming it

This is the step that decides whether the whole arrangement is sound, and it
takes two minutes.

Send a message, and **while it is answering**, in another terminal:

```bash
docker exec ollama ollama ps
nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv
```

- [ ] `ollama ps` shows the model at **100% GPU**. Any CPU percentage means the
      model, the context length, or Immich has pushed you over budget — the
      cause and the fix are in
      [ollama.md#the-vram-budget](ollama.md#the-vram-budget).
- [ ] Frigate is still detecting. Open `https://security.brent-miles.com` and
      confirm inference times look normal.

Then wait five minutes without sending anything:

```bash
docker exec ollama ollama ps      # should be empty
nvidia-smi --query-gpu=memory.free --format=csv
```

- [ ] The model has unloaded and free VRAM is back near your step 1 baseline.
      **This is the behaviour the whole design rests on.** If it does not
      unload, `OLLAMA_KEEP_ALIVE` is not taking effect and Frigate is now
      sharing the card with a permanent tenant.

---

## 8. Turn on document search

```bash
docker exec ollama ollama pull nomic-embed-text   # already done in step 5
```

In the UI: **Workspace → Knowledge**, create a collection, upload a document,
then ask a question about it in a chat with that collection attached.

- [ ] A document uploads without an error naming an embedding model.
- [ ] A question about its contents gets an answer that is actually from the
      document.

If uploads fail, check `RAG_EMBEDDING_ENGINE` resolved to `ollama`:

```bash
docker exec open-webui printenv RAG_EMBEDDING_ENGINE RAG_EMBEDDING_MODEL
```

This is where the stack earns its place. A 9B model asked a question from its own
weights will produce confident, wrong specifics; the same model handed the
document is doing a task it is genuinely good at.

---

## 9. Confirm the LAN guard is doing its job

Two checks, and the second one is the interesting one.

**From your PC on the LAN** — should work:

```powershell
curl.exe -s https://llm.brent-miles.com/api/tags
```

- [ ] Returns JSON listing your models.

**From inside a container** — should be refused. Caddy's `@notlocal` guard
deliberately excludes Docker's own `172.16.0.0/12` range, so a container asking
for a LAN hostname gets the connection aborted. This is the check that proves it:

```bash
docker exec open-webui python3 -c "import urllib.request; urllib.request.urlopen('https://llm.brent-miles.com/api/tags', timeout=5)"
```

- [ ] **Fails.** A success here means the guard has a hole in it and every
      LAN-only hostname in the house — Frigate included — is reachable from any
      container on the proxy network.

Remember this when wiring Home Assistant later: HA is a container, so it must
use `http://ollama:11434` over the proxy network, never the hostname.

---

## 10. Loose ends

- [ ] **Exclude `/srv/ollama` from backups** when a backup job for `/srv` exists.
      It is re-downloadable and it grows every time you try a model. Recorded in
      [decisions.md](decisions.md#models-are-content-not-configuration) and on
      the "Still open" list there.
- [ ] **Include `/srv/openwebui`** in the same job. Accounts, every conversation,
      uploaded documents and the index built from them exist nowhere else.
- [ ] **Beszel already charts the GPU** — no work needed, but its VRAM graph is
      now the fastest way to see this stack misbehaving.

---

## 11. Optional: the Claude Desktop experiment

Do this last and treat a failure as expected rather than as a problem to solve.

Ollama 0.33 added a local Anthropic-API proxy that its desktop app uses to point
Claude Desktop at local models. The documented flow configures Claude Desktop on
**the same machine**, and it launched on Mac first. The models here are on forge,
and the desktops are Windows — two unknowns stacked.

- [ ] Install the Ollama app on a Windows desktop.
- [ ] Set `OLLAMA_HOST` to `http://10.0.0.4:11434` and see whether the app —
      and then its Claude integration — follows it to forge.
- [ ] If it works, record how in [ollama.md](ollama.md#claude-desktop). If it
      does not, stop; nothing in this stack depends on it.

Worth remembering either way that pointing Claude Desktop at a 9B model is a
large downgrade in capability. The reasons to do it are privacy and offline, not
quality.
