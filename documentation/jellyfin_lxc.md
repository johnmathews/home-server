# Jellyfin LXC

- IP: 192.168.2.110
- SSH: `ssh jelly`
- Ansible: `make jellyfin`, role: `roles/jellyfin_lxc`
- LXC config: 8 CPU cores, 4096 MB RAM
- Docker compose: `roles/jellyfin_lxc/files/docker-compose.yml`

## Containers

| Container     | Port  | Image                                   |
|---------------|-------|-----------------------------------------|
| jellyfin      | 8096  | jellyfin-with-yt-dlp:latest (custom)    |
| alloy         | 12345 | grafana/alloy:latest                    |
| cadvisor      | 18080 | gcr.io/cadvisor/cadvisor:latest         |
| node_exporter | 9100  | quay.io/prometheus/node-exporter:latest |
| portainer_agent|      | portainer/agent:latest                  |

## Jellyfin version

As of 2026-03-17: **Jellyfin 10.11.2** (latest is 10.11.6). Uses `jellyfin/jellyfin:latest`
base image with yt-dlp added via custom Dockerfile.

## NFS media mounts

```
/mnt/nfs/library     → /library        (kids shows, family movies, etc.)
/mnt/nfs/media       → /media
/mnt/nfs/movies      → /movies
/mnt/nfs/youtube-kids→ /youtube-kids   (read-only, TubeArchivist library)
```

## Libraries (15 total)

Collections, Create, Gym, Humanity, Kids Movies, Kids Shows, Kids Youtube,
Math + Engineering, Movies, Music, Our Movies, Shows, Sport, Travel, YouTube.

Library configs: `/srv/apps/jellyfin/appdata/root/default/<name>/options.xml`

## Plugins

- Fanart
- Playback Reporting
- Reports
- Subtitle Extract
- TMDb Box Sets
- TubeArchivistMetadata (+ Kids variant)
- YouTube Metadata (two versions installed: 1.0.3.12 and 1.0.3.15)

## Real-time library monitoring (disabled)

**Status:** Disabled on all 14 NFS-backed libraries. Enabled only on Collections (local disk).

**Why:** Jellyfin 10.11.x has a regression where `FileSystemWatcher` on NFS causes ~11% idle
CPU. inotify doesn't work on NFS anyway — the watchers just poll uselessly. This is a known
upstream issue: https://github.com/jellyfin/jellyfin/issues/15815 (still open as of 2026-03-17).

**What still works:** Scheduled library scans run every 12 hours and detect new/changed media.

**Config location:** `<EnableRealtimeMonitor>false</EnableRealtimeMonitor>` in each library's
`options.xml` at `/srv/apps/jellyfin/appdata/root/default/<library>/options.xml`.

**To re-enable** (e.g. if a future Jellyfin version fixes the regression):
```bash
ssh jelly
for lib in Create Gym Humanity 'Kids Movies' 'Kids Shows' 'Kids Youtube' \
  'Math + Engineering' Movies Music 'Our Movies' Shows Sport Travel YouTube; do
  sed -i 's|<EnableRealtimeMonitor>false|<EnableRealtimeMonitor>true|' \
    "/srv/apps/jellyfin/appdata/root/default/$lib/options.xml"
done
docker restart jellyfin
```

**To verify current state:**
```bash
ssh jelly "grep EnableRealtimeMonitor /srv/apps/jellyfin/appdata/root/default/*/options.xml"
```

## 10.11.x known issues

- **Repeated NFS rescanning** ([#15815](https://github.com/jellyfin/jellyfin/issues/15815)) — still open
- **Parallel scan overload on NFS** ([#15728](https://github.com/jellyfin/jellyfin/issues/15728)) — fixed in 10.11.5
- **`.ignore` directory churn** ([#16021](https://github.com/jellyfin/jellyfin/issues/16021)) — partially fixed in 10.11.6
- **API/scanning performance degradation** ([#15352](https://github.com/jellyfin/jellyfin/issues/15352))

Consider upgrading to 10.11.6 for incremental fixes, but the core NFS monitoring issue persists.

## Trickplay

Trickplay image generation is enabled with hardware acceleration (VAAPI via `/dev/dri/renderD128`).
Runs daily as a scheduled task, takes ~37 minutes. Data stored in `/config/data/trickplay/` (~831 MB).

## Troubleshooting

### High idle CPU (~11%)
Likely real-time monitoring on NFS. Check with:
```bash
ssh jelly "docker stats --no-stream"
ssh jelly "docker logs jellyfin --since 5m 2>&1 | grep 'Watching directory'"
```
If you see "Watching directory" lines for NFS paths, monitoring has been re-enabled.

### YouTubeMetadata errors in logs
The YouTube Metadata plugin throws `DirectoryNotFoundException` for cache files. This is
non-critical — it just means metadata cache misses for some videos. The errors appear during
library scans but don't cause issues.
