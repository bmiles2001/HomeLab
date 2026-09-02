# Ollama

Local language models on `forge`, with a chat UI in front of them.

`https://ai.brent-miles.com` — the UI. LAN only.
`https://llm.brent-miles.com` — the raw API, **unauthenticated**. LAN only.

| Container | Network | Publishes | Job |
|---|---|---|---|
| `ollama` | `proxy` | nothing | runs the models, serves the API |
| `open-webui` | `proxy` | nothing | chat UI, accounts, document search |

Everything runs on the RTX 3080, alongside Frigate and Immich.

---

## What this is for, and what it is not

The reason to run a model here rather than use a hosted one is not quality — it
is that nothing leaves the house, it works when the internet does not, and there
is no meter running. A 9B model is a useful assistant for drafting, summarising,
explaining code and answering questions about documents you give it. It is not
in the same class as a frontier model and no amount of configuration in this
stack will make it one.

The place it earns its keep hardest is **document search**. A small model asked a
question from its own weights will produce confident, wrong specifics — that is
the characteristic failure of this size class, and it does not announce itself.
The same model handed the actual document and asked to read it is doing a task it
is genuinely good at. Upload the source; do not trust the recall.

---

## The VRAM budget

This is the only hard part of the stack, and everything else follows from it.

The card has 10GB. Two things were already on it before this stack existed:

- **Frigate's detector**, resident permanently — it is a live NVR and it never
  stops.
- **Immich's ML**, in bursts, during imports.

Both of those share *compute*, and CUDA time-slices compute — which is what
`decisions.md#amendment-frigate-moves-to-the-3080` accepted when it put them on
one card. A language model is a different shape of tenant: it wants **memory**
allocated up front, and memory does not time-slice.

Measure the real numbers rather than trusting these; `nvidia-smi` on the host, or
Beszel's GPU chart, will tell you what Frigate and Immich actually hold. As a
starting estimate:

| | VRAM |
|---|---|
| Card | 10240 MB |
| Frigate detector, always | ~1–2 GB |
| Immich ML, during imports | ~1–2 GB |
| **Left for a model** | **~6–7 GB idle, ~4–5 GB mid-import** |

Which sets the ceiling on what you can run:

| Model size at Q4_K_M | Verdict |
|---|---|
| under ~5 GB | fits in the bad case as well as the good one |
| ~6–7 GB | fits while Immich is idle; may spill during a large import |
| ~7.6 GB | import-dependent, and tight even when idle |
| above ~8 GB | will not fit — do not bother |

**The failure mode is gentle and silent.** Ollama does not evict Frigate and does
not crash. It offloads layers to the CPU and gets very slow. So on this box,
"the chat got slow" is the symptom of a VRAM problem, and this is what confirms
it:

```bash
docker exec ollama ollama ps
```

`100% GPU` is what you want. Any CPU percentage means you have exceeded the
budget — because of the model, the context length, or Immich being busy at that
moment.

### The four settings that bound it

All in `stacks/ollama/compose.yml`, all overridable from Infisical:

- `OLLAMA_MAX_LOADED_MODELS=1` — upstream's default is **3 per GPU**, which on
  this card is 15GB of intent against 10GB of hardware.
- `OLLAMA_NUM_PARALLEL=1` — raising it multiplies the KV cache by the number of
  slots.
- `OLLAMA_KEEP_ALIVE=5m` — the model releases its VRAM five minutes after the
  last message and Frigate gets the card back. The cost is a few seconds of cold
  start on the next one. This is what makes the whole arrangement acceptable.
- `OLLAMA_KV_CACHE_TYPE=q8_0` — halves what the context window costs, for a
  quality difference that is not noticeable. Global, with no per-model override,
  and it falls back to `f16` on unsupported architectures **without saying so**.

### The context-length trap

Ollama picks its default context window from available VRAM, and under 23GB it
picks **4k tokens**. That is fine for chat and too small to hand a model a
document — so this stack sets `OLLAMA_CONTEXT_LENGTH=8192`.

