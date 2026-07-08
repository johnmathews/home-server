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
- The grey `PTT v12 | …` line under the button is diagnostics: `sent:` should climb while you hold and speak. Errors show as a red banner on the card.
- **You can see who is answering.** While one person holds the talk button, everyone else's screens show an amber banner — *"🎙 Ritsya is talking to the visitor"* — live for exactly as long as the button is held, and the other person's phone gets a push ("Ritsya is talking to the visitor", throttled to once per 2 minutes). Best practice remains one talker at a time.
- **Away from home, expect degraded behavior (pending confirmation — see Testing checklist).** Outside the house, connections go through the Cloudflare tunnel, which cannot carry WebRTC media: observed remote sessions fall back to MSE (video +1–3 s lag, one-way only), and **hold-to-talk is expected NOT to work remotely** because talkback requires WebRTC. Watch the badge in the video corner: **RTC** = full function, **MSE** = view-only. Fix options if remote talkback is wanted: forward port 8555 (TCP+UDP) on the MikroTik to 192.168.2.102 (go2rtc already advertises its public address via STUN), or use Tailscale on the phones so the LAN address is reachable.
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

Latency budget (what is and isn't tunable):

```
+--------------------------------------+-----------+---------------------------+
| Component                            | Approx.   | Tunable?                  |
+--------------------------------------+-----------+---------------------------+
| DOORBELL -> APP                      |           |                           |
|  camera encoder buffer               | 200-400ms | no (firmware)             |
|  audio transcode (AAC->Opus, ffmpeg) | ~100ms    | no (WebRTC can't do AAC)  |
|  network (LAN, WebRTC)               | <10ms     | already minimal           |
|  browser jitter buffer               | 100-300ms | YES - v12 hints it to 75ms|
|  MSE fallback (remote via tunnel)    | +1-3s     | avoidable (see below)     |
+--------------------------------------+-----------+---------------------------+
| APP -> DOORBELL                      |           |                           |
|  browser mic + WebRTC send           | 20-60ms   | already minimal           |
|  go2rtc -> camera (PCMU passthrough) | ~10ms     | no transcode, minimal     |
|  doorbell firmware playback buffer   | 500-800ms | NO - this is the floor    |
+--------------------------------------+-----------+---------------------------+
```

**Remote access transports:** WebRTC needs a reachable media path (port 8555). At home, LAN candidates work directly. Through the Cloudflare tunnel only HTTP flows, so the card falls back to MSE (view-only, +1–3 s). To get full-function remote access: MikroTik port-forward 8555 TCP+UDP → 192.168.2.102 (the `stun:8555` candidate then resolves and advertises the public address), or Tailscale on the client devices.

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
- **Diagnostics bar** (`PTT v12 | pc | sender | holding | sent`) driven by `getStats()`.
- **Latency hint**: sets `jitterBufferTarget` (fallback `playoutDelayHint`) to ~75 ms on all WebRTC receivers each tick — shaves 100–300 ms off doorbell→viewer playout where the browser supports it.
- **Insecure-context guard**: on plain http, `navigator.mediaDevices` does not exist (the mount-time failure is silent and a naive call throws synchronously); the button surfaces "Microphone blocked: insecure connection" instead of hanging red.
- **Who-is-talking**: on press the script writes the logged-in user's name (`hass.user.name`, via the frontend's `home-assistant` element — an internal but long-stable API) into `input_text.doorbell_talker`, and clears it on release / `pagehide`. Every card polls that entity in its 400 ms tick and shows the amber banner when someone *else* is talking. Fallback name is "someone" if the hass object is unavailable.

To modify: edit `doorbell-ptt.js`, encode the file **verbatim** into a `data:` URL (`"data:text/javascript," + urllib.parse.quote(js, safe="(){}=>;.,'&:_$![]|=")`), then update the resource via the WebSocket API (`lovelace/resources/update`, resource id `6eebc249f29c4b22a92b3658d51f4da9`). Clients pick it up on hard refresh (companion app: close fully and reopen, or Settings → Debugging → Reset frontend cache). Bump the `PTT vN` version string when editing so the diagnostics bar confirms which version a client is running.

### Notifications

Automation `automation.doorbell_pressed_notify_phones`: on `binary_sensor.front_door_visitor` off→on, parallel notify to `mobile_app_john_s_phone` and `mobile_app_r_e_a_s_iphone` with a **static snapshot** (`data.image: /api/camera_proxy/camera.front_door_fluent`), time-sensitive, tap opens `/front-door`. On iOS the snapshot shows as a small banner thumbnail; **long-press to expand** the full photo.

