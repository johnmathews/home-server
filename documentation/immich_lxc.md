# Immich Photo Management

## Purpose

Self-hosted photo and video management platform with machine learning features (face recognition,
object detection, smart search). Replaces Google Photos.

## Quick Reference

```
+-----------------------+--------------------------------------------------+
| Host                  | immich_lxc (192.168.2.113)                       |
| SSH                   | ssh immich                                       |
| Web UI                | immich.itsa-pizza.com                            |
| Public shares         | share.itsa-pizza.com                             |
| API port              | 2283                                             |
| Docker compose dir    | /srv/apps                                        |
| Ansible               | make immich                                      |
| Role                  | roles/immich_lxc                                 |
+-----------------------+--------------------------------------------------+
```

## Docker Containers

```
+-------------------------+------------------------------------------------------------------+-------+
| Container               | Image                                                            | Port  |
+-------------------------+------------------------------------------------------------------+-------+
| immich_server           | ghcr.io/immich-app/immich-server:release                          | 2283  |
| immich_machine_learning | ghcr.io/immich-app/immich-machine-learning:release                | -     |
| immich_postgres         | ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0    | -     |
| immich-redis            | valkey/valkey:8-bookworm (pinned by SHA)                          | -     |
| immich_public_proxy     | alangrainger/immich-public-proxy:{{ immich_public_proxy_version }}| 3000  |
| image_borders           | ghcr.io/johnmathews/image-borders:{{ image_borders_version }}     | -     |
| cadvisor                | gcr.io/cadvisor/cadvisor:{{ cadvisor_version }}                   | 18080 |
| node_exporter           | quay.io/prometheus/node-exporter:{{ node_exporter_version }}      | 9100  |
| alloy                   | grafana/alloy:{{ alloy_version }}                                 | 12345 |
+-------------------------+------------------------------------------------------------------+-------+
```

Version pins live in `roles/immich_lxc/defaults/main.yml` (currently: public proxy `latest`,
cadvisor `v0.49.1`, node_exporter `v1.8.2`, alloy `v1.5.1`, image_borders `latest`).

### Container Details

- **immich_server**: Main application server. Runs as user 1001:1001. Serves the web UI and API.
- **immich_machine_learning**: Handles face recognition, object detection, and smart search. Stores
  models in a Docker volume (`model-cache`). Runs as user 1001:1001. No hardware acceleration configured
  (CPU inference).
- **immich_postgres**: PostgreSQL 14 with VectorChord 0.4.3 (plus pgvecto.rs 0.2.0 for migration
  compatibility) for vector similarity search (used by smart search/CLIP). Configured with
  `--data-checksums` and `DB_STORAGE_TYPE: HDD` optimization. 128MB shared memory (`shm_size`).
- **immich-redis**: Valkey (Redis-compatible) for caching and job queues. Pinned by SHA digest.
- **immich_public_proxy**: Public-facing proxy for shared albums. Accessible at `share.itsa-pizza.com`.
  Points to Immich server at `http://192.168.2.113:2283`.
- **image_borders**: Custom tool for adding borders to reference photos. Uses Docker profiles
  (`image-borders`) so it only runs when explicitly invoked.

## Storage

### NFS Mounts

Photos are stored on TrueNAS via NFS:

- `/mnt/nfs/photos` — Main photo library (mounted into immich_server)
- `/mnt/nfs/photos/immich` — Immich upload directory (`UPLOAD_LOCATION` in `.env.j2`)

### Docker Volumes

- `model-cache` — ML model cache (named Docker volume)
- `/srv/apps/immich/postgres` — PostgreSQL data directory (local disk; `DB_DATA_LOCATION`)
- `/srv/apps/immich/` — local dir holding only the postgres data dir and the API key file
  (uploads are NOT here — they live on the NFS share, see above)

## Environment Variables

Configuration is split between `.env` file and `/etc/environment`:

### .env file (`/srv/apps/.env`)

Deployed from `roles/immich_lxc/templates/.env.j2`. Contains:
- `IMMICH_VERSION` — Image version tag
- `UPLOAD_LOCATION` — Upload directory path
- `DB_PASSWORD`, `DB_USERNAME`, `DB_DATABASE_NAME` — PostgreSQL credentials
- `DB_DATA_LOCATION` — PostgreSQL data directory

### System environment (`/etc/environment`)

Set via Ansible `lineinfile` tasks for use by cron jobs and scripts:
- `IMMICH_API_KEY` — API key for automation (`vault_immich_media_vm_api_key`)
- `IMMICH_LIBRARY_ID` — Reference library ID
- `IMMICH_API_URL` — API endpoint URL
- `IMMICH_SHARE_USER` — Hardcoded to "John"
- `PUSHOVER_USER_KEY` — Push notification user key
- `PUSHOVER_APP_TOKEN` — Push notification app token

These are the same variables set on the media VM.

## External Access

Immich is proxied through Traefik (not directly through Cloudflare Zero Access) because the mobile
app needs direct API access without authentication redirects.

```
Cloudflare -> Tunnel -> cloudflared -> Traefik (192.168.2.108) -> Immich (192.168.2.113:2283)
```

- `immich.itsa-pizza.com` — Main UI and API (via Traefik `immich` router)
- `share.itsa-pizza.com` — Public share proxy (via Traefik `immich-share` router, points to port 3000)

Traefik applies rate limiting on auth routes (200/s avg, 300 burst) and security headers.

## Ansible Tags

```sh
make immich                    # Full deployment
make immich t=docker           # Docker compose and .env only
make immich t=alloy            # Alloy log shipping config only
make immich t=immich           # Environment variables only
make immich t=pushover         # Pushover notification vars only
```

## Vault Variables Used

- `vault_immich_media_vm_api_key`
- `vault_immich_reference_library_id`
- `vault_immich_api_url`
- `vault_pushover_user_key`
- `vault_pushover_media_vm_app_api_token`
- Database credentials (in `.env.j2` template)

## Backup Strategy

- **Photos**: Stored on TrueNAS NFS share — backed up via TrueNAS ZFS snapshots
- **Database**: PostgreSQL data in `/srv/apps/immich/postgres` — backed up via PBS (whole LXC backup)
- **ML models**: Cached in Docker volume — can be re-downloaded (no backup needed)
- **Thumbnails/previews**: Generated from originals — can be regenerated (no backup needed)

## Known Issues

- **ML model re-indexing**: After major Immich upgrades, the ML model may need to re-index all photos.
  This is CPU-intensive and can take hours.
- **No GPU acceleration**: Machine learning runs on CPU. Consider adding GPU passthrough if inference
  is too slow.
- **image_borders tool**: Must be run manually with `docker compose --profile image-borders up image-borders`.

## Upgrading

1. Check Immich release notes — breaking changes are common
2. Update `IMMICH_VERSION` in the `.env.j2` template
3. Run `make immich t=docker`
4. Check logs: `ssh immich && docker logs immich_server`
5. If ML models changed, wait for re-indexing to complete
