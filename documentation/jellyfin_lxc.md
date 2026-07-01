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

**What still works:** Scheduled library scans (task "Scan Media Library" / `RefreshLibrary`) detect
new/changed media. Note the schedule is currently **7×/day** (09/11/13/15/17/19/21:00), not every
12 h — see "Scheduled scan I/O brownout" below.

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

## Scheduled scan I/O brownout (2026-07-01)

**Symptom:** Jellyfin web UI becomes unresponsive / "down" for ~20 min at a stretch, several times a
day, while the container stays *running* and even reports healthy. During the episode: `node_load1`
spikes to ~80 on 12 vCPU, `docker.sock` times out (alloy/portainer can't reach the daemon), cadvisor's
own fs-usage scans balloon to 9+ min, and Jellyfin logs Kestrel *"thread pool starvation"* warnings.

**This is NOT the plugin restart-loop landmine** — the container does not restart (no startup logs,
steady CPU). It's a transient overload, and it self-resolves once the scan finishes (load drains back
to <2). A container restart clears lingering state but does not prevent recurrence.

**Root cause:** the "Scan Media Library" task (`RefreshLibrary`, task id `7738148f...`) is scheduled
**7×/day** (09/11/13/15/17/19/21:00). Each run took ~24 min on 2026-07-01 (13:00:00→13:23:47 UTC).
Two settings amplify each run into a full-box brownout:

```
system.xml  (/srv/apps/jellyfin/appdata/config/system.xml)
  LibraryScanFanoutConcurrency      = 4   # libraries scanned in parallel
  LibraryMetadataRefreshConcurrency = 0   # 0 = AUTO = #cores = 12-way metadata refresh  <-- worst offender
  ParallelImageEncodingLimit        = 4   # parallel ffmpeg image encodes
```

With `LibraryMetadataRefreshConcurrency=0`, metadata refresh (ffmpeg chapter/trickplay image
extraction + YouTube Metadata yt-dlp network fetches) fans out across all 12 vCPUs, saturating disk
and CPU. The YouTube-metadata `DirectoryNotFoundException` errors are noise, not the cause — the cache
is healthy (see below).

**Proposed remediation (not yet applied — decide + apply via container-stopped file edits or the UI):**

1. Cut scan frequency. The intent was ~2×/day; 7×/day is excessive. Edit the trigger file
   `/srv/apps/jellyfin/appdata/config/ScheduledTasks/7738148f-fcd0-7979-c7ce-b148e06b3aed.js` down to
   two daily triggers, e.g. 09:00 and 21:00 (ticks = hour × 3.6e10):
   ```json
   [{"Type":"DailyTrigger","TimeOfDayTicks":324000000000},{"Type":"DailyTrigger","TimeOfDayTicks":756000000000}]
   ```
   (Ticks reference: 09:00=324e9, 11:00=396e9, 13:00=468e9, 15:00=540e9, 17:00=612e9, 19:00=684e9,
   21:00=756e9.) Or set the trigger to an `IntervalTrigger` of 12 h in the UI.
2. Cap metadata-refresh concurrency so a scan can't monopolise the box. In `system.xml` set
   `LibraryMetadataRefreshConcurrency` to `2` (from `0`). This is the single biggest lever.

**How to apply safely:** Jellyfin rewrites `system.xml` and the `ScheduledTasks/*.js` trigger files on
shutdown, so **stop the container before hand-editing them**, or they'll be overwritten:
```bash
ssh jelly
cd /srv/apps && docker compose stop jellyfin
# edit system.xml / ScheduledTasks/7738148f-*.js
docker compose start jellyfin
```
The scan schedule can also be changed live in the UI (Dashboard → Scheduled Tasks → Scan Media
Library → Triggers); `LibraryMetadataRefreshConcurrency` is not exposed in the UI, so it needs the
file edit. These configs live in `appdata` (Jellyfin runtime state) and are **not** Ansible-managed.

## Scheduled tasks reference

Task trigger configs: `/srv/apps/jellyfin/appdata/config/ScheduledTasks/<task-id>.js`
Last-run results (incl. task Name/Key): `/srv/apps/jellyfin/appdata/data/ScheduledTasks/<task-id>.js`

Trigger tick math: `TimeOfDayTicks ÷ 3.6e10 = hour of day`. Key task ids on this host:

```
7738148f-fcd0-7979-c7ce-b148e06b3aed  RefreshLibrary          Scan Media Library (7×/day — see brownout)
```

To map any task id → name: `cat data/ScheduledTasks/<id>.js` and read its `"Name"`/`"Key"` fields.

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
The YouTube Metadata plugin throws `DirectoryNotFoundException: .../ytvideo.info.json` for a handful
of video IDs. **The cache is not broken** — `/srv/apps/jellyfin/cache/youtubemetadata` is populated
(e.g. 224/225 dirs had a valid `ytvideo.info.json` on 2026-07-01). The errors are per-video: yt-dlp
couldn't fetch metadata for those IDs (deleted / private / geoblocked), so no dir was written, and
every scan re-tries them. They're log noise, **not** an outage cause — nothing to repair in the cache.
The only real cleanup is removing the source media entries for genuinely dead videos so the plugin
stops retrying. Note these fetches *do* add load during scans; see "Scheduled scan I/O brownout".