Notification snapshots **depend on the Cloudflare Access bypass rules** (next section). Two attachment methods were tried: `data.entity_id` (live stream attachment) renders a **black screen** through the Cloudflare tunnel (buffered MJPEG/HLS), so the static `data.image` snapshot is the deliberate choice.

### Cloudflare Access and the companion app

`home.itsa-pizza.com` sits behind Cloudflare Zero Trust Access. The **main app works** (its session carries the Access cookie), but the app's **background processes run in separate iOS processes without that cookie** — notification attachments, token refresh, background webhooks. Access intercepts their requests and returns its login page, producing misleading client-side errors:

```
+--------------------------------------------------+--------------------------------------+
| Error shown on the phone                         | What actually happened               |
+--------------------------------------------------+--------------------------------------+
| "Failed to load attachment - Request adaption    | Token refresh POST /auth/token got   |
|  failed ... ObjectMapper failed to serialize"    | the Access login page instead of JSON|
| "HLS stream unavailable"                         | Stream URL fetch blocked by Access   |
| "... MJPEGStreamer.MJPEGError error 0"           | MJPEG fallback blocked by Access     |
| Attachment loads but BLACK screen                | Live stream buffered by the CF       |
|                                                  | tunnel (not an Access problem)       |
+--------------------------------------------------+--------------------------------------+
```

**Fix (applied 2026-07-08): Access *bypass* policies** on `home.itsa-pizza.com` for the paths token-based clients need — each remains protected by HA's own auth:

```
/api/camera_proxy/*         notification snapshot fetch   (HA bearer auth)
/api/camera_proxy_stream/*  camera stream fetch           (HA bearer auth)
/api/webhook/*              app location/sensor telemetry (secret webhook ids)
/auth/token                 OAuth token refresh           (valid refresh token required)
```

Verify from any external network — a response **from HA** (not a 302 to `cloudflareaccess.com`) means the bypass works:

```sh
curl -i https://home.itsa-pizza.com/api/camera_proxy/camera.front_door_fluent   # 403 from HA = OK
curl -i -X POST https://home.itsa-pizza.com/auth/token -d grant_type=refresh_token  # {"error":"invalid_request"} = OK
curl -i https://home.itsa-pizza.com/api/                                        # 302 to Access = still protected, correct
```

Side effect worth knowing: `/api/webhook/*` being blocked also silently broke the app's **background location/sensor updates when away from home** — fixed by the same bypass.

Automation `automation.doorbell_someone_is_answering` (config id `doorbell_talker_notify`): when `input_text.doorbell_talker` becomes non-empty for 1 s, notify the *other* person's phone (John talks → Ritsya's iPhone, and vice versa; unknown names fall back to John's phone). Throttled via `last_triggered` > 120 s. Automation `automation.doorbell_talker_stale_clear`: talker name non-empty for 3 minutes → reset to empty (browser died mid-press).

(An earlier `doorbell_talk_mode` input_boolean + auto-off automation existed for a toggle-based design; both were deleted when the single-button design replaced it.)

### Useful entities (Reolink integration)

```
binary_sensor.front_door_visitor          doorbell button press
input_text.doorbell_talker                name of whoever is holding talk (else empty)
binary_sensor.front_door_motion/_person/_vehicle/_pet
camera.front_door_fluent                  snapshot source for notifications
number.front_door_doorbell_volume         doorbell speaker volume (currently 93)
select.reolink_chime_visitor_ringtone     chime ringtone
switch.front_door_doorbell_button_sound   the doorbell's own press beep
siren.front_door_siren                    doorbell siren
```

### Testing checklist

Run after any change (script version, go2rtc config, HA upgrade) or to answer
"does it work away from home?". Hard-refresh the browser / fully restart the app
first, and confirm the grey bar shows the expected `PTT vNN` before judging.

Scenarios (test each row top-to-bottom; note results):

```
+----+---------------------------+--------------------------------------------------+
| #  | Scenario                  | Steps                                            |
+----+---------------------------+--------------------------------------------------+
| 1  | Laptop, home WiFi         | full check (below)                               |
| 2  | iPhone app, home WiFi     | full check                                       |
| 3  | iPhone app, WiFi OFF (4G) | full check <- the open question: remote talkback |
| 4  | Second person present     | banner + notification check (below)              |
+----+---------------------------+--------------------------------------------------+
```

