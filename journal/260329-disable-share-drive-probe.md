# Disable share-drive-probe timer

The NFS/SMB share drive probe has been running every 5 minutes on all
`share_drive_clients` hosts (media, immich, jellyfin, music, tubearchivist,
paperless). The shares have been stable for a long time, so the probe was
disabled to reduce unnecessary background activity.

## Changes

- Added `share_drive_probe_enabled` toggle (default: `false`) to
  `roles/share_drive_probe/defaults/main.yml`.
- The final task in `tasks/main.yml` now explicitly sets the timer to
  started/stopped and enabled/disabled based on the variable, ensuring the
  setting survives reboots.
- Handlers respect the toggle: the timer handler stops instead of restarting
  when disabled, and the one-shot service run is skipped entirely.
- Updated `documentation/monitor_nfs_smb_mounts.md` with the new enable/disable
  instructions.

## Re-enabling

Set `share_drive_probe_enabled: true` in `group_vars/all/main.yml` (or a
host-specific override) and run `make site tags=shares`.
