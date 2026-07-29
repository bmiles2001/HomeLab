# Frigate

Yes, it uses machine learning — object detection on every frame it looks at,
continuously, forever. That's the whole point: it's what separates "alert me
when a person is at the door" from "alert me when a tree moves."

But it's a *different* ML workload from Immich's, and the interesting decision
is which silicon each one gets.

---

## Two GPUs, two jobs

You have an Intel UHD 770 iGPU and an RTX 3080. That's lucky, because these two
workloads have opposite shapes:

| | Frigate | Immich |
|---|---|---|
| When | 24/7, every camera, forever | Bursts during import, then idle |
| Model | Small detector on 640×480 crops | CLIP embeddings + face recognition |
| Latency matters | Yes — it caps how many cameras you can run | No — it's a background job |
| If it's slow | You miss events | You wait longer |

**The split: Frigate on the iGPU, Immich on the 3080.**

The iGPU does two separate things for Frigate, and both matter:

- **Decoding.** Several 24/7 H.264/H.265 streams decoded in software will keep
  a big chunk of that i9 permanently busy. QuickSync does it for nearly nothing.
  This is non-optional; do it even if you move detection elsewhere.
- **Detection**, via OpenVINO. A UHD 770 runs the stock SSDLite MobileNet model
  in roughly 10–15ms, which is plenty for a handful of cameras.

Immich gets the 3080 to itself via the `-cuda` ML image. Nothing competes with
it, and a large first-time import finishes in minutes instead of hours.

### Frigate's capacity formula

```
cameras ≈ (1000 / inference_speed_ms) / detect_fps
```

At 12ms inference and 5 fps detection that's roughly 16 camera-streams — far
more than you need. Watch the real number on Frigate's System page.

### When to move detection to the 3080

If inference time climbs past ~25ms, or you add enough cameras that the formula
gets tight, switch to the `-tensorrt` image and the ONNX detector.

One thing that will trip you up if you read older guides: **the TensorRT
detector was removed for NVIDIA GPUs.** NVIDIA dropped compatibility for the
older TensorRT versions Frigate had pinned. The `-tensorrt` *image* still
exists and is still what you want — but inside it you configure `type: onnx`,
not `type: tensorrt`. Guides written before 0.17 will tell you otherwise.

Requires driver >= 530 and compute capability >= 5.0. The 3080 is 8.6, fine.

### And skip the Coral

Frigate's own hardware docs no longer recommend the Coral TPU for new
installations. You already have two perfectly good accelerators in the box.
Note also that detectors **cannot be mixed** for object detection — it's
OpenVINO *or* ONNX *or* Coral, not a blend.

---

## The thing that will actually bite you: storage

Detection is cheap. Recording is not, and it shares the 2TB NVMe with the photo
library that this whole build exists for.

Rough arithmetic for one 4MP camera at ~4 Mbps:

| Mode | Per camera per day | 4 cameras, 7 days |
|---|---|---|
| Continuous (`mode: all`) | ~43 GB | **~1.2 TB** |
| Motion only (`mode: motion`) | ~10 GB | ~280 GB |

That top row is most of your disk, permanently, for footage of an empty
driveway. `config.yml` therefore ships with `record.retain.mode: motion` and 7
days of continuous retention, with alerts and detections kept for 30.

Two things to do before you point real cameras at it:

1. **Decide the budget first.** Pick how many GB Frigate is allowed and set
   retention to fit, rather than discovering the answer when Postgres can't
   write because the disk is full. Immich and Frigate sharing a filesystem
   means Frigate filling it takes photos down too.
2. **Consider a separate disk.** The cleanest version of this is recordings on
   their own spinning drive — cheap per TB, and sequential writes are what
   they're good at. It also isolates the failure. `FRIGATE_MEDIA` in
   `.env.example` exists so this is a one-line change later.

`/tmp/cache` is a tmpfs in compose.yml, so the constant segment churn never
touches the NVMe at all.

---

## Networking, and why this is never public

**Frigate is LAN-only, permanently.** When 443 gets forwarded for Immich, this
must stay behind the `@notlocal` guard in the Caddyfile or be removed from it
entirely. Everything about an NVR is worst-case-if-breached: live video of the
inside of your house, on a service whose threat model assumes a trusted network.

Two ports matter and the difference is important:

- **8971** — the authenticated UI. This is what Caddy proxies.
- **5000** — an *unauthenticated* admin port, intended for use behind a proxy
  that handles auth. Never publish it. Frigate's own compose example publishes
  both; that example assumes no reverse proxy.

The stack publishes neither, because only Caddy publishes ports.

**Put the cameras on a VLAN with no internet route.** Consumer IP cameras are
some of the worst-maintained software in your house, they phone home, and
several vendors have shipped hardcoded credentials. Frigate needs to reach
them; they need to reach nothing. If your router can't do VLANs, at minimum
block them outbound at the firewall.

Give the cameras a dedicated non-admin RTSP account, and put that password in
Infisical under `/frigate` — `config.yml` references it as
`{FRIGATE_RTSP_PASSWORD}` so camera URLs stay in git safely.

---

## Config drift, the same trap as everywhere else

Frigate's web UI includes a config editor that writes to `config.yml`. Used
once, the running config stops matching this repo — the exact failure mode
`decisions.md` rejects Portainer's editor for.

`config.yml` is mounted **read-only** so the UI physically cannot save over it.
Read in the UI, change in git, redeploy. Editing here and running
`./scripts/deploy.sh frigate` takes about ten seconds, which is the only reason
that rule survives contact with a Saturday afternoon.

---

## First run

Get one camera working before you add the rest. In order:

1. Find the camera's RTSP URLs — main stream and substream. Frigate keeps
   vendor-specific notes at
   [docs.frigate.video/configuration/camera_specific](https://docs.frigate.video/configuration/camera_specific).
2. Edit `config.yml`: replace the `front_door` template with the real IP and
   stream paths. Detection points at the **substream**; recording points at the
   main stream. Aiming detection at a 4K feed is the single most common way to
   make Frigate slow.
3. `./scripts/deploy.sh frigate`, then `docker logs -f frigate`.
4. Check the System page: inference speed, and that the iGPU shows up rather
   than falling back to CPU.
5. Draw zones in the UI and paste the coordinates back into `config.yml`.
   Without zones, a camera facing the street alerts on every passing car, and a
   motion detector that cries wolf gets ignored and then turned off.

Only then add camera two.

## Sources

- [Frigate — Object Detectors](https://docs.frigate.video/configuration/object_detectors/)
- [Frigate — Recommended hardware](https://docs.frigate.video/frigate/hardware/)
- [Frigate — Installation](https://docs.frigate.video/frigate/installation/)
- [Frigate — Enrichments / hardware acceleration](https://docs.frigate.video/configuration/hardware_acceleration_enrichments/)
- [Frigate detectors 2026: Hailo vs Coral vs Intel NPU](https://hometechops.com/cameras/coral-vs-hailo-vs-intel-npu)
- [Frigate + NVIDIA setup guide (2026)](https://corelab.tech/setupfrigate/)
- [Immich — Hardware-accelerated machine learning](https://docs.immich.app/features/ml-hardware-acceleration/)
