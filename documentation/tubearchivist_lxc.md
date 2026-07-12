# TubeArchivist

## Purpose

Self-hosted YouTube video archiver. Downloads, indexes, and organizes YouTube videos with
full-text search via Elasticsearch. Used primarily for archiving kids' content.

## Quick Reference

```
+-----------------------+--------------------------------------------------+
| Host                  | tubearchivist_lxc (192.168.2.116)                |
| SSH                   | ssh tubearchivist (user: root)                   |
| Web UI                | tube.itsa-pizza.com                              |
| Port                  | 8000                                             |
| Docker compose dir    | /srv/apps                                        |
| Ansible               | make tube                                        |
| Role                  | roles/tubearchivist_lxc                          |
+-----------------------+--------------------------------------------------+
```

## Docker Containers

```
+-------------------+----------------------------------------------------------+-------+-------------------------------+
| Container         | Image                                                    | Port  | Purpose                       |
+-------------------+----------------------------------------------------------+-------+-------------------------------+
| tubearchivist     | bbilly1/tubearchivist:{{ tubearchivist_version }}         | 8000  | Main web app + downloader     |
| archivist-es      | elasticsearch:8.18.0                                     | 9200* | Full-text search + indexing   |
| archivist-redis   | redis/redis-stack-server:7.4.0-v3                        | 6379* | Task queue + caching          |
| alloy             | grafana/alloy:{{ alloy_version }}                         | 12345 | Log shipping to Loki          |
| node_exporter     | quay.io/prometheus/node-exporter:{{ node_exporter_version }} | 9100 | Host metrics for Prometheus |
| cadvisor          | gcr.io/cadvisor/cadvisor:{{ cadvisor_version }}           | 18080 | Container metrics             |
+-------------------+----------------------------------------------------------+-------+-------------------------------+
```

*Ports marked with `*` are internal only (exposed within Docker network, not on host).

Version pins live in `roles/tubearchivist_lxc/defaults/main.yml` (currently: tubearchivist
`v0.5.10`, alloy `v1.5.1`, node_exporter `v1.8.2`, cadvisor `v0.49.1`).

### Container Details

- **tubearchivist**: Main application. Auto-updates yt-dlp (`TA_AUTO_UPDATE_YTDLP=release`).
  Health check hits `/api/health/` every minute. Depends on Elasticsearch and Redis.
- **archivist-es**: Elasticsearch 8.18.0 with security enabled (`xpack.security.enabled=true`).
  Java heap: 1GB min/max (`-Xms1g -Xmx1g`). Single-node discovery. Memory lock disabled
  (ulimits set for unlimited memlock).
- **archivist-redis**: Redis Stack Server (`redis/redis-stack-server:7.4.0-v3`) for task queue.
  Depends on Elasticsearch being up first.

## Storage

### NFS Mounts

```
+---------------------------+----------------------------+
| Mount Point               | TrueNAS Share              |
+---------------------------+----------------------------+
| /mnt/nfs/youtube-kids     | /mnt/tank/youtube-kids     |
+---------------------------+----------------------------+
```

The NFS share is mounted into the tubearchivist container at `/youtube`. This share is also
mounted read-only into the Jellyfin LXC at `/youtube-kids` for playback.

### Docker Volumes

- `cache` — TubeArchivist download cache and thumbnails
- `redis` — Redis persistence
- `es` — Elasticsearch data and snapshots
- `media` — declared in the compose template (currently unused; the media path is the NFS bind mount)

## Configuration

### Host Variables (`host_vars/tubearchivist_lxc.yml`)

- NFS share: `youtube-kids` mounted at `/mnt/nfs/youtube-kids`
- Sleep hours: disabled (`sleep_hours_enabled: false`) but containers are configured
  to stop (not pause) during quiet hours: `tubearchivist`, `archivist-es`, `archivist-redis`

### Vault Variables

- `vault_ta_elastic_search_password` — Elasticsearch password
- `vault_ta_password` — TubeArchivist web UI password
- `vault_tubearchivist_key` — API key (used by Homepage widget)

### Role Defaults (`roles/tubearchivist_lxc/defaults/main.yml`)

- `tubearchivist_host` — Allowed hosts: `https://tube.{{ primary_domain_name }} 192.168.2.116:8000`
- `ta_username: john` — Web UI username

## External Access

Accessible via Cloudflare Tunnel with Zero Access protection:

- `tube.itsa-pizza.com` → `192.168.2.116:8000`

## Quiet Hours Integration

Although sleep hours scheduling is disabled, the configuration is in place:
- Containers are stopped (not paused) because Elasticsearch doesn't handle pause/unpause gracefully
- NFS/SMB share control is disabled (`sleep_hours_nfs_smb_enabled: false`)
- Uptime Kuma monitoring ID: `tubearchivist: 43`

## Jellyfin Integration

The `youtube-kids` NFS share is mounted read-only into the Jellyfin LXC, allowing Jellyfin
to serve archived YouTube content as a media library. The mount must be read-only to prevent
Jellyfin from modifying the archive.

## Troubleshooting

- **Elasticsearch out of memory**: Check Java heap with `docker logs archivist-es`. The 1GB heap
  may need increasing for large libraries. Edit `ES_JAVA_OPTS` in the docker-compose template.
- **Downloads failing**: yt-dlp auto-updates on container restart. Force an update by restarting
  the tubearchivist container: `docker restart tubearchivist`
- **Health check failing**: The `curl`-based health check requires `curl` inside the container.
  If the container image changes and removes curl, the health check will fail.
- **Search not working**: Elasticsearch may need time to reindex after a restart. Check ES health:
  `curl -u elastic:<password> http://localhost:9200/_cluster/health`

## Upgrading

1. TubeArchivist is pinned — bump `tubearchivist_version` in `roles/tubearchivist_lxc/defaults/main.yml`
2. Elasticsearch is pinned to `8.18.0` — update in the docker-compose template
3. Run `make tube`
4. After Elasticsearch upgrades, the index may need rebuilding via the TubeArchivist web UI
