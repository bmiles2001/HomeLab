# Frigate + Home Assistant punchlist

Ordered set of things to do to get the cameras working, with the commands to do
them. Written 2026-08-04, with the stacks committed but never deployed. Delete
this file once it's all ticked — it's a working list, not reference material.

Detail lives in [frigate.md](frigate.md) and [home-assistant.md](home-assistant.md).

**Two hard ordering constraints:**

1. The detector model (step 3) must exist before Frigate is deployed (step 5).
   Frigate does not start without it.
2. Mosquitto must be up before Frigate and Home Assistant. Both retry a missing
   broker forever rather than failing, so getting this wrong produces no error —
   just a Home Assistant with no cameras in it and no clue why.

---

## 0. Commit and push from your PC

Nothing below works on forge until this lands.

```powershell
cd $HOME\Claude\Projects\"Podman Home Containers"
git add -A
git commit -m "frigate on the 3080, mosquitto, home assistant"
git push
```

---

## 1. Physical and network prerequisites

Not commands — decisions to have made before the software matters.

- [ ] Cameras bought, mounted, on PoE, and reachable by IP.
- [ ] A **dedicated non-admin RTSP account** on each camera, same password on
      all of them.
- [ ] Cameras on a **VLAN with no internet route**, or at minimum blocked
      outbound at the Orbi. Consumer IP cameras are the worst-maintained
      software in the house and several vendors ship hardcoded credentials.
