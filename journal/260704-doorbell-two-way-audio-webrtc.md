# 2026-07-04 — Doorbell two-way audio via WebRTC in Home Assistant

## Problem

The Reolink WiFi doorbell (192.168.2.35) streamed video + audio into Home Assistant
(VM 102, 192.168.2.102), but talkback (speaking through the doorbell's speaker) did
not work. The go2rtc debug page showed "MSE" and no microphone icon.

## Root cause

Not a camera or go2rtc problem — the backchannel was already fully configured and
the doorbell advertises a `PCMU sendonly` speaker track in its RTSP SDP. Two
client-side gates were failing:

1. **MSE playback is one-way by design** — both the go2rtc `stream.html` page and
   HA's built-in camera dialog use MSE/HLS, which cannot carry a microphone.
   Talkback requires WebRTC.
2. **Secure context** — browsers refuse microphone access (`getUserMedia`) on plain
   HTTP for non-localhost hosts, so `http://...:1984` / `http://...:8123` can never
   show a mic button. The HTTPS (Nabu Casa) URL or companion app is required.

## Fix

Everything server-side was already in place (go2rtc backchannel stream, AlexxIT
WebRTC Camera integration v3.6.1 via HACS, WebRTC port 8555 reachable). The missing
piece was a dashboard card that uses WebRTC and requests the mic.

Created dashboard **Doorbell** (`/front-door`) with:

```yaml
type: custom:webrtc-camera
url: doorbell
media: video,audio,microphone
title: Front Door
```

## Notes / learnings

- HA was administered entirely headlessly: REST + WebSocket API with a long-lived
  access token (`uv run --with websockets`). Used `lovelace/dashboards/create` and
  `lovelace/config/save`. Dashboard `url_path` must contain a hyphen.
- The main Overview dashboard is strategy-generated (`original-states`), so cards
  cannot be added to it without converting it to manual mode — a dedicated
  dashboard was less invasive.
- The card must reference the go2rtc stream name (`url: doorbell`), not the Reolink
  integration's camera entity — the auto-generated stream lacks the backchannel.
- Full write-up: `documentation/home-assistant-doorbell.md`.
