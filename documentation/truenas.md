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
- `refresh_shares_nfs_path: "tank/document-store"`
- `refresh_shares_smb_path: "tank/time-machine-backups/johns-laptop"`
- `refresh_shares_wait_seconds: 5`

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
4. Waits 5 seconds (`refresh_shares_wait_seconds`)
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
  [OK] NFS share tank/document-store → ID: 3
  [OK] SMB share tank/time-machine-backups/johns-laptop → ID: 5

[INFO] Disabling shares...
  [OK] Disabled NFS share (ID: 3)
  [OK] Disabled SMB share (ID: 5)

[INFO] Waiting 5 seconds...

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

Therefore a script runs on a cronjob to try to spindown the disks at night. The script counts I/O sectors transferred
over a sample period (via `/sys/block/*/stat`) and only if a disk transfers fewer than `IO_THRESHOLD` sectors is a
spindown using `hdparm` implemented. See below for details.

### Spindown Script Deployment

Deploy the latest version:
```bash
make nas t=hdds
```

The version line at the top of the script shows when it was last edited.

### UI

- `system > advanced settings > cron jobs`

### Script Location

- `/mnt/swift/scripts/spindown_hdds.sh` (deployed)
- `roles/nas/files/spindown_hdds.sh` (source)

### Context

Cron runs a script at hours `0`, `2`, `6`, `23` to see if any HDDs can be spun down.

**Parallel sampling:** All disks are sampled simultaneously using I/O sector counts from `/sys/block/*/stat`. This allows for longer sample durations (15 minutes) without proportional runtime increase. Previously, 4 disks × 7 minutes = 28 minutes total; now 4 disks are sampled in ~15 minutes.

**Parameters:**
- `SAMPLE_DURATION=900` (15 minutes) - catches periodic activity patterns
- `COOLDOWN_SECS=3600` (60 minutes) - prevents spindown thrash after recent spindown
- `IO_THRESHOLD=100` (sectors) - disk must transfer fewer than ~50KB to be considered idle

**Why sector counts instead of iostat %util:**
- Sector counts are absolute cumulative values from the kernel, not time-averaged percentages
- Zero I/O during sample period = exactly 0 sectors transferred (binary certainty)
- No threshold tuning needed - "idle" means truly no activity
- More reliable for detecting periodic background tasks

**Workflow:**
1. Pre-flight: validate each disk (exists, rotational, not in standby, no self-test, cooldown expired)
2. Parallel sample: read initial sector counts, wait SAMPLE_DURATION, read final counts for all valid disks
3. Decision: calculate delta (sectors transferred), check zpool iostat for immediate activity, spindown if idle

The script must be told which disks to try to spindown. It uses the disk id.

```sh
# Pair each device with a friendly label: "<by-id>|<label>"
TARGETS=(
  "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90|backup"
  "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF|backup"
  "/dev/disk/by-id/ata-ST16000NT001-3LV101_K3S04BKQ|tank"
  "/dev/disk/by-id/ata-ST16000NT001-3LV101_ZR5GK5G9|tank"
)
```

### Logs

- `/mnt/swift/logs/spindown_hdds.log`

