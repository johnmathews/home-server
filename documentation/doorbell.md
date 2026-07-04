# The Doorbell

Everything about the Reolink video doorbell at the front door — what it does, how to use it, and (at the end, for the technically curious) how it all works.

## What it can do

- **Rings the chime in the house** when someone presses the button — exactly like a normal doorbell. This works on its own; no phone, app, or server needed.
- **Sends a notification to your phone** when the button is pressed, with a photo of who is standing there. Tapping the notification opens the live video.
- **Live video and sound** from the front door, on any phone, tablet, laptop, or the TV browser — via Home Assistant, from anywhere in the world.
- **Talk to the person at the door** through the doorbell's speaker — hold one button, speak, release.
- **Detects motion, people, vehicles and pets** even when nobody presses the button (visible in Home Assistant; can be used for automations later).
- **Records** continuously to local storage. Nothing is sent to Reolink's cloud when viewed through Home Assistant — video stays inside the house.

## How to use it

### When someone rings

1. Both phones get a **"Doorbell" notification with a snapshot**.
2. **Tap the notification** — it opens the Doorbell dashboard with live video.
3. Want to answer? **Press and hold the blue "🎤 Hold to talk" button** under the video. It turns red ("TRANSMITTING"), your incoming audio pauses (so you don't hear your own echo), and your voice plays at the door. **Release to stop talking and hear their reply.** Expect a ~1 second delay before your voice plays at the door — talk like a walkie-talkie: say your piece, then release and listen.

First time on a device it may ask for microphone permission; on the iPhone the very first hold can show "Reconnecting — hold again to talk" — hold a second time and it works from then on.

### Checking the door anytime

Open Home Assistant → **Doorbell** in the left sidebar (the 🔔 icon). Live video starts immediately.

- **Hearing sound:** browsers start videos muted until you've granted a one-time sound permission for the site — a browser privacy rule Home Assistant cannot override. On the address you actually use (e.g. `https://home.itsa-pizza.com`):
  - **Firefox:** permissions icon left of the address bar → **Autoplay → Allow Audio and Video**. After this, sound plays on open, every time.
  - **Chrome:** offers **no such setting** (marked "Won't Fix" by Google) — it auto-allows only after its internal engagement score for the site grows (`chrome://media-engagement`), or if HA is installed as an app (address-bar install icon), or via the managed policy `defaults write com.google.Chrome AutoplayAllowlist -array "https://home.itsa-pizza.com"` (restart Chrome; verify at `chrome://policy`).
  - **iPhone app:** no permanent setting exists on iOS.
  - **Everywhere:** failing all of the above, **one tap anywhere on the page** starts the sound (a helper script makes any tap count — no need to hit the tiny speaker icon).
- **Your microphone is off unless the button is red.** The mic is captured when you press "Hold to talk" and fully released when you let go — the browser's recording indicator is only on while you're actually transmitting. (A sub-second mic blip at page load is the card pre-negotiating the talk path so the button responds instantly.)
- Permissions are **per browser origin** — if you use both the local (`http://…:8123`) and external addresses, each needs its own grants; talking only works on the HTTPS address (browsers refuse mic access on plain HTTP).

### Good to know

- The **chime and button always work**, even if Home Assistant, the network, or the internet is down — the doorbell and chime are RF-paired directly to each other.
- **One talker at a time**: the doorbell hardware supports a single talkback session, like the Reolink app. If two people hold their buttons at once, the camera gets confused.
- The grey `PTT v10 | …` line under the button is diagnostics: `sent:` should climb while you hold and speak. Errors show as a red banner on the card.
- **The phone app must connect over https for talking to work.** If the companion app's *internal URL* is `http://homeassistant.local:8123` (the default), iOS blocks microphone access entirely while on home WiFi — the card shows `sender:NO` and a "Microphone blocked: insecure connection" banner on hold. Fix: app → Settings → Companion App → your server → set the **Internal URL** to the https address (or disable "connect via internal URL") so the app always uses `https://home.itsa-pizza.com`.

---

## Technical reference

Everything below is for maintenance; normal use never needs it.

### Topology

```
+---------------------+----------------+---------------------------------------------+
| Component           | Address        | Notes                                       |
+---------------------+----------------+---------------------------------------------+
| Home Assistant (VM) | 192.168.2.102  | Proxmox VMID 102, HAOS, HA 2026.6.4         |
| Reolink doorbell    | 192.168.2.35   | WiFi, mains powered, RTSP user `admin`      |
| Reolink chime       | (RF paired)    | Rings independently of HA/network           |
| go2rtc (built-in)   | :1984 on HA    | API/UI at http://192.168.2.102:1984         |
| go2rtc WebRTC       | :8555 on HA    | TCP+UDP, media transport for WebRTC         |
+---------------------+----------------+---------------------------------------------+
```

HA is **not managed by the Ansible repo** — it is configured through its own UI/API (see "Headless HA administration" below). Nothing in the streaming/notification path touches Reolink's cloud; media flows browser ↔ go2rtc (HA VM) ↔ camera RTSP, all on the LAN (or via remote-access relay). The camera's own cloud features (`switch.front_door_push_notifications`, `email_on_event`, `ftp_upload`) are separate and can be disabled without affecting any of this.

### Audio architecture

The doorbell's RTSP SDP advertises three tracks; the third is the talkback path:

```
video H264                  recvonly   camera -> viewer
audio AAC 16 kHz            recvonly   camera mic -> viewer
audio PCMU/8000             sendonly   viewer mic -> camera SPEAKER (backchannel)
```

Talkback requires **WebRTC** (MSE/HLS are one-way by design — HA's built-in camera dialog and go2rtc's `stream.html` can never do it), a **secure context** (HTTPS) for mic access, and — on iOS — `getUserMedia` called **during a user gesture**.

The talkback round trip is ~1.4 s (dominated by the doorbell firmware's ~0.5–0.8 s audio buffer — not tunable); the visitor hears you after roughly half that. Echo (your voice returning via the doorbell's mic) is avoided by muting incoming audio while transmitting (half-duplex), like every commercial intercom.

### go2rtc stream (go2rtc config inside HA)

```yaml
streams:
  doorbell:
    - "rtsp://admin:<password>@192.168.2.35:554/h264Preview_01_main#backchannel=0"
    - "ffmpeg:doorbell#audio=opus#audio=pcma"     # incoming-audio codec variants only
    - "rtsp://admin:<password>@192.168.2.35:554/h264Preview_01_sub#backchannel=1"

webrtc:
  candidates:
    - 192.168.2.102:8555
    - stun:8555
```

**`#backchannel=0` on the main stream is load-bearing.** Without it, talkback senders pile up on the permanent main RTSP session (they are never cleaned up), and once the camera's talkback wedges it stays wedged across browser refreshes — the observed symptom was "talk worked once, then never again". With it, mic audio routes through the *dedicated sub-stream session*, which go2rtc dials fresh per use and hangs up afterwards, so failures self-clear. Edit via `POST http://192.168.2.102:1984/api/config` (raw YAML body) + `POST /api/restart` (brief blip on all camera streams).

### Dashboard + injected script

Dashboard **"Doorbell"** (`/front-door`, icon `mdi:doorbell-video`) holds a single card:

```yaml
type: custom:webrtc-camera   # AlexxIT WebRTC integration (HACS), v3.6.1
url: doorbell                # go2rtc stream name, NOT the Reolink camera entity
media: video,audio,microphone
ui: true
title: Front Door
```

All talk/unmute behavior comes from a **Lovelace resource**: a JS module (registered as a `data:text/javascript,…` URL — no filesystem access to HAOS was available) that patches the card class. Reference source with comments: [`doorbell-ptt.js`](doorbell-ptt.js). It provides:

- **Auto-unmute** after playback starts where the browser allows it, with fallback to "first tap anywhere unmutes". (The card's own fallback treats *any* early `play()` rejection as autoplay-blocked and self-mutes — this recovers from that.)
- **Hold-to-talk button** injected into the card: fresh `getUserMedia` per hold (inside the gesture — the iOS requirement), attach via `sender.replaceTrack(track)`, detach + `track.stop()` on release. Idle = zero packets sent and mic fully released.
- **Half-duplex**: all viewer videos mute while transmitting, restore on release.
- **iOS first-use path**: mount-time `getUserMedia` fails outside a gesture (silently — the card only `console.warn`s), so the card negotiates no audio sender; the first hold acquires permission in-gesture and reconnects the card ("hold again to talk").
- **Race-proofing**: HA renders cards while resources are still loading, so the module both patches the class *and* retrofits existing instances by walking shadow DOMs (retries at 0/0.8/2.5/8 s).
- **Diagnostics bar** (`PTT v10 | pc | sender | holding | sent`) driven by `getStats()`.
- **Insecure-context guard**: on plain http, `navigator.mediaDevices` does not exist (the mount-time failure is silent and a naive call throws synchronously); the button surfaces "Microphone blocked: insecure connection" instead of hanging red.

To modify: edit `doorbell-ptt.js`, encode the file **verbatim** into a `data:` URL (`"data:text/javascript," + urllib.parse.quote(js, safe="(){}=>;.,'&:_$![]|=")`), then update the resource via the WebSocket API (`lovelace/resources/update`, resource id `6eebc249f29c4b22a92b3658d51f4da9`). Clients pick it up on hard refresh (companion app: close fully and reopen, or Settings → Debugging → Reset frontend cache). Bump the `PTT vN` version string when editing so the diagnostics bar confirms which version a client is running.

### Notifications

Automation `automation.doorbell_pressed_notify_phones`: on `binary_sensor.front_door_visitor` off→on, parallel notify to `mobile_app_john_s_phone` and `mobile_app_r_e_a_s_iphone` with snapshot (`/api/camera_proxy/camera.front_door_fluent`), time-sensitive, tap opens `/front-door`.

(An earlier `doorbell_talk_mode` input_boolean + auto-off automation existed for a toggle-based design; both were deleted when the single-button design replaced it.)

### Useful entities (Reolink integration)

```
binary_sensor.front_door_visitor          doorbell button press
binary_sensor.front_door_motion/_person/_vehicle/_pet
camera.front_door_fluent                  snapshot source for notifications
number.front_door_doorbell_volume         doorbell speaker volume (currently 93)
select.reolink_chime_visitor_ringtone     chime ringtone
switch.front_door_doorbell_button_sound   the doorbell's own press beep
siren.front_door_siren                    doorbell siren
```

### Troubleshooting

- **Diagnostics first**: the grey bar on the card. `pc:NO` = WebRTC never connected; `sender:NO` = no talk channel negotiated (iOS pre-first-hold, or mic permission denied); `sent:` not climbing while held = browser not transmitting. Red banner = surfaced error (`NotAllowedError` = permission).
- **Test the server→speaker leg without any browser** (plays a tone at the door):
  `curl -X POST "http://192.168.2.102:1984/api/streams?dst=doorbell&src=ffmpeg:http://<some-host>/tone.wav%23audio=pcmu%23input=file"`
- **Inspect live sessions**: `curl http://192.168.2.102:1984/api/streams | jq .` — look for the mic consumer (`audio, recvonly`) and its bytes, and the backchannel session's senders/bytes toward `192.168.2.35`.
- **Video starts muted** — browser autoplay policy; see "Hearing sound" above. One tap anywhere is the universal fallback.
- **Talk worked, then stopped working across refreshes** — historically the wedged main-session backchannel; ensure `#backchannel=0` is still on the main stream (see above).
- **Distorted/robotic talkback audio** — change the ffmpeg line to a single codec: `ffmpeg:doorbell#audio=pcma`.
- **Phone: `sender:NO` and 0 kB sent while holding** — the app is connected over plain http (internal URL). Set the companion app's internal URL to https or disable it (see "Good to know").
- **iOS app shows stale dashboard/behavior** — companion app Settings → Debugging → Reset frontend cache.
- **Card badge shows MSE instead of RTC** — WebRTC failed to negotiate; check TCP 8555 reachability and `webrtc.candidates`.

### Headless HA administration

REST + WebSocket API (`ws://192.168.2.102:8123/api/websocket`) with a long-lived access token (Profile → Security). Notes: dashboard `url_path` needs a hyphen; strategy dashboards (like Overview) can't take cards without converting to manual; automations via `POST /api/config/automation/config/<id>`; helpers, dashboards, and frontend resources via WebSocket commands (`input_boolean/create|delete`, `lovelace/config/save`, `lovelace/resources/create|update`). go2rtc on `:1984` is unauthenticated on the LAN: `GET/POST /api/config`, `POST /api/restart`, `GET /api/streams`. The doorbell RTSP password lives in the go2rtc config inside HA — not in this repo or Ansible Vault.