The catch is that the KV cache grows with the context window and comes out of the
same 6–7GB the weights are competing for. **A model that fits perfectly at 4k can
spill to CPU at 32k**, with no error printed anywhere. If you raise it for a
document-heavy task, raise it in steps and check `ollama ps` after each one.

---

## First deploy

```bash
cd ~/home-containers
git pull
./bootstrap.sh                 # creates /srv/ollama and /srv/openwebui
```

Add to Infisical under `/ollama`:

| Key | Value |
|---|---|
| `WEBUI_SECRET_KEY` | any long random string — `openssl rand -hex 32` |
| `DOMAIN` | `brent-miles.com`, the same as `/caddy` |

Then:

```bash
./scripts/deploy.sh ollama
```

Reload Caddy so the two new hostnames resolve. After a `git pull` this needs a
recreate rather than a reload — the Caddyfile is a single-file bind mount and
git replaces files by rename, so the container keeps reading the old inode
(`decisions.md#single-file-bind-mounts-need-a-recreate-not-a-reload`):

```bash
docker exec caddy grep -c openwebui /etc/caddy/Caddyfile   # 0 after a pull?
./scripts/deploy.sh caddy -- --force-recreate
```

**Pull the embedding model before anything else.** Document upload fails at the
embedding step without it, with an error that names the model:

```bash
docker exec ollama ollama pull nomic-embed-text
```

Then a chat model — this one fits comfortably and is a reasonable first try:

```bash
docker exec ollama ollama pull qwen3.5:9b
```

Now open `https://ai.brent-miles.com`. **The first account created becomes the
admin**, so make it yours before anyone else opens the page. Everyone after that
lands in a pending queue until you approve them in Admin Panel → Users.

Leave signup enabled until the house has accounts. Turning it off from the UI is
safe; setting `ENABLE_SIGNUP=false` before an admin exists locks you out of an
interface with no other way in — the same shape of mistake as Homelable's
password hash, and with the same lack of a recovery path.

---

## Models

**Models are not in this repo, and that is deliberate.** They are pulled at
runtime into `/srv/ollama`. They are content in a data volume — the same category
as the photo library and the camera clips — not configuration. What the repo
reproduces is the environment; which weights happen to be sitting in it is not
something git needs to know.

Add one:

```bash
docker exec ollama ollama pull <model>
```

It appears in Open WebUI's picker immediately. Admins can also pull from
Admin Panel → Settings → Models without touching a shell.

List what is there, with sizes, and remove one:

```bash
docker exec ollama ollama list
docker exec ollama ollama rm <model>
du -sh /srv/ollama
```

### Picking one

The constraint is per-model, not cumulative. With `OLLAMA_MAX_LOADED_MODELS=1`
only one is resident at a time, so **the number of models installed is irrelevant
to Frigate** — a dozen sitting cold on disk cost nothing but disk. What matters is
whether the one you invoke fits the budget above.

Reasonable starting points, all Q4_K_M:

| Model | Size | For |
|---|---|---|
| `qwen3.5:9b` | 6.6 GB | general drafting and questions |
| `qwen2.5-coder:7b` | 4.7 GB | code, and comfortable headroom |
| `gemma4:12b` | 7.6 GB | stronger general use, import-dependent fit |
| `nomic-embed-text` | 274 MB | embeddings — required for document search |

The embedding model is the exception to the one-at-a-time rule: RAG hits it
constantly, so it wants to stay loaded alongside the chat model. At 274MB that
costs nothing worth arithmetic.

### Comparing models honestly

Open WebUI has **multi-model chat** — pick several models in one conversation and
a single prompt fans out to all of them, answers side by side. That is the right
harness: same prompt, same context, same session.

**It is also the most reliable way to blow the VRAM budget.** Running three
models at once loads three at once, regardless of `OLLAMA_MAX_LOADED_MODELS` —
that setting caps what stays resident, not what a single request can pull in. So
the comparison is exactly the workload most likely to fall back to CPU and make a
good model look bad.

