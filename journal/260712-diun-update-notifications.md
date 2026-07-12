# Diun: Pushover notifications for image updates fleet-wide

**Date:** 2026-07-12

## What was built

Diun (`crazymax/diun`) deployed on the infra VM (`roles/infra_vm`, tag `diun`),
watching **29 rolling-tag images across all hosts** via the file provider (it polls
registries directly — no per-host agents or docker-socket access needed). Weekly
check (Monday 09:00), one Pushover notification per updated image, using the pve
Pushover app token (swap `diun_pushover_token` in role defaults for a dedicated
app label). Test wiring verified: `docker exec diun diun notif test` delivered.

Watch list: `roles/infra_vm/templates/diun-images.yml.j2` — primary apps (jellyfin,
immich ×3, open-webui, navidrome), media stack (sonarr/radarr/qbittorrent/bazarr/
prowlarr/gluetun/slskd/jellyseerr/booklore), music extras, infra (grafana,
prometheus, portainer, mktxp, traefik:v3.1, diun itself), the latest-camp
monitoring sidecars, syncthing, iperf3. Deliberately excluded: self-built
`ghcr.io/johnmathews/*` images, databases, and pinned images. Known noise source:
linuxserver.io images rebuild weekly.

New make targets to apply upgrades in one command:

- `make jelly-upgrade` — pull base, rebuild `jellyfin-with-yt-dlp`, recreate,
  health-check with version print
- `make immich-upgrade` — pull the three release/latest images, `make immich`,
  health-check via `/api/server/version`

## Gotchas hit

- `pull: never` strikes again: first deploy failed because `crazymax/diun:latest`
  wasn't cached on infra. Pre-pull before adding any new service to a compose stack.
- **Diun found a real bug on its first scan**: `booklore/booklore` on Docker Hub is
  dead ("access denied") — BookLore moved to `ghcr.io/booklore-app/booklore`. The
  media-vm compose template still referenced the dead path, meaning the running
  container could never be re-pulled. Fixed the template, pre-pulled the ghcr image
  on media-vm; the next `make media` will recreate booklore onto it.
