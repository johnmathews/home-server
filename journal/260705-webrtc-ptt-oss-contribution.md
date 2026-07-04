# 2026-07-05 — Offering the doorbell PTT feature upstream (AlexxIT/WebRTC)

The push-to-talk work from [260704](260704-doorbell-two-way-audio-webrtc.md) solves
feature requests that have been open for years in the AlexxIT/WebRTC card repo
(#685, #750, #584), so we prepared an upstream contribution.

## What was done

- Reimplemented the PTT logic as a **native card feature** (`ptt: true` config
  option) against upstream master (`0c5421b`, 2026-07-04): ~150 lines in
  `webrtc-camera.js` following the repo's `render*()` pattern, no changes to the
  vendored `video-rtc.js`, plus a README "Push to talk" section. Cleaner than our
  injected script — inside the card there is no monkey-patching, shadow-DOM
  walking, or load-order race handling.
- Verified in a Playwright harness against the real card: mic parked (released)
  after negotiation, fresh in-gesture capture on hold, full teardown on release,
  self-mute while transmitting, iOS "hold again to talk" reconnect path, visible
  error banners.
- Posted an offer-to-PR comment on issue #685 (2026-07-05, approved by John):
  <https://github.com/AlexxIT/WebRTC/issues/685#issuecomment-4884009785>
  It also documents the Reolink `#backchannel=0` wedge fix for others.

## Artifacts (outside this repo)

`~/projects/webrtc-ptt-contribution/`:

- `0001-add-push-to-talk-mode.patch` — `git am`-ready feature patch
- `issue-685-comment-as-posted.md` — the comment as posted
- `README.md` — same next-steps checklist as below

## Runbook: when the maintainer responds

If AlexxIT reacts positively to the comment (each public step needs John's
approval first):

1. **Rebase check** — clone upstream fresh, `git am
   ~/projects/webrtc-ptt-contribution/0001-add-push-to-talk-mode.patch`; resolve
   if master moved.
2. **Smoke test on real hardware** — swap the live HA card resource to the
   patched `webrtc-camera.js` for five minutes: dashboard `/front-door`, replace
   the injected-script behavior by loading the patched card + `ptt: true` on the
   card config, verify hold-to-talk end-to-end (desktop + iPhone), then restore.
   (HA admin is headless: WebSocket API + long-lived token — John must create a
   fresh token; the old one should be revoked.)
3. **Fork and PR** — fork AlexxIT/WebRTC under `johnmathews` (`gh repo fork`),
   push branch `feat-push-to-talk`, open the PR referencing #685/#750/#584.
   Match whatever shape the maintainer asked for in his reply (he sometimes
   wants different option names or UI placement — adjust before submitting).
4. **If the PR lands** — our injected script (`documentation/doorbell-ptt.js`)
   can be retired: switch the dashboard card to the released card version with
   `ptt: true`, delete the `data:` URL Lovelace resource (id `6eebc249…`), and
   update `documentation/doorbell.md`.
5. **If declined or ignored (~a month)** — keep our injected script (it works
   fine); optionally publish the patch as a standalone HACS frontend module if
   others ask for it on the issue.

## Watching for a response

No automation set up — John will see GitHub notifications for replies to his
comment. Any future session can resume with "the WebRTC maintainer replied";
the memory file and this runbook carry the context.
