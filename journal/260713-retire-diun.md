# Diun retired: exporter-based freshness is the single update-visibility system

**Date:** 2026-07-13

## Why

Diun (added 2026-07-12) and the image-freshness exporter (added the same day)
overlapped almost entirely, and the exporter wins on every axis: it knows what is
actually *running* (Diun only knows the registry changed), it auto-discovers all
~108 containers on 12 hosts (Diun needed a hand-curated watch list that went stale
within a day — booklore), and it feeds a dashboard + alerting. First Monday's
notifications confirmed the overlap: two Pushover streams saying similar things.

## Changes

1. Diun removed: compose service, tasks/diun.yml, watch-list template, defaults,
   handler, .env vars; container/image/data dir cleaned off the infra VM. The
   Monday 09:00 Diun digest is gone.
2. Replacement fast lane: Grafana rule **"App update available"** (folder
   Containers, uid dfryl87q8k0lcd) — `container_image_outdated == 1 for 24h`
   filtered to immich_server, jellyfin, navidrome, open-webui; Pushover, weekly
   repeat. Edit the container_name regex to change the tracked set.
3. The 30-day "Container image stale" digest stays as the long-tail safety net.

## Known blind spot (accepted, documented)

jellyfin runs the locally-built `jellyfin-with-yt-dlp` image → freshness status
`local`, never `outdated` — so nothing automatically signals new Jellyfin
releases anymore (Diun watched the base image). Options: run `make jelly-upgrade`
periodically, or teach the exporter base-image freshness for local builds
(suggested follow-up for the container-status-exporter repo, alongside its
in-flight code review).
