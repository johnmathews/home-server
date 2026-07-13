# Jellyfin blind spot closed: base-image freshness for local builds

**Date:** 2026-07-13

The exporter learned to follow the OCI `org.opencontainers.image.base.name`
annotation (implemented in container-status-exporter, commit 0317c4d, on top of
the engineering-team review's hardened registry client — 202 tests). This repo's
side: one LABEL in `roles/jellyfin_lxc/files/dockerfile` naming
`docker.io/jellyfin/jellyfin:latest`, rebuilt via `make jelly t=docker`.

Result: jellyfin — the original 8-months-stale offender — is now covered by the
same `container_image_outdated` metric, dashboard, and "App update available"
fast-lane alert as everything else. `container_image_info` gained a `base_image`
label (visible in the dashboard inventory table).

Caveat (documented in upgrade-procedures.md and the exporter docs): the
comparison is local-base-tag vs registry, assuming pull and rebuild happen
together — `make jelly-upgrade` does exactly that.
