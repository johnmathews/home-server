# The Doorbell

Everything about the Reolink video doorbell at the front door — what it does, how to use it, and (at the end, for the technically curious) how it all works.

## What it can do

- **Rings the chime in the house** when someone presses the button — exactly like a normal doorbell. This works on its own; no phone, app, or server needed.
- **Sends a notification to your phone** when the button is pressed, with a photo of who is standing there. Tapping the notification opens the live video.
- **Live video and sound** from the front door, on any phone, tablet, laptop, or the TV browser — via Home Assistant, from anywhere in the world.
- **Talk to the person at the door** through the doorbell's speaker ("talk mode") — from the couch or from the other side of the planet.
- **Detects motion, people, vehicles and pets** even when nobody presses the button (visible in Home Assistant; can be used for automations later).
- **Records** continuously to local storage. Nothing is sent to Reolink's cloud when viewed through Home Assistant — video stays inside the house.

## How to use it

### When someone rings

1. Both phones get a **"Doorbell" notification with a snapshot**.
2. **Tap the notification** — it opens the Doorbell dashboard with live video and sound.
3. Want to answer? Tap the red **"Talk mode (microphone)"** button under the video, allow microphone access if asked, and speak normally. Expect a **1–2 second delay** before your voice plays at the door — talk like a walkie-talkie: say your piece, then pause. Tap the button again to switch your microphone off.

### Checking the door anytime

Open Home Assistant → **Doorbell** in the left sidebar (the 🔔 icon). Live video starts immediately.

- **Hearing sound:** every browser starts videos **muted** until you've given that
  site a one-time sound permission — this is a browser privacy rule that Home
  Assistant cannot override. Do this once per device on the address you actually
  use (`https://home.johnmathews.is`):
  - **Chrome:** click the tune/lock icon left of the address bar → Site settings →
    **Sound → Allow**.
  - **Firefox:** click the permissions icon left of the address bar →
    **Autoplay → Allow Audio and Video** (or Settings → Privacy & Security →
    Autoplay → manage exceptions).
  - **iPhone app:** iOS gives no permanent setting — tap the **speaker icon** on
    the video's control bar once per viewing. It's always visible at the bottom of
    the card.
  After the desktop permission is set, the video opens with sound every time.
- **Your microphone is always off** unless Talk mode is on. With Talk mode off, the microphone-enabled player isn't even loaded, so the browser releases the mic completely (no recording indicator). You can watch and listen without the doorbell broadcasting anything from inside the house.

### Good to know

- The **chime and button always work**, even if Home Assistant, the network, or the internet is down — the doorbell and chime are paired directly to each other.
- Talk mode is a **house-wide switch**: turning it on means whoever has the dashboard open with a granted microphone is transmitting. It **switches itself off automatically after 3 minutes** as a safety net, but turn it off yourself when done.
- Use Home Assistant over its **secure (https) address or the phone app** — on a plain http address the browser refuses to share the microphone, so Talk mode won't work there.

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

HA is **not managed by the Ansible repo** — it is configured through its own UI/API. Nothing in the streaming/notification path touches Reolink's cloud; media flows browser ↔ go2rtc (HA VM) ↔ camera RTSP, all on the LAN (or via Nabu Casa relay when remote). The camera's own cloud features (`switch.front_door_push_notifications`, `email_on_event`, `ftp_upload`) are separate and can be disabled without affecting any of this.

### Two-way audio: why it works / what broke before

- **MSE/HLS playback is one-way by design.** HA's built-in camera dialog and the go2rtc `stream.html` page (badge shows "MSE") can never do talkback. Talkback requires **WebRTC** plus a player that requests the microphone plus a **secure context** (HTTPS or localhost — plain `http://...:8123`/`:1984` never shows a mic).
- The doorbell's RTSP SDP advertises the talkback path as a third track:

```
video H264                  recvonly   camera -> viewer
audio AAC 16 kHz            recvonly   camera mic -> viewer
audio PCMU/8000             sendonly   viewer mic -> camera SPEAKER (backchannel)
```

- Browsers speak PCMA/PCMU natively in WebRTC, so outgoing voice needs no transcoding. The ~1–2 s talkback delay is the doorbell firmware's jitter buffer — not tunable from our side.

### go2rtc stream (go2rtc config inside HA)

