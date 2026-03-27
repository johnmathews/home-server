# slskd standalone — bypass Lidarr metadata matching

**Date**: 2026-03-27

## Context

Lidarr's metadata matching (via MusicBrainz) was rejecting valid music downloads from Soulseek,
causing Soularr to re-download the same albums repeatedly. This wasted disk space, bandwidth, and
network activity with no benefit — the music was fine, Lidarr just didn't like the metadata.

## Changes

### Disabled Lidarr and Soularr

- Commented out `lidarr` and `soularr` services in `roles/media_vm/templates/docker-compose.yml.j2`
- Soularr was only the bridge between Lidarr and slskd — without Lidarr it has no purpose
- Both services remain in the template (commented) for easy re-enablement

### slskd now standalone

- slskd runs as a standalone Soulseek client — manual search and download via WebUI
- Added `music: /music` directory mapping in `slskd.yml.j2` config
- Changed slskd's upload share from `/mnt/nfs/music/lidarr` to `/mnt/nfs/music/slskd`
- Only `/music` is shared with peers (not `/downloads` staging area)

### New workflow

1. Search and download in slskd WebUI (http://192.168.2.105:5030)
2. Review completed downloads in `/mnt/nfs/downloads/slskd/`
3. Move approved albums to `/mnt/nfs/music/slskd/Artist/Album/`
4. Rescan shares in slskd so new files are uploaded to peers
5. Navidrome picks up new files on hourly scan

### Navidrome multi-library

- Created `/mnt/nfs/music/slskd/` on TrueNAS
- Added as a separate library in Navidrome (Navidrome supports multiple libraries)
- Existing `releases` library unchanged

### Documentation

- Rewrote music acquisition section in `documentation/media_vm.md`
- Updated music sources section in `documentation/navidrome.md`

## Decision rationale

The automated pipeline (Lidarr -> Soularr -> slskd) added complexity without reliability.
Manual curation via slskd's WebUI is simpler, avoids the download loop, and gives direct
control over what gets kept. The trade-off is no automation, but for music discovery that's
actually preferable.
