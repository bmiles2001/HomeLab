# Frigate

The NVR. Object detection on every frame it looks at, continuously, forever —
that's what separates "alert me when a person is at the door" from "alert me
when a tree moves."

Two things about this deployment are unusual and both are deliberate:
detection runs on the **RTX 3080**, and **recording is off**.

---

## Why the 3080 and not the iGPU

The original plan gave Frigate the Intel UHD 770 and Immich the 3080, on the
reasoning that a continuous workload and a bursty one shouldn't share silicon.
That's still sound reasoning; it was reversed for a simpler one — the 3080 is
enormously faster at this, and the enhanced detection is the reason for
choosing Frigate over an appliance NVR in the first place.

The numbers, roughly:

| | UHD 770 / OpenVINO / SSDLite | RTX 3080 / ONNX / yolov9-t |
|---|---|---|
| Inference | ~10–15 ms | low single-digit ms |
| Accuracy | MobileNet-class, 91 labels | markedly better, 80 labels |
| Cameras supported | ~16 stream-equivalents | far more than this house needs |

Frigate's capacity formula:

```
cameras ≈ (1000 / inference_speed_ms) / detect_fps
```

Watch the real number on Frigate's System page rather than trusting the table.

**`type: onnx`, not `type: tensorrt`.** The image is still called `-tensorrt`
and that trips everyone up. NVIDIA dropped compatibility with the TensorRT
versions Frigate had pinned, so for desktop cards the TensorRT detector is
gone; the image name survives because it's what carries CUDA. Any guide older
than 0.17 will tell you otherwise. `type: tensorrt` now only means Jetson.

Requires driver ≥ 530 and compute capability ≥ 5.0. The 3080 is 8.6. Note that
0.17 **dropped support for GTX 900-series cards** — not relevant here, but it's
why some older forum answers no longer apply.

### Sharing the 3080 with Immich

The original concern was real, it's just been judged acceptable. What to expect:

- **Detection is tiny.** yolov9-t at 320px on an Ampere card uses a small
  fraction of it. Immich's CLIP and face recognition are far heavier.
- **A large Immich import will slow detection.** Not stop it — CUDA time-slices
  — but inference time will visibly rise on the System page while an import
  runs. If you're importing a decade of photos, expect it, and don't go
  debugging Frigate.
- **VRAM is the real limit, not compute.** 10GB is plenty for both, but if you
  later turn on Frigate's semantic search or face recognition, those load
  additional models onto the same card. Check `nvidia-smi` before assuming.

If this ever becomes a genuine problem the fallback hasn't gone anywhere:
change the detector back to OpenVINO on the iGPU and switch `hwaccel_args` to
`preset-vaapi`. Two lines in `config.yml`, plus adding the `/dev/dri` device
back to `compose.yml`.

### And skip the Coral

Frigate's own hardware docs no longer recommend the Coral TPU for new
installations, and there are two perfectly good accelerators in this box
already. Note also that detectors **cannot be mixed** — it's ONNX *or*
OpenVINO *or* Coral, never a blend.

---

## Step 1: build the detector model

**Do this before the first deploy.** The `-tensorrt` image ships no default
ONNX model, and Frigate will not start without one. The failure looks like a
missing-file error rather than "you skipped a step."

Run this anywhere with Docker — it doesn't have to be `forge`, and it doesn't
need a GPU. It builds a throwaway image, exports the model inside it, and drops
the result in your current directory:

