# 2026-07-08 — Doorbell: see who is answering ("who-is-talking")

Follow-up to [260704](260704-doorbell-two-way-audio-webrtc.md). With two people
able to answer the doorbell, John wanted to see when Ritsya is already talking
to a visitor (and vice versa).

## Design

The PTT script runs inside each person's authenticated HA frontend session, so
it knows who is pressing the button: `hass.user.name` via the frontend's
`home-assistant` element (internal but long-stable API, same mechanism card-mod
uses). No server-side detection needed — go2rtc session inspection would only
yield device IPs, which map poorly to people.

## Implementation (PTT v11)

- New helper `input_text.doorbell_talker`: set to the talker's name on press,
  cleared on release and on `pagehide`.
- Card banner: each card polls the entity in its existing 400 ms tick and shows
  an amber "🎙 <name> is talking to the visitor" banner while someone *else*
  holds the button. Hidden for the talker themselves (their button already
  shows TRANSMITTING).
- `automation.doorbell_someone_is_answering` (config id
  `doorbell_talker_notify`): talker non-empty for 1 s → push to the *other*
  person's phone (name-based `choose`; unknown names fall back to John's
  phone). Throttled via `last_triggered > 120 s` so hold/release cycles in one
  conversation produce one push.
- `automation.doorbell_talker_stale_clear`: name non-empty for 3 min → reset
  (browser died mid-press).

Verified: end-to-end simulation (set helper to "Ritsya" via API → John's phone
received the push; `last_triggered` confirmed) and user confirmed receipt.

## Notes

- zsh footgun during deploy: `for pair in "a b"; do set -- $pair` does not
  word-split in zsh — automations silently weren't created on first attempt
  (the `{"result":"ok"}` output was actually curl errors). Explicit commands
  fixed it.
- Automation entity IDs come from the **alias**, not the config id:
  `POST /api/config/automation/config/doorbell_talker_notify` with alias
  "Doorbell - someone is answering" → `automation.doorbell_someone_is_answering`.
- A fresh `input_text` helper starts as `'unknown'`, not `''` — reset it after
  creation or state templates misfire.
- This feature is homelab-specific (multi-user awareness) and intentionally NOT
  part of the upstream AlexxIT/WebRTC PTT patch.
