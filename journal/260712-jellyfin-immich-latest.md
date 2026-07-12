# Jellyfin and Immich: confirmed on rolling tags; both upgraded

**Date:** 2026-07-12

## Finding: both apps already tracked rolling tags — but were stale in practice

- **Jellyfin** builds `jellyfin-with-yt-dlp:latest` locally `FROM jellyfin/jellyfin:latest`
  (+ latest yt-dlp + the ffprobe ulimit wrapper). With `pull: never`, "latest" only means
  latest-at-pull-time: the cached base was from 2025-11-03 (10.11.2) — eight months stale.
- **Immich** server + ML use the official rolling `release` tag
  (`IMMICH_VERSION=release`). Someone had pulled v2.6.3 at some point but never
  recreated, so containers ran untagged v2.5.2 images while `release` pointed at v2.6.3
  locally.

## Changes

- `immich_public_proxy_version`: `1.6.1` → `latest` in role defaults (live container
  was already running `latest` — repo/live drift, now reconciled).
- Deployed `make immich`: server+ML recreated onto v2.6.3 (from v2.5.2), proxy on
  latest, live-drifted sidecars (were `latest`) reconciled to the repo's `sidecar_*`
  pins. All containers healthy, `/api/server/ping` 200.
- Jellyfin: pulled fresh base (10.11.11), `docker compose build jellyfin && up -d`.
  Healthy, web 200, version confirmed 10.11.11. No active viewers at restart time.
- Kept pinned deliberately: `immich_postgres` (`14-vectorchord0.4.3`) and valkey
  (SHA-pinned) — databases; moving those to rolling tags risks an unplanned major
  upgrade (same class of landmine as the paperless DB downgrade).
- `upgrade-procedures.md` now has concrete pull-then-recreate recipes for both apps.

## Observations

- Both jellyfin and immich LXCs run a hand-launched `portainer_agent` container
  (up 4 months) that is not in any compose file — not Ansible-managed, survives
  deploys.
