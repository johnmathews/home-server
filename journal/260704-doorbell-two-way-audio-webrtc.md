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

## Phase 4 (same day): no-reload talk toggle + mute truth

- User noticed toggling talk mode reloaded the video card (conditional-card swap
  remounts the player, which resets to muted). Redesigned: the video card is now
  **unconditional** (never remounts); talk mode mounts a separate **send-only mic
  card** (`media: microphone`) — a second go2rtc session on the same stream.
- Read the card source (webrtc-camera.js / video-rtc.js): the player starts
  unmuted and auto-mutes on `play()` rejection; the `muted:` config option is
  mute-only, so the earlier `muted: false` was a no-op (corrected in docs).
  Sound-on-open is purely a per-site browser permission: Chrome Site settings →
  Sound → Allow; Firefox Autoplay → Allow Audio and Video (on
  `https://home.johnmathews.is`); iOS has no permission, one tap required.
- Added `ui: true` to the video card for a persistent control bar with a
  one-tap volume button (helps iOS especially).

## Phase 5 (same day): the debugging saga → final single-button design

The toggle/conditional-card designs kept failing in the field. Root causes, found
by testing against the real card source in a Playwright harness and by watching
go2rtc's session API live during user tests:

- **Load-order race**: HA renders cards while Lovelace resources are still
  loading, so prototype-patching alone missed already-rendered cards — sometimes
  nothing was enhanced. Fix: also retrofit existing instances by walking shadow
  DOMs, with retries.
- **Chrome truth**: Site settings → Sound → Allow does NOT permit unmuted
  autoplay (Google "Won't Fix"); only MEI, PWA install, or the managed
  `AutoplayAllowlist` policy do. Firefox's per-site Autoplay permission works.
- **iOS gesture rule**: WebKit rejects `getUserMedia` outside a user gesture.
  The card acquires the mic at mount (async, outside gesture) and only
  `console.warn`s the failure — so the iPhone silently created a session with no
  audio channel at all (confirmed: no mic consumer ever reached go2rtc).
- **Backchannel wedge**: talkback rode the permanent main RTSP session; senders
  accumulated (16 observed) and never cleaned up, plus the PTT design streamed
  continuous silence, plus two devices armed at once — the camera's single
  talkback session wedged and survived browser refreshes ("worked once, never
  again"). Fix: `#backchannel=0` on the main stream so talkback uses the
  dedicated on-demand sub-session (fresh dial per use, self-clearing). Verified
  server→speaker independently by injecting a tone via
  `POST /api/streams?dst=doorbell&src=ffmpeg:<url>#audio=pcmu` (32 kB = 4 s
  delivered; user confirmed audible).
- **UX**: the two-level arm-toggle + hold-card design confused; conditional-card
  mount/unmount re-rendered the video card, resetting it to muted.

Final design: **one card** (`media: video,audio,microphone`, `ui: true`) plus one
injected module that adds a "🎤 Hold to talk" button — fresh `getUserMedia` per
hold (in-gesture, iOS-safe), `sender.replaceTrack()` attach/detach (verified via
real-WebRTC loopback: bytes stop on null, resume on restore), mic fully released
on release, half-duplex incoming mute while held, on-card diagnostics
(`getStats` byte counter) and visible error banners. Deleted the input_boolean +
auto-off automation. Script source preserved at `documentation/doorbell-ptt.js`;
deployed as a `data:` URL Lovelace resource (id `6eebc249…`) since HAOS offers
no filesystem access without SSH.

Working end-to-end on desktop; user access domain is `https://home.itsa-pizza.com`
(HA's configured external_url says home.johnmathews.is — unreconciled).