Compare in pairs, and check `ollama ps` while it runs. If either model shows a
CPU percentage you are benchmarking the card, not the model.

For speed rather than quality, this prints the eval rate in tokens/sec at the end
of each response:

```bash
docker exec -it ollama ollama run <model> --verbose
```

### Giving a model a persistent instruction

Open WebUI's **Workspace → Models** wraps a base model with a system prompt,
temperature and context length under its own name in the picker. That is the
right place for it while you are still experimenting — it is editable in the
browser between attempts, and it is stored in `/srv/openwebui`, which is backed
up.

Ollama's own `Modelfile` does the same thing one layer down and produces a real
model in `ollama list`. It is the better answer only if something outside Open
WebUI needs the same behaviour.

---

## What to back up, and what not to

`/srv/ollama` is **the one data directory on this box that should be excluded
from backups.** Everything in it is a re-downloadable artifact with a name, a
rebuilt server re-pulls it in minutes, and it is the directory most likely to
quietly grow to tens of gigabytes while you try models out. Backing it up costs
real bandwidth and storage to protect nothing that is not on the internet.

`/srv/openwebui` is the opposite and should be treated like Immich's data:
accounts, every conversation anyone in the house has had, uploaded documents and
the vector index built from them. None of it exists anywhere else.

---

## The API hostname, and Claude Desktop

`llm.brent-miles.com` is the raw Ollama API. **Ollama ships no authentication and
has no setting to add any**, so Caddy's LAN guard is the entire access control —
the same class as Frigate's unauthenticated port 5000, except that here there is
no authenticated port to point at instead.

What is actually at risk is bounded: models are re-downloadable, and prompts sent
straight to the API are not stored. The realistic worst case from inside the LAN
is somebody deleting weights you can pull again, or keeping the GPU busy — which
Frigate would notice before you did. If that stops being acceptable, the answer is
a `basicauth` directive in the Caddy block, and it will break any client that
cannot set a header.

**Home Assistant cannot use this hostname.** It is a container, and the
`@notlocal` guard deliberately excludes Docker's own `172.16.0.0/12` range. HA
reaches `http://ollama:11434` over the `proxy` network instead. That is not a
workaround — a request from a container is not a request from the LAN, and that
rule has no exception for our own containers.

### Claude Desktop

Ollama 0.33.0 added a local proxy that speaks the Anthropic API, and the Ollama
desktop app can use it to configure Claude Desktop to run local models in place
of the hosted ones. Two things make it a bad foundation for this stack and a fine
experiment on top of it:

- The documented flow is **machine-local** — the Ollama app configures Claude
  Desktop on the same computer. Nothing upstream describes aiming it at a server
  on the LAN.
- It launched on **Mac first**. The desktops here are Windows.

So the stack does not depend on it. If it is worth testing: install the Ollama
app on a Windows desktop, set `OLLAMA_HOST` to point at `forge`, and see whether
the proxy follows it. If it does, it is a bonus. Worth remembering either way
that pointing Claude Desktop at a 9B model is a large downgrade in capability —
the reasons to do it are privacy and offline, not quality.

---

## Still open

- **Home Assistant as a conversation agent.** HA can use Ollama for its voice
  pipeline, which would make voice commands work without the cloud. It wants a
  resident model for latency, which means giving up `OLLAMA_KEEP_ALIVE=5m` and
  subtracting a model's full size from Frigate's headroom permanently. Not free,
  and not decided.
- **Whether `gemma4:12b` actually fits.** 7.6GB against a 6–7GB idle budget is
  the boundary case. One import during one conversation answers it.
- **The idle iGPU.** The UHD 770 does nothing since Frigate moved to the 3080.
  It cannot run these models usefully, but it remains the natural home for
  Immich's video transcoding — which would take Immich off the 3080 during the
  exact bursts that squeeze this stack.
