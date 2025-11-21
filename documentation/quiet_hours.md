## Deployment

- The service is updated and deployed using Ansible.
- The tasks live in `tasks/sleep_docker_containers.yml`

`make site tags=sleep`

`make media tags=sleep`

`make paperless tags=sleep`

`make tube tags=sleep`

## Context

Several services running as docker containers prevent HDD spindown, even when
they are not being used.

Pausing these docker services when they are not being used and when HDDs should
be in standby prevents disk IO and allows the HDDs to spin down.

"Quiet Hours" denotes this time period.

Systemd services run on a schedule defined by the variables `docker_quiet_hours_start` and
`docker_quiet_hours_end`. Four operations are supported:
- `docker-sleep@pause.service` - Pause containers during quiet hours
- `docker-sleep@unpause.service` - Resume paused containers
- `docker-sleep@stop.service` - Stop containers during quiet hours
- `docker-sleep@start.service` - Start stopped containers

_Docker Pause_

Pausing a docker container does not stop it, but it does prevent disk IO.

`docker pause` uses the cgroups `freezer` command.

The state of the container is unaffected (RAM remains allocated, PIDs stay open,
file/socket state is unchanged.

## Variables

The following template variables are used.

They can be edited in `media_vm/defaults/main.yml`.

```yaml
uptime_kuma_url: "http://192.168.2.106:3001"
uptime_kuma_user: "john"
docker_quiet_hours_start: "23:55"
docker_quiet_hours_end: "08:45"
```

Ansible vault:

- `vault_uptime_kuma_password`

## Template files

The Ansible role uses the following files and templates, located in
`roles/sleep_hours/templates/`:

- `docker-sleep@.service` - Unified service unit template for all operations
- `docker-sleep@pause.timer.j2`
- `docker-sleep@unpause.timer.j2`
- `docker-sleep@stop.timer.j2`
- `docker-sleep@start.timer.j2`
- `docker-sleep.sh` - Main script that performs all operations
- `uptimekumactl.py` - Uptime Kuma integration
- `containers.list.j2` - Container list template
- `kuma.map.j2` - Monitor mapping template

## Method

- The timer units trigger their respective service unit based on schedule.

- All four operations (pause, unpause, stop, start) use a single consolidated
  service unit template: `docker-sleep@.service`. Systemd templating automatically
  instantiates the correct service based on the timer's `Unit=` directive.

- The `@` in the filename indicates systemd templating. The parameter after `@`
  is passed as `%i` to the service, avoiding file duplication:
  - `docker-sleep@pause.timer` → triggers `docker-sleep@pause.service` → `%i=pause`
  - `docker-sleep@unpause.timer` → triggers `docker-sleep@unpause.service` → `%i=unpause`
  - `docker-sleep@stop.timer` → triggers `docker-sleep@stop.service` → `%i=stop`
  - `docker-sleep@start.timer` → triggers `docker-sleep@start.service` → `%i=start`

- The service unit calls `docker-sleep.sh %i` with the operation name.

- `docker-sleep.sh` reads the appropriate container list and attempts to perform
  the operation on each container. It logs its actions using `logfmt` format.
  The `alloy` service will forward the logs to `Loki` and can be viewed in `Grafana`.

- `docker-sleep.sh` also notifies Uptime Kuma monitors (via `kumactl.py`) when
  containers are paused/resumed/stopped/started.

## Commands

### Run the service

```sh
sudo systemctl start docker-sleep@pause.service
sudo systemctl start docker-sleep@unpause.service
sudo systemctl start docker-sleep@stop.service
sudo systemctl start docker-sleep@start.service
```

### Don't run the shell script without using the service unit

This wont work because the scripts (`kumactl.py` and `docker-quiet.sh`) use
environment variables that are supplied by the systemd service unit.

### Verify State

```sh
systemctl status docker-sleep@pause.timer
systemctl status docker-sleep@unpause.timer
systemctl status docker-sleep@stop.timer
systemctl status docker-sleep@start.timer
systemctl status docker-sleep@pause.service
systemctl status docker-sleep@unpause.service
systemctl status docker-sleep@stop.service
systemctl status docker-sleep@start.service
```

### List timers

```sh
TZ=Europe/Amsterdam systemctl list-timers --all
```

### View logs from last run only:

Timers do not generate logs.

```sh
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@pause.service)
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@unpause.service)
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@stop.service)
journalctl --no-pager _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value docker-sleep@start.service)
```

### View logs

```sh
journalctl -u docker-sleep@pause.service -n 50
journalctl -u docker-sleep@unpause.service -n 50
journalctl -u docker-sleep@stop.service -n 50
journalctl -u docker-sleep@start.service -n 50
```

## File locations

The Ansible role copies the following files to these locations:

- `docker-sleep.sh` -> `/usr/local/bin/docker-sleep.sh`
- `truenas-shares.sh` -> `/usr/local/bin/truenas-shares.sh`
- `uptimekumactl.py` -> `/usr/local/bin/kumactl.py`
- `containers.pause.list` -> `/etc/sleep-hours/containers.pause.list`
- `containers.stop.list` -> `/etc/sleep-hours/containers.stop.list`
- `kuma.map` -> `/etc/sleep-hours/kuma.map`
- `truenas.conf` -> `/etc/sleep-hours/truenas.conf` (if NFS/SMB control enabled)
- Timer Units -> `/etc/systemd/system/docker-sleep@*.timer`
- Service Unit Template -> `/etc/systemd/system/docker-sleep@.service`

## Plugin Configuration: SABnzbd

The SABnzbd plugin supports robust API-based busy detection with multiple fallback mechanisms.

### Environment Variables

Configure the SABnzbd plugin via systemd environment variables:

**Required:**
- `SAB_URL` - SABnzbd base URL (e.g., `http://127.0.0.1:8081`)
- `SAB_API_KEY` - SABnzbd API key (found in Config > General > Security)

**Optional:**
- `SAB_TIMEOUT_S` - API request timeout in seconds (default: 5)
- `SAB_RETRIES` - Number of API retry attempts (default: 2)
- `SAB_RETRY_DELAY_S` - Initial retry delay in seconds (default: 1, exponential backoff)
- `SAB_BUSY_THRESHOLD_KBPS` - Minimum download speed to consider busy in KB/s (default: 10)
- `SAB_CHECK_POSTPROC` - Check post-processing activity (default: 1)
- `SAB_HEALTH_CHECK` - Validate connectivity before API calls (default: 1)
- `CURL_INSECURE` - Allow self-signed SSL certificates (default: 0)

### Busy Detection Criteria

The plugin considers SABnzbd busy if any of the following conditions are true:

1. **Queue Status**: Status is "Downloading" or "Fetching"
2. **Download Speed**: Speed exceeds threshold (default 10 KB/s)
3. **Queued Jobs**: Jobs are queued AND not paused AND data remaining
4. **Post-Processing**: Active post-processing (Repairing, Extracting, Moving, Running)

### Configuration Example

Add to the systemd service unit environment:

```systemd
[Service]
Environment="SAB_URL=http://127.0.0.1:8081"
Environment="SAB_API_KEY=your-api-key-here"
Environment="SAB_BUSY_THRESHOLD_KBPS=50"
Environment="SAB_CHECK_POSTPROC=1"
```

Or use an EnvironmentFile:

```bash
# /etc/sleep-hours/sabnzbd.env
SAB_URL=http://127.0.0.1:8081
SAB_API_KEY=your-api-key-here
SAB_BUSY_THRESHOLD_KBPS=50
SAB_CHECK_POSTPROC=1
```

Then reference in systemd unit:

```systemd
[Service]
EnvironmentFile=/etc/sleep-hours/sabnzbd.env
```

### Fallback Behavior

If the SABnzbd API is unavailable (network error, invalid credentials, SABnzbd offline), the plugin automatically falls back to generic CPU/IO-based busy detection using `docker stats`.

This ensures the sleep hours service continues to function even if SABnzbd is temporarily unreachable.

### Logging

Enable debug logging with `QUIET_DEBUG=1` to see:
- API request/response details
- JSON parsing results
- Busy detection decision criteria
- Retry attempts and failures

Example:
```bash
QUIET_DEBUG=1 systemctl start docker-sleep@stop.service
journalctl -u docker-sleep@stop.service -n 100
```

### API Endpoints Used

- `GET /api?mode=queue&limit=0` - Lightweight queue status check
- `GET /api?mode=history&limit=1` - Post-processing status check
- `GET /api?mode=version` - Health check (no authentication required)

### Changelog

**Version 2.0** (Current)
- Multi-criteria busy detection (queue status, speed, post-processing)
- Retry logic with exponential backoff
- Pure-bash JSON parsing (no jq dependency)
- Comprehensive environment validation
- Enhanced error handling and logging
- Post-processing activity detection
- Configurable busy thresholds

**Version 1.0** (Legacy)
- Basic queue check (noofslots, kbpersec)
- Single API call with no retry
- Crude regex-based JSON parsing

## TrueNAS NFS/SMB Share Control

The quiet hours system can automatically disable and re-enable TrueNAS NFS and SMB shares to prevent HDD wakeup during quiet hours.

### How It Works

1. **Before stopping containers:** Disable NFS/SMB shares
2. **Stop containers:** Containers no longer accessing shares
3. **HDDs can spin down:** No client activity, no share activity
4. **Before starting containers:** Re-enable NFS/SMB shares
5. **Start containers:** Containers can access shares normally

### Configuration

Enable in host_vars:

```yaml
# Enable NFS/SMB share control
sleep_hours_nfs_smb_enabled: true

# Define NFS shares to control
nfs_shares:
  - name: paperless
    mountpoint: /mnt/nfs/paperless
    target: /mnt/tank/paperless

# Optional: SMB shares
smb_shares:
  - name: paperless
    target: /mnt/paperless
```

### Script Location

- Script: `/usr/local/bin/truenas-shares.sh`
- Config: `/etc/sleep-hours/truenas.conf`
- Share list: `/etc/sleep-hours/truenas-nfs-shares.list`

### Features

**Enhanced in v2.0:**
- ✅ JSON response validation
- ✅ Flexible path matching (handles /mnt prefix variations)
- ✅ State verification after toggle
- ✅ TrueNAS API health checks
- ✅ Enhanced error logging
- ✅ Retry logic (3 attempts, 2s delay)

### Requirements

- TrueNAS API key (stored in vault: `vault_truenas_api_key`)
- jq command (for JSON parsing)
- TrueNAS accessible at configured URL

### Testing

**Safe read-only test:**
```bash
ssh paperless-lxc
source /etc/sleep-hours/truenas.conf
/usr/local/bin/truenas-shares.sh status "/mnt/tank/paperless"
```

**With debug logging:**
```bash
QUIET_DEBUG=1 QUIET_LOG_LEVEL=debug \
  /usr/local/bin/truenas-shares.sh status "/mnt/tank/paperless"
```

**Full test (⚠️ makes changes):**
```bash
# Disable shares
/usr/local/bin/truenas-shares.sh disable "/mnt/tank/paperless"

# Verify in TrueNAS UI: https://192.168.2.104 > Shares > NFS

# Re-enable shares
/usr/local/bin/truenas-shares.sh enable "/mnt/tank/paperless" "paperless-webserver"
```

### Troubleshooting

**Share not found:**
- Check path format in TrueNAS (may include or exclude /mnt)
- Use debug mode to see API response
- Verify share exists in TrueNAS UI

**API errors:**
- Verify TRUENAS_API_KEY is correct
- Check TrueNAS is accessible
- Ensure jq is installed

**State verification failures:**
- Check TrueNAS logs
- Manually verify share state in UI
- May indicate permissions issue

**Recovery if shares stuck disabled:**
1. Manually enable in TrueNAS UI
2. Restart containers: `docker start <container-name>`
3. Temporarily disable feature: `sleep_hours_nfs_smb_enabled: false`

### Currently Enabled

- ✅ paperless_lxc
- ✅ tubearchivist_lxc
- ❌ media-vm (disabled)

