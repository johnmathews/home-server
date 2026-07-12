# Jellyfin LXC

- IP: 192.168.2.110
- SSH: `ssh jelly`
- Ansible: `make jelly`, role: `roles/jellyfin_lxc`
- LXC config: 12 CPU cores, 6144 MB RAM (was 4 GB; raised ~2026-06-28)
- Docker compose: `roles/jellyfin_lxc/files/docker-compose.yml`

## Containers

| Container     | Port  | Image                                    |
|---------------|-------|------------------------------------------|
| jellyfin      | 8096  | jellyfin-with-yt-dlp:latest (custom)     |
| alloy         | 12345 | grafana/alloy:v1.5.1                     |
| cadvisor      | 18080 | gcr.io/cadvisor/cadvisor:v0.49.1         |
| node_exporter | 9100  | quay.io/prometheus/node-exporter:v1.8.2  |

The jellyfin container runs with `mem_limit: 4g` / `mem_reservation: 1g` — **the limit must stay
below the LXC's 6 GB** (see the ffprobe OOM brownout section for why). The sidecars are capped
too (alloy/cadvisor 512m, node_exporter 128m; ~10× their typical usage) so no single container
can starve the LXC.

## Jellyfin version

As of 2026-07-04: **Jellyfin 10.11.7** (image built 2026-04-01 from `jellyfin/jellyfin:latest`
with yt-dlp added via custom Dockerfile — the tag is `latest`, so the actual version only moves
when the image is rebuilt).

## NFS media mounts

```
/mnt/nfs/library     → /library        (kids shows, family movies, etc.)
/mnt/nfs/media       → /media
/mnt/nfs/movies      → /movies
/mnt/nfs/youtube-kids→ /youtube-kids   (read-only, TubeArchivist library)
```

## Libraries (18 total)

Collections, Create, Gym, Heavy Club Basics, Heavy Club Exercise Tutorials, Humanity,
Kettlebell Compilations, Kids Movies, Kids Shows, Kids Youtube, Math + Engineering, Movies,
Our Movies, Shows, Sport, Travel, Turkish Get-Up, Ukraine Lectures.

The five club/kettlebell/Ukraine libraries were added 2026-07-01, each pointing at a
`/movies/youtube/<subdir>` path. **New libraries default to real-time monitoring ON** — turn it
off when creating NFS-backed libraries (see below).

Library configs: `/srv/apps/jellyfin/appdata/root/default/<name>/options.xml`

## Plugins

- Fanart
- Playback Reporting
- Reports
- Subtitle Extract
- TMDb Box Sets
- TubeArchivistMetadata (+ Kids variant)
- YouTube Metadata (single version `1.0.3.15`; the duplicate-folder landmine was cleaned 2026-07-01)

## Real-time library monitoring (disabled)

**Status:** Disabled on all 17 NFS-backed libraries. Enabled only on Collections (local disk).
(Drift note: the 5 libraries added 2026-07-01 + Create were created with monitoring ON — Jellyfin's
default for new libraries — and were switched off 2026-07-04. Check for drift after adding any
library.)

**Why:** Jellyfin 10.11.x has a regression where `FileSystemWatcher` on NFS causes ~11% idle
CPU. inotify doesn't work on NFS anyway — the watchers just poll uselessly. This is a known
upstream issue: https://github.com/jellyfin/jellyfin/issues/15815 (still open as of 2026-03-17).

**What still works:** Scheduled library scans (task "Scan Media Library" / `RefreshLibrary`) detect
new/changed media. Note the schedule is currently **7×/day** (09/11/13/15/17/19/21:00), not every
12 h — see "Scheduled scan I/O brownout" below.

**Config location:** `<EnableRealtimeMonitor>false</EnableRealtimeMonitor>` in each library's
`options.xml` at `/srv/apps/jellyfin/appdata/root/default/<library>/options.xml`.

