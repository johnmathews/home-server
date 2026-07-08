# 2026-07-08 — Doorbell latency levers + remote-access gap (PTT v12)

Follow-up to the who-is-talking work earlier today. John asked whether the
speak→hear lag could be reduced in either direction.

## Findings

- **App→doorbell is at its floor**: mic → go2rtc → camera is <100 ms with PCMU
  passthrough (no transcode); the remaining ~0.5–0.8 s is the doorbell
  firmware's playback buffer. Not tunable. (Suggested cross-check: the official
  Reolink app should show similar delay.)
- **Doorbell→app had one tunable component**: the browser's adaptive jitter
  buffer (100–300 ms). PTT v12 hints it down via
  `RTCRtpReceiver.jitterBufferTarget = 75` (fallback `playoutDelayHint`),
  applied every tick to all receivers.
- **Remote-access gap discovered** (from session logs of the 2026-07-04
  monitoring): connections from outside the LAN arrive via the Cloudflare
  tunnel, which only carries HTTP — the card falls back to **MSE**: +1–3 s of
  view latency and, critically, **no talkback** (PTT requires WebRTC).
  At home, LAN host candidates give direct WebRTC. Remote talkback is expected
  broken; John believes it worked — pending systematic confirmation.

## Changes

- PTT v12 deployed (jitter-buffer hint); source updated in
  `documentation/doorbell-ptt.js`.
- `documentation/doorbell.md`: latency-budget table, remote-access transport
  explanation (fix options: MikroTik 8555 TCP+UDP port-forward → 192.168.2.102,
  or Tailscale on the phones), and a new **Testing checklist** section with
  4 scenarios (laptop home / iPhone home / iPhone on 4G / second-person
  banner+notification) and a per-scenario full check.

## Open

- Scenario 3 (iPhone on 4G): run the checklist to confirm whether remote
  talkback works. If MSE + no talk, decide between port-forward (needs
  explicit approval — firewall change on the MikroTik, `router` SSH alias
  exists) or Tailscale-on-phones.
