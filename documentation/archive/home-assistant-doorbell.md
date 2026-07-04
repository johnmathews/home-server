# Home Assistant — Reolink Doorbell Two-Way Audio

**Status:** superseded by [doorbell.md](../doorbell.md) (2026-07-04).

Two-way audio (talkback) from Home Assistant dashboards to the Reolink video doorbell,
via go2rtc + WebRTC. Set up 2026-07-04.

## Topology

```
+---------------------+----------------+---------------------------------------------+
| Component           | Address        | Notes                                       |
+---------------------+----------------+---------------------------------------------+
| Home Assistant (VM) | 192.168.2.102  | Proxmox VMID 102, HAOS, HA 2026.6.4         |
| Reolink doorbell    | 192.168.2.35   | WiFi, mains powered, RTSP user `admin`      |
| go2rtc (built-in)   | :1984 on HA    | API/UI at http://192.168.2.102:1984         |
| go2rtc WebRTC       | :8555 on HA    | TCP+UDP, media transport for WebRTC         |
+---------------------+----------------+---------------------------------------------+
```

HA is **not managed by this Ansible repo** — it is configured through its own UI/API.
This doc records the configuration because the repo is the household's operational
source of truth.

## Why one-way audio was the symptom

- **MSE/HLS playback is one-way by design.** The built-in HA camera dialog and the
  go2rtc `stream.html` page (when it shows "MSE" in the corner) can never do talkback.
- **Two-way audio requires WebRTC** end-to-end, *and* a player that requests the
  microphone, *and* a **secure context**: browsers only grant `getUserMedia` on
  HTTPS or localhost. `http://192.168.2.102:8123` and `http://homeassistant.local:1984`
  will never show a mic button — use the Nabu Casa HTTPS URL or the companion app.

## The working configuration

### go2rtc stream (go2rtc config inside HA)

```yaml
streams:
  doorbell:
    - "rtsp://admin:<password>@192.168.2.35:554/h264Preview_01_main"
    - "ffmpeg:doorbell#audio=opus#audio=pcma"
    - "rtsp://admin:<password>@192.168.2.35:554/h264Preview_01_sub#backchannel=1"

webrtc:
  candidates:
    - 192.168.2.102:8555
    - stun:8555
```

The doorbell's RTSP SDP advertises three media tracks; the third is the talkback path:

```
video H264                  recvonly   camera -> viewer
audio AAC 16 kHz            recvonly   camera mic -> viewer
audio PCMU/8000             sendonly   viewer mic -> camera SPEAKER (backchannel)
```

The `ffmpeg:` line transcodes the browser's Opus microphone audio to PCMA/PCMU for
the camera. Verify the backchannel is detected at
`http://192.168.2.102:1984/api/streams` (look for `"audio, sendonly, PCMU/8000"`).

### HA side

- **AlexxIT WebRTC Camera** integration installed via HACS (v3.6.1 at setup time).
  It auto-registers the `webrtc-camera` card resource (`/webrtc/webrtc-camera.js`).
- Dashboard **"Doorbell"** (`/front-door`, sidebar icon `mdi:doorbell-video`) with:

```yaml
type: custom:webrtc-camera
url: doorbell            # go2rtc stream name, NOT the Reolink camera entity
media: video,audio,microphone
title: Front Door
```

`media: ...,microphone` is what makes the mic button appear. `url: doorbell` must
point at the manually defined go2rtc stream — the Reolink integration's
auto-generated camera stream does not carry the backchannel.

## Usage

1. Open HA over **HTTPS** (Nabu Casa URL) or the **companion app**.
2. Sidebar → **Doorbell** → tap the microphone icon → grant mic permission once.
3. The card's corner badge should read **RTC** (WebRTC). If it reads MSE, talkback
   is not active — see troubleshooting.

## Troubleshooting

- **No mic icon** — you are on plain HTTP (secure-context block) or the card's
  `media:` option is missing `microphone`.
- **Card shows MSE instead of RTC** — WebRTC failed to negotiate. Check TCP 8555
  is reachable from the client (`nc -z 192.168.2.102 8555`) and that the
  `webrtc.candidates` block lists the HA LAN IP.
- **Distorted/robotic talkback audio** — change the ffmpeg line to a single codec:
  `ffmpeg:doorbell#audio=pcma`.
- **"stream not found"** — the WebRTC integration spun up its own go2rtc instead of
  reusing HA's built-in one; point it at the built-in instance or duplicate the
  `doorbell` stream definition in its config.
- **Inspect live state** (read-only, no auth):
  `curl http://192.168.2.102:1984/api/streams | jq .` and
  `curl http://192.168.2.102:1984/api/config`.

## Administration notes

- HA admin automation (dashboards, config entries, HACS) is possible headlessly via
  the WebSocket API (`ws://192.168.2.102:8123/api/websocket`) with a long-lived
  access token (Profile → Security). Dashboard URL paths must contain a hyphen.
- The doorbell RTSP password is stored in the go2rtc config inside HA; it is not
  in this repo or in Ansible Vault.