**To toggle for all libraries except Collections** (works regardless of which libraries exist;
flip true/false as needed — run with the container stopped so Jellyfin doesn't rewrite the files):
```bash
ssh jelly
cd /srv/apps && docker compose stop jellyfin
for f in /srv/apps/jellyfin/appdata/root/default/*/options.xml; do
  case "$f" in */Collections/*) continue ;; esac
  sed -i 's|<EnableRealtimeMonitor>true|<EnableRealtimeMonitor>false|' "$f"
done
docker compose start jellyfin
```

**To verify current state:**
```bash
ssh jelly "grep EnableRealtimeMonitor /srv/apps/jellyfin/appdata/root/default/*/options.xml"
```

## Recurring 10–20 min brownouts: ffprobe OOM loop (ROOT CAUSE, found 2026-07-04)

**This was the actual cause of the daily brownouts from ~2026-06-28 through 2026-07-04.** The
scan-concurrency work below (2026-07-01/02) was real but secondary — the outages continued because
of this loop, which ran underneath the whole time.

**Mechanism:** `Abominable (2019) WEBDL-1080p.mkv` (Kids Movies, 6.4 GB) had a corrupt Matroska
seek index (SeekHead/Cues) — linear playback/demux was fine, but Jellyfin 10.11's media-info probe
(`ffprobe ... -show_frames -only_first_vframe`) follows the cues, lands on garbage EBML elements
("unknown-length element", "invalid as first byte of an EBML number"), and **balloons to ~5.5 GB
anon RSS**. That exhausted the 6 GB LXC cgroup → the whole box entered reclaim thrash (D-state
pileup, `node_load1` up to 102 while CPU stays <50%, Kestrel thread-pool starvation, docker.sock
and node_exporter statfs all hang) → after 0.5–20 min the kernel memcg OOM killer killed ffprobe →
scan completed → instant recovery. Because ffprobe never finished, Jellyfin never saved probe data
for the item and **re-probed it on every scheduled scan** — one OOM kill per scan, every scan
(verify: `ssh pve "journalctl -k | grep 'Memory cgroup out of memory'"` — the kernel is shared, so
guest OOMs appear in the pve journal).

**Why the outage length varied (22 s → 24 min):** it's the time the box thrashes before the OOM
killer fires — short when RAM is mostly free at scan start, long when page cache is full. Raising
LXC RAM 4 GB → 6 GB (~Jun 28) made episodes *longer*, not better.

**Trigger for the item re-probe:** new `.srt` subtitle files added 2026-06-26 invalidated the item's
media info; the file itself had been in the library (corrupt) since 2025-10.

**Fix applied 2026-07-04:**

1. **Container memory cap fixed** (the fix that actually ended the outages) in
   `roles/jellyfin_lxc/files/docker-compose.yml`: `mem_limit` was **8g on a 6 GB LXC** (could never
   trigger — the LXC wall was always hit first). Now `mem_limit: 4g`, `mem_reservation: 1g`,
   transcode tmpfs 4g → 2g (tmpfs pages count against the container's limit). A runaway ffprobe is
   now killed inside the container cgroup in ~10 s; the LXC keeps ~2 GB headroom. Verified on the
   15:00 scan 2026-07-04: scan completed in 32 s, load ~4, UI up, ffprobe killed at 3.8 GB inside
   the docker cgroup with zero box-wide impact.
2. **The bad title was deleted entirely** (John's call — movie not worth keeping). Note: a
   lossless remux (`-c copy`) had been tried first and did **not** stop the balloon — the bug is
   keyed to the title's stream data, not (only) its corrupt cues. If Radarr still monitors
   Abominable (2019) it may re-grab it; a different encode is unlikely to trigger the bug, and
   the ffprobe wrapper (below) makes it harmless if it does.
3. **ffprobe wrapped with `ulimit -v 3G`** in the custom Dockerfile
   (`roles/jellyfin_lxc/files/dockerfile`): key discovery — when the oversized allocation FAILS,
   ffprobe falls back to a sane path and completes with full valid JSON in seconds (verified on
   the bad file and 486 swept files; a 4K remux probes fine through it). The wrapper converts any
   future balloon into a graceful completion **with metadata saved**, so no retry loop can form.
   `ffmpeg` itself is not wrapped (transcodes legitimately need memory). Dockerfile changes are
   applied by `make jelly` — the "Copy dockerfile" task notifies the "Rebuild jellyfin image"
   handler (`build: always`, added 2026-07-04), which rebuilds and recreates the container.
   The rebuild reuses the locally cached base image (`pull: never`), so it can't silently
   upgrade Jellyfin; it does refresh yt-dlp (ADD-from-URL layer).

**Diagnosis recipe for "Jellyfin down N minutes, self-recovered":** check pve journal for memcg OOM
kills first. To catch a runaway live:
`nohup sh -c 'for i in $(seq 1 1200); do date +%H:%M:%S; ps -eo rss=,args= | grep [f]fprobe; sleep 2; done' > /tmp/ffprobe-watch.log &`
then read the biggest RSS lines — the culprit file path is in the ffprobe command line.

## Scheduled scan I/O brownout (2026-07-01) — contributing factors, superseded

**Note (2026-07-04):** the analysis below identified real amplifiers (12-way metadata fan-out,
blocking trickplay) and the applied settings are kept, but the recurring outages were caused by the
ffprobe OOM loop above, not by scan concurrency alone.

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

**What actually triggered the recurrence (2026-07-02):** ~220 new videos were imported into
`/movies/youtube` ~1 week prior (all files dated 8–14 days ago, none since). Every scan since has
been running metadata refresh + chapter-image extraction + **trickplay generation** on that backlog.
Two settings turned that into a box-wide brownout: `LibraryMetadataRefreshConcurrency=0` (fans across
all 12 vCPUs) **and** trickplay `ScanBehavior=Blocking` (trickplay ffmpeg runs *inside* the scan
instead of as a background task). Jellyfin is 10.11.7 (unchanged since the 2026-04-01 image build), so
this is a workload/config interaction, not a version regression.

**Remediation (APPLIED 2026-07-02 — final state, keeps chapter images + trickplay):**

1. **`LibraryMetadataRefreshConcurrency` `0` → `4`** in `system.xml`. The master throttle: max items
   metadata-refreshed in parallel. `0` = auto = 12-way = the herd. `4` processes a large import
   steadily without saturating CPU or the NFS link (chapter extraction is NFS-IO-bound — do not exceed
   4 here even with spare cores). This is the single biggest lever.
2. **Trickplay `ScanBehavior` `Blocking` → `NonBlocking`** in `system.xml` (`<TrickplayOptions>` block).
   Moves trickplay generation out of the scan into a background task (already `BelowNormal` priority),
   so the scan finishes fast while trickplay grinds gently afterward. Chapter images and trickplay are
   both retained.
3. Scan frequency left at **7×/day** (my interim 2×/day cut was reverted — the two changes above make
   frequent scans cheap, so the cut is unnecessary). `LibraryScanFanoutConcurrency` (4) and
   `ParallelImageEncodingLimit` (4) left as-is.

Backups on host: `config/system.xml.bak-20260702-151439` (pre-change),
`config/system.xml.bak-20260702-155424` (interim), and the original trigger file
`...7738148f-...js.bak-20260702-151439`. Verified all values persisted across restart. Next levers if a
brownout ever recurs: `EnableKeyFrameOnlyExtraction` `false`→`true` (cheaper trickplay ffmpeg), then
`LibraryScanFanoutConcurrency` `4`→`2`.

_Superseded interim fix (kept for reference): initially cut scans to 2×/day and set
`LibraryMetadataRefreshConcurrency=2`; both were revised above once the trickplay `Blocking` root cause
was found._

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

Running 10.11.7 (has the 10.11.5/10.11.6 fixes above); the core NFS monitoring issue (#15815)
persists, which is why real-time monitoring stays disabled.

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
The YouTube Metadata plugin throws `DirectoryNotFoundException: .../ytvideo.info.json` for video IDs
that yt-dlp can't fetch (deleted / private / geoblocked): no cache dir gets written, and every scan
re-tries them. **The cache itself is not broken** — `/srv/apps/jellyfin/cache/youtubemetadata` is
populated. They're log noise, **not** an outage cause. The only real cleanup is deleting the source
media files for genuinely dead videos so the plugin stops retrying — done 2026-07-04 for the three
known dead IDs (`foYNUVFoZe0`, `NJTdu309d3E`, `VZcPKF2FOm0`). If new ones appear, find them with:
`grep -h "DirectoryNotFoundException.*youtubemetadata" /srv/apps/jellyfin/appdata/log/log_*.log | grep -oE "youtubemetadata/[^/]+" | sort -u`
then `find /mnt/nfs/movies/youtube -name "*<id>*" -delete` on jelly.