- [ ] Each camera's **main stream and substream** RTSP URLs written down.
      Vendor-specific notes: [docs.frigate.video/configuration/camera_specific](https://docs.frigate.video/configuration/camera_specific)
- [ ] The substream's actual resolution written down. You need it in step 6, and
      guessing makes Frigate hang on startup rather than log an error.

---

## 2. Pull, bootstrap, put the secrets in

```bash
ssh forge
cd ~/home-containers && git pull
./bootstrap.sh
```

`bootstrap.sh` now creates the `iot` network, `/srv/frigate/{media,models}` and
`/srv/homeassistant/config`. Expect it to warn about the missing detector model
— that's step 3.

Then the secrets. The MQTT password is one credential stored under two paths;
generate it once and paste the same value into both, or Frigate reconnects to
the broker every few seconds forever.

```bash
MQTT_PW=$(openssl rand -base64 24)

infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/mosquitto \
  MQTT_USER=frigate MQTT_PASSWORD="$MQTT_PW"

infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/frigate \
  FRIGATE_MQTT_USER=frigate FRIGATE_MQTT_PASSWORD="$MQTT_PW" \
  FRIGATE_RTSP_PASSWORD='<the camera account password>'

# HA has no secrets of its own, but deploy.sh needs the path to exist
infisical secrets set --projectId="$INFISICAL_PROJECT_ID" --env=prod --path=/homeassistant \
  TZ=America/Chicago

echo "$MQTT_PW"   # you'll type this into HA by hand in step 8
```

---

## 3. Build the detector model

**Frigate will not start without this.** The `-tensorrt` image ships no ONNX
model. Ten to twenty minutes, almost all of it downloading PyTorch. Full
explanation in [frigate.md](frigate.md#step-1-build-the-detector-model).

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
./bootstrap.sh | grep -i model     # should now say ok
```

Back the file up somewhere. It's ~10MB and rebuilding it is an errand you won't
remember the shape of.

---

## 4. Confirm the GPU is actually usable by containers

Immich's ML already uses it, so this should pass — but check before blaming
Frigate.

```bash
nvidia-smi
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

Driver must be ≥ 530. If the second command fails, the container toolkit isn't
registered and Frigate's detector won't come up either.

---

## 5. Deploy the broker, then Frigate

```bash
./scripts/deploy.sh mosquitto
docker logs mosquitto --tail 20        # want "mosquitto version 2.x starting", no pwfile errors

./scripts/deploy.sh frigate
docker logs -f frigate
```

Grab the generated admin password — it is printed **once**:

```bash
docker logs frigate 2>&1 | grep -i password
```

If Frigate exits immediately, it's almost always step 3. Check the
troubleshooting table in [frigate.md](frigate.md#troubleshooting) before
anything else.

---

## 6. One camera, properly, before any others

Edit `stacks/frigate/config.yml` **on your PC**, not on forge. Replace the
`front_door` template with the real IP and stream paths:

- detect role → the **substream**
- record role → the **main stream** (still used for live view even with
  recording off)
- `detect.width` / `detect.height` → the substream's real resolution

Then push, pull, redeploy:

```bash
# on forge
cd ~/home-containers && git pull
./scripts/deploy.sh frigate
docker logs -f frigate
```

---

## 7. Route it through Caddy and check the System page

```bash
docker exec caddy caddy reload --config /etc/caddy/Caddyfile
```

Open `https://security.brent-miles.com`, log in as `admin`, change the password,
and add a `viewer` account for the family.

Then **System page**, and check all three:

- [ ] Inference speed in the **low single-digit ms**. If it's 25ms+, something
      fell back to CPU.
- [ ] The **GPU appears** as the detector rather than CPU.
- [ ] **CPU is not pinned.** If detection is on the GPU but a core is buried,
      ffmpeg is software-decoding — `NVIDIA_DRIVER_CAPABILITIES` isn't reaching
      the container.

---

## 8. Home Assistant

```bash
./scripts/deploy.sh homeassistant
docker logs -f homeassistant     # first start takes several minutes
```

At `https://home.brent-miles.com`, in order — full detail in
[home-assistant.md](home-assistant.md#first-run):

1. **Onboard.** First account is the owner and can't be demoted. Make it yours,
   not a shared family one.
2. **MQTT integration** — broker `mosquitto`, port `1883`, credentials from
   step 2. Container name, not an IP.
3. **HACS**:
   ```bash
   docker exec -it homeassistant bash -c "wget -O - https://get.hacs.xyz | bash -"
   docker restart homeassistant
   ```
   then add the HACS integration in the UI and do the GitHub device-code dance.
4. **Frigate integration** via HACS → restart → add integration →
   URL `http://frigate:8971`.
   `http://`, not `https://`. Not port 5000 (unauthenticated). Not the
   `security.` hostname.

You should end up with camera, image, sensor, switch and binary_sensor entities
per camera.

---

## 9. Notifications

Import [SgtBatten's Frigate Notifications blueprint](https://github.com/SgtBatten/HA_blueprints)
rather than writing an automation by hand — it handles cooldowns, zone filtering
and silencing, which is the difference between a useful alert and one the family
mutes within a week.

**Set expectations before you hand out phones:** with recording off, the
notification carries a **still image, not a clip**, and the blueprint's clip/GIF
options will produce nothing.

---

## 10. Zones — do not skip this

Without zones, a camera facing the street alerts on every passing car. A motion
detector that cries wolf gets muted, then ignored, then turned off, and then you
have no security system.

Draw them in the Frigate UI, copy the coordinates, paste them into
`config.yml` on your PC, push, pull, redeploy. The UI cannot save them itself —
`config.yml` is mounted read-only on purpose.

---

## 11. The family

One phone completely before touching the others.

1. Home Assistant from the App Store → `https://home.brent-miles.com`
2. Log in as **their own HA user**, not yours — notifications are per-user and
   per-device, and a shared login makes them impossible to target.
3. Trigger a detection and confirm the notification arrives with an image.

**Tell them the limitation up front:** the notification arrives anywhere, but
the image and the live view only load at home. That's a LAN-only system, not a
bug, and it goes away when Tailscale does.

---

## 12. Then add the remaining cameras

One at a time, checking inference speed on the System page after each. The
capacity formula is `cameras ≈ (1000 / inference_ms) / detect_fps`, and a 3080
running yolov9-t has far more headroom than this house needs — but watch it
rather than trusting that.

---

## What's deliberately still open afterwards

In risk order:

1. **Recording.** Off until there's a disk that isn't the photo library's. This
   is live view and alerting only — there is nothing to review after an
   incident. Buy the drive, point `FRIGATE_MEDIA` at it, uncomment the record
   block in `config.yml`. See
   [frigate.md](frigate.md#turning-it-on-when-the-disk-arrives).
2. **A backup for `/srv/homeassistant/config`.** Holds every credential HA has.
   Nothing covers it. Stop the container before copying — SQLite mid-write.
3. **Tailscale**, which fixes off-LAN notification images and live view.
4. **Immich transcoding on the now-idle iGPU.** Free performance, unclaimed.