```
[2026-01-24 02:00:03] INFO  ============================================================
[2026-01-24 02:00:03] INFO  Starting HDD spindown  (SAMPLE_DURATION=900s, IO_THRESHOLD=100 sectors)
[2026-01-24 02:00:03] INFO    target: sdb - backup [/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90]
[2026-01-24 02:00:03] INFO    target: sdc - backup [/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF]
[2026-01-24 02:00:03] INFO    target: sdd - tank [/dev/disk/by-id/ata-ST16000NT001-3LV101_K3S04BKQ]
[2026-01-24 02:00:03] INFO    target: sde - tank [/dev/disk/by-id/ata-ST16000NT001-3LV101_ZR5GK5G9]
[2026-01-24 02:00:03] INFO  Pre-flight: checking disk states…
[2026-01-24 02:00:03] NOTE  backup (sdb): already in standby; skipping.
[2026-01-24 02:00:03] INFO    ✓ backup (sdc): queued for sampling
[2026-01-24 02:00:03] INFO    ✓ tank (sdd): queued for sampling
[2026-01-24 02:00:03] INFO    ✓ tank (sde): queued for sampling

[2026-01-24 02:00:03] INFO  Sampling 3 disk(s) in parallel for 900s: sdc sdd sde
[2026-01-24 02:00:03] INFO  Waiting 900 seconds…

[2026-01-24 02:15:03] INFO  Making spindown decisions…
[2026-01-24 02:15:03] INFO  backup (sdc): 48 sectors (24.00KB) transferred [R:16 W:32] (threshold: 100)
[2026-01-24 02:15:03] WARN  backup (sdc): 48 <= 100 sectors; spinning down…
[2026-01-24 02:15:03] OK    backup (sdc): disk in standby.
[2026-01-24 02:15:03] INFO  tank (sdd): 72 sectors (36.00KB) transferred [R:40 W:32] (threshold: 100)
[2026-01-24 02:15:03] WARN  tank (sdd): 72 <= 100 sectors; spinning down…
[2026-01-24 02:15:03] OK    tank (sdd): disk in standby.
[2026-01-24 02:15:03] INFO  tank (sde): 256 sectors (128.00KB) transferred [R:128 W:128] (threshold: 100)
[2026-01-24 02:15:03] NOTE  tank (sde): 256 > 100 sectors; skipping spindown.

[2026-01-24 02:15:03] OK    Spindown script complete. Exiting.
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

## Safe Reboot

TrueNAS has a script that performs safety checks before rebooting to avoid interrupting critical operations like ZFS resilvers, scrubs, or active I/O workloads.

### Deployment

Deploy the latest version:
```bash
make nas t=safe-reboot
```

### Configuration

Variables in `roles/nas/defaults/main.yml`:
- `safe_reboot_max_retries: 4` - Maximum number of retry attempts
- `safe_reboot_retry_sleep_seconds: 300` - Wait time between retries (5 minutes)
- `safe_reboot_io_sample_duration: 180` - Duration to sample I/O per attempt (3 minutes)
- `safe_reboot_io_sample_interval: 30` - Interval between I/O samples (30 seconds)
- `safe_reboot_io_ops_threshold: 120` - Operations/minute threshold (2 ops/sec) - normalized so changing sample interval doesn't affect effective threshold

### UI

Configure via TrueNAS cron job to schedule safe reboots:
- `System → Advanced Settings → Cron Jobs`
- Type: Command
- Command: `/mnt/swift/scripts/safe_reboot.sh`
- Schedule: User-defined (e.g., weekly maintenance window)

### Script Location

- `/mnt/swift/scripts/safe_reboot.sh` (deployed)
- `roles/nas/templates/safe_reboot.sh.j2` (source)

### How It Works

1. Verifies no ZFS resilver or scrub is in progress
2. Samples zpool I/O every 30 seconds for 3 minutes (6 samples total per attempt)
3. Calculates operations per second for each sample
4. Compares each sample against threshold (120 ops/min = 2 ops/sec, normalized by sample interval)
5. If ALL samples are below threshold, initiates reboot
6. If ANY sample exceeds threshold, attempt fails
7. On failure, waits 5 minutes and retries (up to 4 attempts total)
8. Sends Pushover notifications on success or failure
9. Logs all decisions to `/mnt/swift/logs/safe_reboot.log`

### Maximum Runtime

If TrueNAS is continuously busy and all retries exhaust:
- 4 attempts × 3 minutes per attempt = 12 minutes of I/O sampling
- 3 wait periods × 5 minutes each = 15 minutes of waiting
- **Total: 27 minutes maximum** before giving up

### Logs

`/mnt/swift/logs/safe_reboot.log` (rotates at 10MB, keeps 5 old logs)

Example output:
```
[2026-01-05 14:00:00] INFO  ============================================================
[2026-01-05 14:00:00] INFO  Starting safe reboot check (max retries: 4, retry interval: 300s)
[2026-01-05 14:00:00] INFO  Attempt 1 of 4: Running safety checks...
[2026-01-05 14:00:00] INFO  Sampling zpool I/O every 30s for 180s (6 samples)...
[2026-01-05 14:00:00] INFO  Threshold: 2.00 ops/sec (60.00 ops per 30s sample)
[2026-01-05 14:00:30] INFO  Sample 1/6: 0.45 ops/sec (13.5 ops)
[2026-01-05 14:01:00] INFO  Sample 2/6: 0.62 ops/sec (18.6 ops)
...
[2026-01-05 14:03:00] INFO  I/O Summary: avg 0.58 ops/sec, 0/6 samples exceeded threshold
[2026-01-05 14:03:00] OK    All samples below threshold (2.00 ops/sec)
[2026-01-05 14:03:00] OK    All safety checks passed. Initiating reboot now...
```
