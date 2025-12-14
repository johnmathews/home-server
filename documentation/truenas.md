This document covers TrueNAS scripts and apps: share refresh, disk spindown, and disk-status-exporter

## Share Refresh

TrueNAS has a bug where NFS/SMB shares appear active but don't actually work until they're disabled and re-enabled. A script runs on boot to work around this by cycling the shares (OFF → wait → ON).

### Deployment

Deploy the latest version:
```bash
make nas t=refresh-shares
```

### Configuration

Variables in `roles/nas/defaults/main.yml`:
- `refresh_shares_enabled: true`
- `refresh_shares_nfs_path: "tank/paperless"`
- `refresh_shares_smb_path: "tank/paperless"`
- `refresh_shares_wait_seconds: 10`

### UI

`System → Advanced Settings → Init/Shutdown Scripts`
- Type: Command
- Command: `/mnt/swift/scripts/refresh_shares.sh`
- When: Post Init

### Script Location

- `/mnt/swift/scripts/refresh_shares.sh` (deployed)
- `roles/nas/templates/refresh_shares.sh.j2` (source)

### How It Works

1. Verifies TrueNAS API is accessible
2. Looks up NFS and SMB share IDs via API
3. Disables both shares
4. Waits 10 seconds
5. Re-enables both shares
6. Logs everything to `/mnt/swift/logs/refresh_shares.log`

### Logs

`/mnt/swift/logs/refresh_shares.log`

Example output:
```
────────────────────────────────────────────
Refresh script started at 2025-12-14 23:30:45
────────────────────────────────────────────

[INFO] Verifying TrueNAS API health...
  [OK] TrueNAS API accessible

[INFO] Looking up share IDs...
  [OK] NFS share tank/paperless → ID: 3
  [OK] SMB share tank/paperless → ID: 5

[INFO] Disabling shares...
  [OK] Disabled NFS share (ID: 3)
  [OK] Disabled SMB share (ID: 5)

[INFO] Waiting 10 seconds...

[INFO] Enabling shares...
  [OK] Enabled NFS share (ID: 3)
  [OK] Enabled SMB share (ID: 5)

[OK] Share refresh complete!
```

## Disk Spindown

TrueNAS HDDs in the `tank` dataset don't ever spin down by themselves. I don't know why, but I suspect its caused by ZFS
rather than TrueNAS. I've taken the following measures to make spindown possible:

- TrueNAS apps live on the `switft` datapool,
- the `netdata` reporting service is masked,
- the `tank` datapool uses:
  - a "metadata" VDEV
  - a "log" VDEV

Therefore a script runs on a cronjob to try to spindown the disks at night. The script measures utilisation over a sample
period and only if utilisation is below 0.1% is a spindown using `hdparm` implemented. See below for details.

### Spindown Script Deployment

Deploy the latest version:
```bash
make nas t=hdds
```

The version line at the top of the script shows when it was last edited.

### UI

- `system > advanced settings > cron jobs`

### Script Location

- `mnt/swift/scripts/spindown_hdds.sh`
- `roles/truenas_vm/files/spindown_hdds.sh`

### Context

Cron runs a script at hours `0`, `2`, `6`, `23` to see if any HDDs can be spun down. The script monitors each disk for
`4 minutes` and if disk activity is below `0.1%` then it sends a spindown command using `hdparm`.

If the activity threshold requirement isn't met, then spindown isn't attempted.

The script must be told which disks to try to spindown. It uses the disk id.

```sh
# Pair each device with a friendly label: "<by-id>|<label>"
TARGETS=(
	"/dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG|backup"
	"/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90|tank"
	"/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF|tank"
)
```

### Logs

- `/mnt/swift/logs/spindown_hdds.log`

```
[2025-10-05 02:00:03] INFO  ============================================================
[2025-10-05 02:00:03] INFO  Starting HDD spindown  (SAMPLE_DURATION=240s, UTIL_THRESHOLD=0.10%)
[2025-10-05 02:00:03] INFO    target: sdb - backup [/dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG]
[2025-10-05 02:00:03] INFO    target: sde - tank [/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90]
[2025-10-05 02:00:03] INFO    target: sdc - tank [/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF]

[2025-10-05 02:00:03] NOTE  backup (sdb): already in standby; skipping.

[2025-10-05 02:00:03] INFO  tank (sde): sampling I/O for 240s…
[2025-10-05 02:08:03] INFO  tank (sde): 0.16% utilisation
[2025-10-05 02:08:03] NOTE  tank (sde): utilisation >= 0.10%, skipping spindown.

[2025-10-05 02:08:03] INFO  tank (sdc): sampling I/O for 240s…
[2025-10-05 02:16:03] INFO  tank (sdc): 0.15% utilisation
[2025-10-05 02:16:03] NOTE  tank (sdc): utilisation >= 0.10%, skipping spindown.

[2025-10-05 02:16:03] OK    Spindown script complete. Exiting.
```

## Disk status exporter

Grafana shows the spindown status of each hard disk. This is possible because a custom TrueNAS app queries the disks and
exposes Prometheus style metrics.

The custom app lives in a separate repo and is containerized using a Github action.

Github repo: [https://github.com/johnmathews/disk_status_exporter](https://github.com/johnmathews/disk_status_exporter)

### Deploy

- Push to the `main` branch of the Github remote. This will trigger a Github action that will deploy a new version of the
  container to the Github Container Registry (GHCR.io).
- Then update the app in the TrueNAS apps UI.

### UI

`TruNAS apps > disk-status-exporter`

### Code Location

`projects/home-server/disk-status-exporter `

### Context

- `disk-status-exporter` reports the power status of HDDs using the command `smartctl -n standby -i <disk>`. Options are
  `standby`, `active or idle`, `idle` or `unknown`.
- It is a containerised FastAPI script that is managed in a separate repo.
- It emits Prometheus metrics at `<truenas-ip>:9635/metrics`

### Logs

In the TrueNAS UI, click on the app and then select `Details > Workloads > View Logs`
