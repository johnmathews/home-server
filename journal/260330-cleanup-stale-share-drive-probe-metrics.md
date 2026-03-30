# Clean up stale share-drive-probe .prom files

After disabling the share-drive-probe timer (260329), Grafana still showed the
probe as active. Investigated and confirmed that the systemd timers are
inactive/disabled on all hosts, but leftover `.prom` files in
`/var/lib/node_exporter/textfile_collector/` were being re-scraped by
node_exporter every interval, keeping the metrics alive in Prometheus.

## Hosts cleaned

Removed `share_drive_probe.prom` from:
- media (192.168.2.105) — needed sudo
- immich (192.168.2.113)
- jelly (192.168.2.110)
- tube (192.168.2.116)
- paperless (192.168.2.117)
- pve (192.168.2.214)

Music (192.168.2.109) had no stale file — already clean.

## Documentation update

Added a note to `documentation/monitor_nfs_smb_mounts.md` explaining that
disabling the probe does not remove the `.prom` file, and stale files must be
manually deleted to stop Grafana from showing phantom data.