Full check, per scenario:

1. **Badge**: corner of the video — record `RTC` or `MSE`. (`MSE` = view-only mode; talk cannot work.)
2. **Video**: live, and reacts within ~1 s when you wave at the camera.
3. **Sound**: audible after at most one tap anywhere on the page.
4. **Diagnostics line**: `pc:yes | sender:yes` (on iPhone, `sender:NO` before the very first hold is normal).
5. **Talk**: hold the button ~5 s and speak. Expect: button red, `sent:` climbing by a few kB/s, voice at the door after ~1 s. Note any red banner text verbatim.
6. **Release**: audio returns; `sent:` stops climbing.

Second-person check (scenario 4): while one person holds talk, the other's screen shows the amber "🎙 <name> is talking" banner within ~1 s, and their phone gets one push (throttled: max one per 2 min).

Record results as: scenario / badge / talk worked? / delay felt / any banner text.
Known-good reference (2026-07-08): scenarios 1, 2, 4 all pass with badge RTC; scenario 3 untested — expected MSE + no talk until the port-forward or Tailscale fix is applied.

### Troubleshooting

- **Diagnostics first**: the grey bar on the card. `pc:NO` = WebRTC never connected; `sender:NO` = no talk channel negotiated (iOS pre-first-hold, or mic permission denied); `sent:` not climbing while held = browser not transmitting. Red banner = surfaced error (`NotAllowedError` = permission).
- **Test the server→speaker leg without any browser** (plays a tone at the door):
  `curl -X POST "http://192.168.2.102:1984/api/streams?dst=doorbell&src=ffmpeg:http://<some-host>/tone.wav%23audio=pcmu%23input=file"`
- **Inspect live sessions**: `curl http://192.168.2.102:1984/api/streams | jq .` — look for the mic consumer (`audio, recvonly`) and its bytes, and the backchannel session's senders/bytes toward `192.168.2.35`.
- **Video starts muted** — browser autoplay policy; see "Hearing sound" above. One tap anywhere is the universal fallback.
- **Talk worked, then stopped working across refreshes** — historically the wedged main-session backchannel; ensure `#backchannel=0` is still on the main stream (see above).
- **Distorted/robotic talkback audio** — change the ffmpeg line to a single codec: `ffmpeg:doorbell#audio=pcma`.
- **Notification shows "Failed to load attachment / Request adaption failed", "HLS stream unavailable", or a black image** — Cloudflare Access is blocking the app's background fetches, or the live-stream attachment is being used; see "Cloudflare Access and the companion app" above.
- **Phone: `sender:NO` and 0 kB sent while holding** — the app is connected over plain http (internal URL). Set the companion app's internal URL to https or disable it (see "Good to know").
- **iOS app shows stale dashboard/behavior** — companion app Settings → Debugging → Reset frontend cache.
- **Card badge shows MSE instead of RTC** — WebRTC failed to negotiate; check TCP 8555 reachability and `webrtc.candidates`.

### Upstream contribution (pending)

The PTT feature was reimplemented as a native `ptt: true` option for the
AlexxIT/WebRTC card and offered upstream in
[issue #685](https://github.com/AlexxIT/WebRTC/issues/685#issuecomment-4884009785)
(2026-07-05). Patch + next-steps runbook:
`~/projects/webrtc-ptt-contribution/` and
[journal/260705-webrtc-ptt-oss-contribution.md](../journal/260705-webrtc-ptt-oss-contribution.md).
If the PR is eventually merged, the injected `doorbell-ptt.js` resource can be
retired in favor of the card's built-in option (see the runbook, step 4).

### Headless HA administration

REST + WebSocket API (`ws://192.168.2.102:8123/api/websocket`) with a long-lived access token (Profile → Security). Notes: dashboard `url_path` needs a hyphen; strategy dashboards (like Overview) can't take cards without converting to manual; automations via `POST /api/config/automation/config/<id>`; helpers, dashboards, and frontend resources via WebSocket commands (`input_boolean/create|delete`, `lovelace/config/save`, `lovelace/resources/create|update`). go2rtc on `:1984` is unauthenticated on the LAN: `GET/POST /api/config`, `POST /api/restart`, `GET /api/streams`. The doorbell RTSP password lives in the go2rtc config inside HA — not in this repo or Ansible Vault.
