# 2026-07-08 — Doorbell notification snapshots vs Cloudflare Access

John noticed the doorbell-press notification appeared to be text-only. The
snapshot had been configured since day one — it had never actually loaded.

## The debugging chain

1. Long-press on a real notification showed **"Failed to load attachment —
   Request adaption failed … ObjectMapper failed to serialize response"** —
   the iOS notification content extension was failing, not the config.
2. Switched the payload from `data.image` (raw camera_proxy URL) to
   `data.entity_id` (the documented iOS camera attachment) → new error:
   **"HLS stream unavailable … MJPEGStreamer.MJPEGError error 0"**.
3. Root cause found by curling the external URL anonymously:
   **`home.itsa-pizza.com` is behind Cloudflare Zero Trust Access.** The main
   app carries the Access cookie; the notification extension runs in a
   separate process without it, so Access fed its login page to every fetch —
   hence three different decode errors from three different fetch paths.
4. John added Access **bypass** policies: `/api/camera_proxy/*`,
   `/api/camera_proxy_stream/*`, `/api/webhook/*`. Verified via curl
   (responses now from HA, not 302s). entity_id attachment then loaded but
   rendered a **black screen** — live MJPEG/HLS doesn't survive the buffering
   Cloudflare tunnel.
5. Switched back to `data.image` (single static JPEG — tunnel-friendly). It
   failed once more with "request adaption failed": the extension's **token
   refresh** hits `/auth/token`, which was still behind Access (predicted one
   message before it happened — expired token → refresh → login page).
6. John added `/auth/token` to the bypass. **Snapshot works.**

## Outcome

- Notification now attaches a static snapshot (`data.image:
  /api/camera_proxy/camera.front_door_fluent`); iOS shows a thumbnail,
  long-press expands.
- Four Access bypass paths documented in `documentation/doorbell.md`
  ("Cloudflare Access and the companion app") with an error→cause table and
  verification curls. Each bypassed path retains HA's own auth.
- Bonus fix: `/api/webhook/*` bypass also un-breaks the app's background
  location/sensor updates when away from home (silently broken before).

## Learnings

- Cloudflare Access + HA companion app: interactive sessions work, everything
  running in a separate iOS process (notification extensions, background
  refresh) fails with **decode errors that look like app bugs**. Test with an
  anonymous curl before believing any client-side error text.
- iOS `data.entity_id` live attachments need unbuffered streaming — a
  CF-tunneled HA can't provide it; static `data.image` is the robust choice.
- "Request adaption failed" (Alamofire) = token refresh failed, not the
  actual resource fetch.