```yaml
streams:
 doorbell:
  - "rtsp://admin:<password>@192.168.2.35:554/h264Preview_01_main"
  - "ffmpeg:doorbell#audio=opus#audio=pcma" # incoming-audio codec variants only
  - "rtsp://admin:<password>@192.168.2.35:554/h264Preview_01_sub#backchannel=1"

webrtc:
 candidates:
  - 192.168.2.102:8555
  - stun:8555
```

Verify the backchannel is detected: `curl http://192.168.2.102:1984/api/streams` should show `"audio, sendonly, PCMU/8000"` under the doorbell producer.

### HA configuration (all created via API, 2026-07-04)

- **AlexxIT WebRTC Camera** integration via HACS (v3.6.1). Auto-registers the `webrtc-camera` card resource.
- **Dashboard** "Doorbell" (`/front-door`, sidebar icon `mdi:doorbell-video`):

```yaml
views:
 - title: Doorbell
   icon: mdi:doorbell-video
   cards:
    - type: custom:webrtc-camera # ALWAYS mounted - never reloads on talk toggle
      url: doorbell # go2rtc stream name, NOT the Reolink entity
      media: video,audio
      ui: true # card's own control bar (persistent volume button)
      title: Front Door
    - type: conditional # talk mode: separate SEND-ONLY mic session mounts
      conditions:
       - condition: state
         entity: input_boolean.doorbell_talk_mode
         state: "on"
      card:
       type: custom:webrtc-camera
       url: doorbell
       media: microphone
       title: 🎤 Microphone live — you are transmitting
    - type: tile
      entity: input_boolean.doorbell_talk_mode
      name: Talk mode (microphone)
      icon: mdi:microphone
      color: red
      tap_action:
       action: toggle # single press toggles, no modal
      icon_tap_action:
       action: toggle
      hold_action:
       action: more-info # long-press still opens details
```

Design rationale:

- **The video card is unconditional** so toggling talk mode never remounts it. (An
  earlier design swapped two conditional video cards; every remount reset the
  browser's mute state.) The mic runs as a **second, send-only go2rtc session**
  (`media: microphone`) that mounts/unmounts with the toggle — unmounting fully
  releases the browser microphone, which is why this is a conditional card and not
  a mute button.
- **Mute/autoplay semantics** (from the card source): the player starts unmuted
  and *auto-mutes itself* when the browser rejects unmuted autoplay
  (`play().catch(() => video.muted = true)`). The card's `muted:` option is
  mute-only — `muted: false` does nothing. Sound-on-open therefore depends
  entirely on the per-site browser permission (see "How to use it"); there is no
  server-side setting.

- **Helper**: `input_boolean.doorbell_talk_mode`. NOTE: this is a persistent,
  house-wide switch, not a per-visit default — if left on it stays on for everyone.
- **Automation** `automation.doorbell_talk_mode_auto_off`: talk mode on for
  3 minutes → turned off (mode `restart`, so re-toggling resets the timer).
- **Automation** `automation.doorbell_pressed_notify_phones`: trigger `binary_sensor.front_door_visitor` off→on; parallel notify to `mobile_app_john_s_phone` and `mobile_app_r_e_a_s_iphone` with snapshot (`/api/camera_proxy/camera.front_door_fluent`), time-sensitive, tap opens `/front-door`.

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

- **No mic icon in talk mode** — you are on plain HTTP (secure-context block), or mic permission was denied for the site.
- **Card badge shows MSE instead of RTC** — WebRTC failed to negotiate; check `nc -z 192.168.2.102 8555` from the client and the `webrtc.candidates` block.
- **Distorted/robotic talkback audio** — change the ffmpeg line to a single codec: `ffmpeg:doorbell#audio=pcma`.
- **Video starts muted** — browser autoplay policy (per device, per site); grant
  the sound/autoplay permission for `https://home.johnmathews.is` (see "How to use
  it" above). On iOS there is no permission — one tap on the speaker icon.
- **"stream not found"** — the WebRTC integration spun up its own go2rtc instead of reusing HA's built-in one; point it at the built-in instance.
- **Inspect live state** (read-only, no auth): `curl http://192.168.2.102:1984/api/streams | jq .`

### Headless HA administration

REST + WebSocket API (`ws://192.168.2.102:8123/api/websocket`) with a long-lived access token (Profile → Security). Notes: dashboard `url_path` needs a hyphen; strategy dashboards (like Overview) can't take cards without converting to manual; automations via `POST /api/config/automation/config/<id>`; helpers and dashboards via WebSocket commands (`input_boolean/create`, `lovelace/config/save`). The doorbell RTSP password lives in the go2rtc config inside HA — not in this repo or Ansible Vault.