```bash
docker build . --build-arg MODEL_SIZE=t --build-arg IMG_SIZE=320 --output . -f- <<'EOF'
FROM python:3.11 AS build
RUN apt-get update && apt-get install --no-install-recommends -y cmake libgl1 && rm -rf /var/lib/apt/lists/*
COPY --from=ghcr.io/astral-sh/uv:0.10.4 /uv /bin/
WORKDIR /yolov9
ADD https://github.com/WongKinYiu/yolov9.git .
RUN uv pip install --system -r requirements.txt
RUN uv pip install --system onnx==1.18.0 onnxruntime onnx-simplifier==0.4.* onnxscript
ARG MODEL_SIZE
ARG IMG_SIZE
ADD https://github.com/WongKinYiu/yolov9/releases/download/v0.1/yolov9-${MODEL_SIZE}-converted.pt yolov9-${MODEL_SIZE}.pt
RUN sed -i "s/ckpt = torch.load(attempt_download(w), map_location='cpu')/ckpt = torch.load(attempt_download(w), map_location='cpu', weights_only=False)/g" models/experimental.py
RUN python3 export.py --weights ./yolov9-${MODEL_SIZE}.pt --imgsz ${IMG_SIZE} --simplify --include onnx
FROM scratch
ARG MODEL_SIZE
ARG IMG_SIZE
COPY --from=build /yolov9/yolov9-${MODEL_SIZE}.onnx /yolov9-${MODEL_SIZE}-${IMG_SIZE}.onnx
EOF

sudo cp yolov9-t-320.onnx /srv/frigate/models/
```

It takes ten to twenty minutes, almost all of it downloading PyTorch.

`MODEL_SIZE` and `IMG_SIZE` must match `model.width` / `model.height` in
`config.yml` and the filename in `model.path`. If you change either build
argument, change all three. Sizes go `t`, `s`, `m`, `c`, `e` — `t` is right
here; a 3080 could run `s` at 640 comfortably if accuracy ever disappoints, at
the cost of rebuilding.

**Why yolov9 and not YOLO-NAS**, which older guides push: only yolov9, YOLOX and
RF-DETR get CUDA Graphs acceleration in 0.17. YOLO-NAS explicitly does not, and
its pretrained weights carry a non-commercial licence besides.

Back it up, or at least write down that this page exists. It's ~10MB and
regenerating it is a twenty-minute errand you won't remember the shape of.

---

## Recording is off, and what that costs

`config.yml` ships with `record.enabled: false`. This is the setting most
likely to surprise you later, so it's worth being blunt about what it means:

- **No clips, anywhere.** Review, History and Explore will be largely empty.
- **Home Assistant notifications carry a still image**, not a video.
- **Nothing to export after an incident.** A snapshot is one frame.

So right now this is a live-view and alerting system, not a recorder. That's a
reasonable place to start — it proves the cameras, the detection and the phones
all work before committing a terabyte to it — but don't mistake it for a
finished security system.

### The arithmetic that made this the default

One 4MP camera at ~4 Mbps:

| Mode | Per camera per day | 4 cameras, 7 days |
|---|---|---|
| Continuous | ~43 GB | **~1.2 TB** |
| Motion only | ~10 GB | ~280 GB |

The top row is most of the 2TB NVMe, permanently, for footage of an empty
driveway — on the disk the photo library lives on. Frigate filling that
filesystem takes Immich's Postgres down with it. That's the actual risk, and
it's why this waits for its own disk.

### Turning it on when the disk arrives

Three steps:

1. Mount the new drive, then point `FRIGATE_MEDIA` in Infisical at it.
2. Replace `record: {enabled: false}` in `config.yml` with the block commented
   out directly above it.
3. `./scripts/deploy.sh frigate`.

Note the **0.17 schema change**: `continuous` and `motion` are now separate keys
under `record`, and the old `retain: {days, mode}` shape no longer loads. Any
recording config you find in a 0.15 or 0.16 guide needs translating.

Start at `motion` retention rather than `continuous`. Continuous is a real
feature — it's the only thing that answers "what happened at 3am that nothing
detected" — but decide the GB budget first and set retention to fit it, rather
than discovering the answer when the disk is full.

---

## Networking, and why this is never public

**Frigate is LAN-only, permanently.** It sits inside the `@notlocal` guard in
the Caddyfile alongside everything except Immich. Everything about an NVR is
worst-case-if-breached — live video of the inside of your house, on a service
whose threat model assumes a trusted network.

Reached at `https://security.brent-miles.com`, on the wildcard certificate,
with no DNS record of its own.

Two ports matter and the difference is important:

- **8971** — the authenticated UI. This is what Caddy proxies.
- **5000** — an *unauthenticated* admin port, meant for use behind a proxy that
  handles auth itself. This proxy does not. Never publish it, and never point
  Caddy at it.

