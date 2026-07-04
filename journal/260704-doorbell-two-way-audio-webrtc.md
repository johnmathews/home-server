# 2026-07-04 — Doorbell two-way audio via WebRTC in Home Assistant

## Problem

The Reolink WiFi doorbell (192.168.2.35) streamed video + audio into Home Assistant (VM 102, 192.168.2.102), but talkback (speaking through the doorbell's speaker) did not work. The go2rtc debug page showed "MSE" and no microphone icon.

## Root cause

Not a camera or go2rtc problem — the backchannel was already fully configured and the doorbell advertises a `PCMU sendonly` speaker track in its RTSP SDP. Two client-side gates were failing:

1. **MSE playback is one-way by design** — both the go2rtc `stream.html` page and HA's built-in camera dialog use MSE/HLS, which cannot carry a microphone. Talkback requires WebRTC.
2. **Secure context** — browsers refuse microphone access (`getUserMedia`) on plain HTTP for non-localhost hosts, so `http://...:1984` / `http://...:8123` can never show a mic button. The HTTPS (Nabu Casa) URL or companion app is required.

## Fix

Everything server-side was already in place (go2rtc backchannel stream, AlexxIT WebRTC Camera integration v3.6.1 via HACS, WebRTC port 8555 reachable). The missing piece was a dashboard card that uses WebRTC and requests the mic.

Created dashboard **Doorbell** (`/front-door`) with:

```yaml
type: custom:webrtc-camera
url: doorbell
media: video,audio,microphone
title: Front Door
```

## Notes / learnings

- HA was administered entirely headlessly: REST + WebSocket API with a long-lived access token (`uv run --with websockets`). Used `lovelace/dashboards/create` and `lovelace/config/save`. Dashboard `url_path` must contain a hyphen.
- The main Overview dashboard is strategy-generated (`original-states`), so cards cannot be added to it without converting it to manual mode — a dedicated dashboard was less invasive.
- The card must reference the go2rtc stream name (`url: doorbell`), not the Reolink integration's camera entity — the auto-generated stream lacks the backchannel.

## Phase 2 (same day): notifications + mic-off-by-default

- Created `automation.doorbell_pressed_notify_phones`: on `binary_sensor.front_door_visitor` press, parallel push (with camera snapshot, time-sensitive, tap opens `/front-door`) to both phones. Created via `POST /api/config/automation/config/<id>`; test-fired successfully.
- Reworked the Doorbell dashboard for privacy: `input_boolean.doorbell_talk_mode` gates two conditional cards — default is a listen-only card (`media: video,audio`); toggling talk mode unmounts it and mounts a mic-enabled card (`media: video,audio,microphone`). Unmounting fully releases the browser microphone (better than a mute button).
- Speaker audio "on by default" is limited by browser autoplay policy on desktop — fix is allowing sound for the HA site in browser site settings; companion app plays sound automatically.
- Talkback delay ~1–2 s is the doorbell firmware's jitter buffer; the outgoing audio path has no transcode hop (browsers speak PCMA/PCMU natively in WebRTC), so nothing to tune server-side.
- The RF-paired Reolink chime rings independently of HA/network — unaffected.
- Full write-up: `documentation/doorbell.md` (supersedes `home-assistant-doorbell.md`, now in `documentation/archive/`).

## Phase 3 (same day): talk-mode footgun fix

- User found talk mode "on by default" — the `input_boolean` is persistent and
  house-wide, so it had simply stayed on after testing. Added
  `automation.doorbell_talk_mode_auto_off` (on for 3 min → off, mode `restart`).
- Also added `muted: false` to both webrtc-camera cards (per AlexxIT README this is
  the initial mute-toggle state) so clients that permit sound autoplay start
  unmuted. Browser autoplay policy still wins where it applies: Firefox needs the
  per-site Autoplay → "Allow Audio and Video" permission; the iOS companion app
  needs one tap on the speaker icon per stream start.
