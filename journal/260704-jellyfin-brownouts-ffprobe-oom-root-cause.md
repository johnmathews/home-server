# Jellyfin daily brownouts: ffprobe OOM loop on corrupt MKV (real root cause)

**Date:** 2026-07-04

## Problem

Jellyfin LXC "down" ~10–20 min, self-recovering, one or more times per day since ~2026-06-28.
Two earlier sessions fixed real but secondary issues (YouTube Metadata plugin duplicate-folder
restart loop on 07-01; scan concurrency + blocking trickplay on 07-02) — outages continued
(most recently 2026-07-03 15:01–15:16 local).

## Investigation path (what finally cracked it)

1. Prometheus: `node_load1` spiked to 102 during the outage while LXC CPU (pve-side
   `pve_cpu_usage_ratio`) peaked at 77% → not compute-bound, ~100 threads in D-state.
2. `up{instance=~"...110.*"}` == 0 for the *entire* scan duration → node_exporter's statfs on the
   NFS mounts hung → box-wide stall, all on-host metrics blind during the window.
3. External views: TrueNAS idle (load ~0, link ~54 MB/s max, NFS ops only ~1000/s) → not a
   server-side stall.
4. `pve_memory_usage_bytes{id="lxc/110"}`: 9% baseline → **97.8%** during the outage → memory.
5. pve kernel journal (shared kernel — guest OOMs land there):
   `Memory cgroup out of memory: Killed process (ffprobe) anon-rss:5,499,120kB` at the exact
   second the outage ended. Same kill on *every* scheduled scan since Jun 28.
6. Live catch during the 13:00 scan (2 s `ps` poller): ffprobe on
   `/library/kids/movies/Abominable (2019)/Abominable (2019) WEBDL-1080p.mkv` grew 2.5→5.4 GB in
   10 s, thrashed the box ~5 min, OOM-killed 13:05:28, scan completed 13:05:36.

## Root cause

Corrupt Matroska seek index (SeekHead/Cues) in that one 6.4 GB file (present since 2025-10;
linear demux 100% clean, so playback mostly worked). Jellyfin 10.11's probe
(`-show_frames -only_first_vframe`) follows the cues into garbage EBML and allocates without
bound. ffprobe dies before finishing → Jellyfin never persists media info → re-probes the same
file on every scan → one OOM + brownout per scan, forever. Re-probing was triggered on 06-26 by
new `.srt` files invalidating the item's media info. Outage length = pre-OOM thrash time
(depends on free RAM at scan start: 22 s when cache empty, 24 min when full). Raising LXC RAM
4→6 GB (~Jun 28) made outages *longer*.

A second latent bug made this catastrophic: compose had `mem_limit: 8g` for the jellyfin
container **on a 6 GB LXC** — the docker limit could never fire, so the runaway always hit the
LXC-wide cgroup wall and took every service on the box down with it.

## Fixes

1. `roles/jellyfin_lxc/files/docker-compose.yml`: `mem_limit` 8g→**4g**, `mem_reservation`
   4g→1g, transcode tmpfs 4g→2g (tmpfs counts against the container limit). Future runaways die
   inside the container cgroup in seconds; box stays up. **Verified on the 15:00 scan:** ffprobe
   killed at 3.8 GB inside the docker cgroup, scan completed in 32 s, load ~4, zero impact.
   This is the fix that ended the outages.
2. Remuxed the file (`ffmpeg -map 0 -c copy`) — did NOT stop the balloon. **Correction of the
   initial analysis:** the probe balloons even on the clean remux, yet completes fine in seconds
   under `ulimit -v 2G` (failed alloc → graceful fallback path). So it's an ffmpeg allocation bug
   triggered by this title's stream data, not (only) the corrupt cues — and my "remux verified
   fixed" test was invalid because the ulimit cap itself changed ffprobe's behavior. Lesson: a
   verification harness must not alter the failure mechanism it's testing for.
3. Final resolution (John's decisions): **deleted the movie entirely** (incl. the `.corrupt-bak`),
   and **wrapped ffprobe with `ulimit -v 3G` in the custom Dockerfile** — capped probes complete
   gracefully with valid output (verified: bad file, 486-file sweep, and a 4K title through the
   wrapper), so any future pathological file saves its metadata instead of OOM-looping. ffmpeg
   left unwrapped. Rebuild required after dockerfile changes: compose handler recreates but does
   not rebuild (`docker compose build jellyfin`).
3. Disabled `EnableRealtimeMonitor` on the 6 NFS libraries that had drifted ON (5 new libraries
   added 07-01 + Create) — new Jellyfin libraries default to ON; documented intent is OFF for
   all NFS libraries.
4. Removed the fossil `mount_touch_probe.prom` on jellyfin — the probe timer has been off since
   2025-10-02, but node_exporter kept serving that frozen file for 9 months (including
   `/mnt/media/*` series for mounts that no longer exist). Decision: share_drive_probe stays
   **disabled everywhere** (John: NFS is stable, probing not needed); the misleading part was the
   stale metrics file, not the disabled timer. `monitor_nfs_smb_mounts.md` updated with the status.

## Follow-up hardening (same day)

- Added a `Rebuild jellyfin image` handler (`build: always`, jellyfin service only) notified by
  the "Copy dockerfile" task — closes the gap where a dockerfile change deployed the file but
  never rebuilt the image (the manual `docker compose build` mentioned below is no longer
  needed). `pull: never` keeps rebuilds from silently upgrading Jellyfin.

- Deleted the 3 dead-YouTube-video source files (`foYNUVFoZe0`, `NJTdu309d3E`, `VZcPKF2FOm0`)
  that the YouTube Metadata plugin re-fetched (and error-logged) on every scan.
- Added memory caps to the sidecar containers (alloy/cadvisor 512m, node_exporter 128m — ~10×
  typical usage) so no container on the 6 GB LXC can starve the others.
- Decision: real-time library monitoring stays OFF on NFS libraries permanently — inotify only
  fires for local-kernel writes, and all media is written by other hosts (Radarr/Sonarr on
  media-vm, TubeArchivist), so NFS watchers can never see changes; they only burn CPU. For
  instant availability, use writer-side notifications (Radarr/Sonarr → Jellyfin "Notify on
  import" connections) with scheduled scans as the backstop.
- Declined: pinning `FROM jellyfin/jellyfin:<version>` in the Dockerfile (John's call; stays
  `latest`, version moves only on manual rebuild).

## Lessons

- "Down N minutes, self-recovered, container never restarted" + load ≫ CPU ⇒ check the **pve
  journal for memcg OOM kills** before anything else. One command would have found this a week
  earlier.
- A docker `mem_limit` above the LXC's total RAM is worse than none — it silently converts a
  per-container kill into a whole-box brownout.
- On-host metrics go blind during these events; use pve_exporter + TrueNAS/network metrics for
  the external truth.
