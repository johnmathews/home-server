## Disk Spindown

### Deploy

- `make nas tags=hdds`

The version line at the top of the script shows when it was last edited.

### UI

- `system > advanced settings > cron jobs`

### Script Location

- `mnt/swift/scripts/spindown_hdds.sh`
- `roles/truenas_vm/files/spindown_hdds.sh`

### Context

Cron runs a script at hours `0`, `2`, `6`, `23` to see if any HDDs can be spun
down. The script monitors each disk for `4 minutes` and if disk activity is
below `0.1%` then it sends a spindown command using `hdparm`.

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

Github:
[https://github.com/johnmathews/disk_status_exporter](https://github.com/johnmathews/disk_status_exporter)

### Deploy

- Push to the `main` branch of the github remote. This will trigger a github
  action that will deploy a new version of the container to the Github Container
  Registry (GHCR).
- Then update the app in the TrueNAS apps UI.

### UI

`TruNAS apps > disk-status-exporter`

### Code Location

`projects/home-server/disk-status-exporter `

### Context

- `disk-status-exporter` reports the power status of HDDs using the command
  `smartctl -n standby -i <disk>`. Options are `standby`, `active or idle`,
  `idle` or `unknown`.
- It is a containerised FastAPI script that is managed in a separate repo.
- It emits Prometheus metrics at `<truenas-ip>:9635/metrics`

### Logs

In the TrueNAS UI, click on the app and then select `Details > Workloads > View Logs`