Frigate's own compose example publishes both, because it assumes no reverse
proxy. This stack publishes neither.

**Put the cameras on a VLAN with no internet route.** Consumer IP cameras are
some of the worst-maintained software in the house, they phone home, and
several vendors have shipped hardcoded credentials. Frigate needs to reach
them; they need to reach nothing. If the Orbi can't do VLANs, at minimum block
them outbound at the firewall.

Give the cameras a dedicated non-admin RTSP account and put that password in
Infisical under `/frigate`. `config.yml` references it as
`{FRIGATE_RTSP_PASSWORD}`, so camera URLs stay in git safely.

---

## Config drift, the same trap as everywhere else

Frigate's web UI includes a config editor that writes to `config.yml`. Used
once, the running config stops matching this repo — the exact failure mode
`decisions.md` rejects Portainer's editor for.

`config.yml` is mounted **read-only** so the UI physically cannot save over it.
Read in the UI, change in git, redeploy. That takes about ten seconds, which is
the only reason the rule survives contact with a Saturday afternoon.

0.17 makes this slightly more annoying than it was: the new Add Camera wizard
and the UI's zone editor both want to write to that file, and they'll report a
save failure. Draw the zone in the UI, copy the coordinates, paste them here.

---

## First run

Get one camera working before you add the rest.

```bash
./bootstrap.sh                       # creates /srv/frigate/*, the iot network
# ... build the model, per step 1 above ...
./scripts/deploy.sh mosquitto        # frigate expects a broker
./scripts/deploy.sh frigate
docker logs -f frigate
```

Then, in order:

1. **Find the camera's RTSP URLs** — main stream and substream. Frigate keeps
   vendor-specific notes at
   [docs.frigate.video/configuration/camera_specific](https://docs.frigate.video/configuration/camera_specific).
2. **Edit `config.yml`**: replace the `front_door` template with the real IP and
   stream paths. Detection points at the **substream**; the main stream is what
   the live view and Home Assistant pull. Aiming detection at a 4K feed is the
   single most common way to make Frigate slow.
3. Set `detect.width` / `detect.height` to the substream's real resolution.
   0.17 changed resolution auto-detection, and a camera that misreports makes
   Frigate **hang on startup** rather than log an error.
4. `./scripts/deploy.sh frigate`, then watch `docker logs -f frigate`.
5. **Check the System page**: inference speed should be low single-digit ms, and
   the GPU should appear rather than a CPU fallback. Check ffmpeg is using NVDEC
   too — if `NVIDIA_DRIVER_CAPABILITIES=all` were missing, detection would still
   work on the GPU while decoding silently fell back to the CPU.
6. **Draw zones**, paste the coordinates back here. Without zones, a camera
   facing the street alerts on every passing car — and a motion detector that
   cries wolf gets muted, then ignored, then turned off.

Only then add camera two.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| Container exits immediately, missing-path error | No model in `/srv/frigate/models`. See step 1. |
| `manifest unknown` on pull | `FRIGATE_VERSION` was set to `0.17.2-tensorrt`; compose appends `-tensorrt` itself. |
| Hangs on startup, no error | A camera misreporting its resolution. Set `detect.width`/`height` explicitly. |
| "Bus error", random crashes | `shm_size` too small for the camera count. |
| Detection on GPU but CPU pinned | NVDEC not in use — check `NVIDIA_DRIVER_CAPABILITIES`. |
| Reconnects to MQTT every few seconds | Credentials under `/frigate` and `/mosquitto` disagree. |
| Live view works, no events in HA | MQTT connected but the Frigate integration isn't installed. See [home-assistant.md](home-assistant.md). |

## Sources

- [Frigate — Object Detectors](https://docs.frigate.video/configuration/object_detectors/)
- [Frigate — Recording](https://docs.frigate.video/configuration/record)
- [Frigate 0.17.0 release notes](https://github.com/blakeblackshear/frigate/releases/tag/v0.17.0)
- [Frigate — Recommended hardware](https://docs.frigate.video/frigate/hardware/)
- [Frigate — Camera specific configuration](https://docs.frigate.video/configuration/camera_specific)
