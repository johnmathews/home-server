## Deployment

- The service is updated and deployed using Ansible.
- The tasks live in `tasks/sleep_docker_containers.yml`

`make site tags=sleep`

`make media tags=sleep`

`make paperless tags=sleep`

`make tube tags=sleep`

## Testing

A comprehensive test suite validates the sleep hours system using **bats** (Bash Automated Testing System).

### Running Tests

```bash
# Install bats first (one-time setup)
brew install bats-core  # macOS
sudo apt-get install bats  # Debian/Ubuntu

# Run all tests
cd tests
./run_tests.sh
```

### What's Tested

- Container pause/unpause/stop/start workflows
- TrueNAS NFS/SMB share enable/disable via API
- Idempotency (running operations multiple times)
- Phase execution order
- Summary statistics accuracy
- **Regression test** for the enable/unpause bug (fixed 2025-11-22)

### Test Coverage

- **20 integration tests** across 5 test files
- Mock TrueNAS API server (no real TrueNAS required)
- Mock Uptime Kuma server
- Automated in CI/CD via GitHub Actions

### Documentation

- Full test documentation: `/tests/README.md`
- Implementation details: `/tests/IMPLEMENTATION_SUMMARY.md`

The test suite ensures the critical bug where shares weren't re-enabled after sleep hours can never return.

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

### Critical Configuration Requirements

The TrueNAS API URL **must** include the full API path:

```yaml
# roles/sleep_hours/defaults/main.yml
sleep_hours_truenas_api_url: "https://192.168.2.104/api/v2.0" # ✅ Correct
```

**Common mistake:**

```yaml
sleep_hours_truenas_api_url: "https://192.168.2.104" # ❌ Wrong - missing /api/v2.0
```

**Why this matters:** The script uses this URL directly. Without `/api/v2.0`, all API calls will fail with HTTP 302 redirects.

#### Self-Signed Certificates

The script uses `curl -k` to accept TrueNAS's self-signed certificate. For production environments, consider:

1. Installing TrueNAS's CA certificate to the system trust store, OR
2. Using `--cacert /path/to/truenas-ca.pem` in production

For home labs, `-k` (insecure mode) is acceptable and already configured.

#### Script Self-Sourcing

The `truenas-shares.sh` script automatically sources its configuration from `/etc/sleep-hours/truenas.conf`. This means:

- ✅ Works when called directly: `/usr/local/bin/truenas-shares.sh disable ...`
- ✅ Works when called from systemd services
- ✅ Works when called from `docker-sleep.sh`
- ✅ No need to export environment variables manually

**Implementation:**

```bash
# The script does this internally:
if [[ -f /etc/sleep-hours/truenas.conf ]]; then
  . /etc/sleep-hours/truenas.conf
fi
```

### Script Location

- Script: `/usr/local/bin/truenas-shares.sh`
- Config: `/etc/sleep-hours/truenas.conf`
- Share list: `/etc/sleep-hours/truenas-nfs-shares.list`

### Features & Implementation

**API Integration:**

- ✅ TrueNAS SCALE REST API v2.0 (`/api/v2.0/sharing/...`)
- ✅ Dynamic share ID discovery (no hardcoded IDs)
- ✅ Supports both NFS and SMB shares on same dataset
- ✅ PUT method for share updates (TrueNAS requirement)
- ✅ Flexible path matching (handles `/mnt/tank/...` or `tank/...`)

**Reliability:**

- ✅ JSON response validation using `jq`
- ✅ State verification after each toggle operation
- ✅ TrueNAS API health checks before operations
- ✅ Retry logic (3 attempts, 2s delay with exponential backoff)
- ✅ Self-contained configuration (sources own config file)

**Logging:**

- ✅ Structured logging to stderr (logfmt compatible)
- ✅ Clean function return values (stdout for data only)
- ✅ Integration with alloy → Loki → Grafana

#### How Share Discovery Works

The script **dynamically discovers** share IDs at runtime by querying the TrueNAS API:

1. **List all shares:** `GET /sharing/nfs` and `GET /sharing/smb`
2. **Match by path:** Find shares where `.path == "/mnt/tank/paperless"`
3. **Extract ID:** Parse JSON response for `.id` field
4. **Use ID for updates:** `PUT /sharing/nfs/id/5` with `{"enabled": false}`

**Example:**

```bash
# What the script does internally:
$ curl -s -k "$TRUENAS_API_URL/sharing/nfs" | jq '.[] | select(.path=="/mnt/tank/paperless") | .id'
5

# Then uses that ID:
$ curl -X PUT "$TRUENAS_API_URL/sharing/nfs/id/5" -d '{"enabled":false}'
```

**Benefits:**

- No hardcoded share IDs (survives TrueNAS reconfiguration)
- Works across multiple TrueNAS systems
- Handles share renames gracefully (matches by path, not name)

### Requirements

- TrueNAS API key (stored in vault: `vault_truenas_api_key`)
- jq command (for JSON parsing)
- TrueNAS accessible at configured URL

### Testing

#### Pre-Flight Check (Read-Only)

Before making changes, verify the system can communicate with TrueNAS:

```bash
# 1. Check configuration
ssh <host>
cat /etc/sleep-hours/truenas.conf
cat /etc/sleep-hours/truenas-nfs-shares.list

# 2. Test API connectivity
source /etc/sleep-hours/truenas.conf
curl -s -k "$TRUENAS_API_URL/system/info" \
  -H "Authorization: Bearer $TRUENAS_API_KEY" | jq -r '.version'
# Expected output: TrueNAS-SCALE-24.10.2.3 (or similar)

# 3. List configured shares
curl -s -k "$TRUENAS_API_URL/sharing/nfs" \
  -H "Authorization: Bearer $TRUENAS_API_KEY" | jq '.[] | {id, path, enabled}'

# 4. Test share discovery (safe read-only)
/usr/local/bin/truenas-shares.sh status
```

#### Debug Mode Testing

Enable verbose logging to see internal operations:

```bash
QUIET_DEBUG=1 QUIET_LOG_LEVEL=debug \
  /usr/local/bin/truenas-shares.sh status "/mnt/tank/paperless"

# You'll see:
# - API request/response details
# - Share ID lookup process
# - JSON parsing results
# - State verification checks
```

#### Full Integration Test (⚠️ Makes Changes)

**WARNING:** This will temporarily disable NFS/SMB shares and prevent container access!

```bash
# 1. Verify current state
docker ps | grep paperless
ls -la /mnt/nfs/paperless/  # Should work

# 2. Test disable operation
/usr/local/bin/truenas-shares.sh disable "/mnt/tank/paperless"

# Expected output:
# Starting disable action
# ts=... level=info ... event=truenas_health reason=ok version=TrueNAS-SCALE-24.10.2.3
# ==========================================
# Disabling NFS/SMB Shares
# ==========================================
#   ✓ /mnt/tank/paperless NFS disabled
#   ✓ /mnt/tank/paperless SMB disabled

# 3. Verify shares are disabled
curl -s -k "$TRUENAS_API_URL/sharing/nfs/id/5" \
  -H "Authorization: Bearer $TRUENAS_API_KEY" | jq '{id, path, enabled}'
# Expected: "enabled": false

# 4. Verify NFS unmounted (proof it worked!)
ls -la /mnt/nfs/paperless/
# Expected: "Transport endpoint is not connected" or directory empty

# 5. Try to start containers (should fail - expected!)
cd /srv/apps && docker compose up -d paperless-webserver
# Expected error: "no such file or directory" on NFS mount

# 6. Re-enable shares
/usr/local/bin/truenas-shares.sh enable "/mnt/tank/paperless"

# Expected output:
# Starting enable action
# ts=... level=info ... event=truenas_health reason=ok
#   ✓ /mnt/tank/paperless NFS enabled
#   ✓ /mnt/tank/paperless SMB enabled

# 7. Verify shares re-enabled
curl -s -k "$TRUENAS_API_URL/sharing/nfs/id/5" \
  -H "Authorization: Bearer $TRUENAS_API_KEY" | jq '{enabled}'
# Expected: "enabled": true

# 8. Verify NFS remounted
ls -la /mnt/nfs/paperless/
# Expected: Files visible again

# 9. Restart containers
cd /srv/apps && docker compose up -d
docker ps | grep paperless
# Expected: All containers running
```

#### Automated Testing

The test proves the system works if:

1. ✅ API connection succeeds (health check passes)
2. ✅ Share IDs discovered (not "not found" errors)
3. ✅ Disable succeeds (enabled=false confirmed)
4. ✅ **NFS unmounts** (containers can't access files - THIS IS THE KEY PROOF)
5. ✅ Enable succeeds (enabled=true confirmed)
6. ✅ NFS remounts (containers can access files again)
7. ✅ Containers start successfully

**The "containers can't start" error during step 5 is PROOF the system works!**

### API Reference

**TrueNAS SCALE REST API Endpoints:**

| Operation        | Method  | Endpoint                        | Request Body              |
| ---------------- | ------- | ------------------------------- | ------------------------- |
| List NFS shares  | GET     | `/api/v2.0/sharing/nfs`         | -                         |
| List SMB shares  | GET     | `/api/v2.0/sharing/smb`         | -                         |
| Get NFS share    | GET     | `/api/v2.0/sharing/nfs/id/{id}` | -                         |
| Get SMB share    | GET     | `/api/v2.0/sharing/smb/id/{id}` | -                         |
| Update NFS share | **PUT** | `/api/v2.0/sharing/nfs/id/{id}` | `{"enabled": true/false}` |
| Update SMB share | **PUT** | `/api/v2.0/sharing/smb/id/{id}` | `{"enabled": true/false}` |
| Health check     | GET     | `/api/v2.0/system/info`         | -                         |

**Important Notes:**

- TrueNAS uses **PUT** (not PATCH) for share updates
- PUT requires the full resource object, but TrueNAS accepts partial updates
- The `/id/` prefix in the path is required (e.g., `/sharing/nfs/id/5`, not `/sharing/nfs/5`)
- All requests require `Authorization: Bearer <api_key>` header
- Self-signed certificates require `curl -k` flag

**HTTP Methods:**

- **GET**: Retrieve resource(s) - idempotent, no side effects
- **PUT**: Full resource replacement - idempotent, modifies resource
- **PATCH**: Partial update - NOT SUPPORTED by TrueNAS (returns HTTP 405)

**Why PUT instead of PATCH?**
TrueNAS API returns `HTTP 405 Method Not Allowed` for PATCH requests with header:

```
Allow: DELETE,GET,PUT
```

This indicates TrueNAS follows an older REST API pattern where PUT is used for all updates.

### Logging Architecture

The script follows Unix best practices for output separation:

**stdout (fd 1) - Data/Return Values:**

- Function return values (share IDs, status results)
- Structured data that gets captured by `$(command)`
- Pipeline-able content

**stderr (fd 2) - Messages/Logs:**

- Log messages (debug, info, warn, error) in logfmt format
- Progress indicators and status updates
- Human-readable output
- Forwarded to systemd journal → alloy → Loki → Grafana

**Example:**

```bash
# Function returns clean data to stdout:
share_id=$(get_nfs_share_id "/mnt/tank/paperless")
echo "Got ID: $share_id"  # Prints: Got ID: 5

# All logs go to stderr (not captured):
# ts=2025-11-21T12:00:00 level=info resource=/mnt/tank/paperless action=lookup...
```

**Why this matters:**

- Prevents log messages from polluting function return values
- Allows `2>/dev/null` to suppress logs without breaking functionality
- Enables clean data pipelines: `id=$(script) | jq .id`
- Follows standard Unix tools pattern (grep, curl, jq all work this way)

**Viewing logs:**

```bash
# See all output (stdout + stderr):
/usr/local/bin/truenas-shares.sh disable "/mnt/tank/paperless"

# Data only (stdout, suppress logs):
/usr/local/bin/truenas-shares.sh status "/mnt/tank/paperless" 2>/dev/null

# Logs only (stderr, discard data):
/usr/local/bin/truenas-shares.sh status "/mnt/tank/paperless" >/dev/null
```

### Troubleshooting

#### Share Not Found

**Symptoms:**

```
ts=... level=warn resource=/mnt/tank/paperless action=disable event=nfs_not_found reason=skipped
```

**Diagnosis:**

```bash
# List all NFS shares to see paths:
ssh <host> 'source /etc/sleep-hours/truenas.conf && \
  curl -s -k "$TRUENAS_API_URL/sharing/nfs" \
  -H "Authorization: Bearer $TRUENAS_API_KEY" | jq ".[] | {id, path}"'

# Compare with your configured path:
cat /etc/sleep-hours/truenas-nfs-shares.list
```

**Solutions:**

- Check path format - TrueNAS may use `/mnt/tank/paperless` or `tank/paperless`
- Verify share exists in TrueNAS UI (Shares → NFS)
- Path matching handles variations but requires exact dataset name

---

#### API Connection Failures

**Symptoms:**

```
ts=... level=error resource=_ action=disable event=truenas_health reason=failed cannot_reach_api
```

**Diagnosis:**

```bash
# Check API URL format (must include /api/v2.0):
ssh <host> 'source /etc/sleep-hours/truenas.conf && echo $TRUENAS_API_URL'
# Expected: https://192.168.2.104/api/v2.0
# Wrong: https://192.168.2.104

# Test API connectivity:
ssh <host> 'source /etc/sleep-hours/truenas.conf && \
  curl -v -k "$TRUENAS_API_URL/system/info" \
  -H "Authorization: Bearer $TRUENAS_API_KEY"'
```

**Solutions:**

1. **Missing `/api/v2.0`:** Update `sleep_hours_truenas_api_url` in `roles/sleep_hours/defaults/main.yml`
2. **SSL certificate errors:** Script uses `-k` flag, but verify with manual curl
3. **Invalid API key:** Regenerate in TrueNAS UI (System Settings → API Keys)
4. **Network connectivity:** Ping TrueNAS IP, check firewall rules

---

#### Environment Variables Empty

**Symptoms:**

```
DEBUG: TRUENAS_API_KEY length=0
ts=... level=error resource=_ action=disable event=failed reason=api_auth TRUENAS_API_KEY not set
```

**Cause:** Script invoked without environment variables being exported (OLD BUG - FIXED in v2.0)

**Solution:** The script now self-sources configuration. If you see this error:

```bash
# Verify config file exists and is readable:
ls -l /etc/sleep-hours/truenas.conf
cat /etc/sleep-hours/truenas.conf

# Redeploy if missing:
make paperless  # Or whatever host is affected
```

---

#### State Verification Failures

**Symptoms:**

```
ts=... level=error resource=/mnt/tank/paperless action=disable event=nfs_verify
reason=state_mismatch share_id=5 expected=false actual=unknown
```

**Diagnosis:**

```bash
# Check share state directly:
ssh <host> 'source /etc/sleep-hours/truenas.conf && \
  curl -s -k "$TRUENAS_API_URL/sharing/nfs/id/5" \
  -H "Authorization: Bearer $TRUENAS_API_KEY" | jq "{id, path, enabled}"'
```

**Possible causes:**

- TrueNAS API returned unexpected JSON structure
- jq parsing failed (check jq is installed)
- Permission issue on TrueNAS side (API key lacks permission)
- Share was deleted/recreated (ID changed)

**Solutions:**

1. Verify jq is installed: `which jq`
2. Check TrueNAS logs: System Settings → Shell → `tail /var/log/middlewared.log`
3. Manually verify share state in TrueNAS UI
4. If share ID changed, script will auto-discover new ID on next run

---

#### Containers Can't Start After Shares Disabled

**Symptoms:**

```
Error response from daemon: error while creating mount source path
'/mnt/nfs/paperless/consume': mkdir /mnt/nfs/paperless/consume:
no such file or directory
```

**Cause:** This is **EXPECTED** behavior! It proves share disable worked.

**Recovery:**

```bash
# Method 1: Use the script
/usr/local/bin/truenas-shares.sh enable "/mnt/tank/paperless"

# Method 2: Manual API call
source /etc/sleep-hours/truenas.conf
curl -X PUT "$TRUENAS_API_URL/sharing/nfs/id/5" \
  -H "Authorization: Bearer $TRUENAS_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"enabled":true}'

# Method 3: TrueNAS UI
# Navigate to Shares → NFS → Edit share → Toggle "Enabled"

# Then restart containers:
cd /srv/apps && docker compose up -d
```

---

#### jq Not Installed

**Symptoms:**

```
ts=... level=error resource=/mnt/tank/paperless action=disable event=jq_required
reason=jq is required for reliable share ID lookup
```

**Solution:**

```bash
# Debian/Ubuntu:
sudo apt-get update && sudo apt-get install -y jq

# Then verify:
which jq
jq --version
```

**Note:** jq is required as of v2.0 (previous version had unreliable grep-based fallback).

### Currently Enabled Hosts

Check `host_vars/<hostname>.yml` for the current status:

- ✅ paperless_lxc (`sleep_hours_nfs_smb_enabled: true`)
- ✅ tubearchivist_lxc (`sleep_hours_nfs_smb_enabled: true`)
- ✅ media-vm (`sleep_hours_nfs_smb_enabled: true`)

To enable on a new host:

```yaml
# host_vars/<hostname>.yml
sleep_hours_nfs_smb_enabled: true
```

## Version History

### v2.1 (2025-11-22) - Current

**CRITICAL BUG FIX:**

- 🐛 **FIX:** Fixed case statement mismatch in `truenas-shares.sh` that prevented shares from re-enabling after sleep hours
  - Bug: Execution case had `unpause)` instead of `enable)`
  - Impact: Shares were disabled during sleep hours but NEVER re-enabled when containers restarted
  - Containers would start but couldn't access NFS/SMB mounts
  - Affected hosts: media_vm, paperless_lxc, tubearchivist_lxc
- 🔨 **REFACTOR:** Simplified dual case statement validation to single case statement
  - Prevents future validation/execution mismatches
  - Cleaner code: validates and executes in one place
  - Follows "simple is better than complex" principle

### v2.0 (2025-11-21)

**TrueNAS Share Control:**

- 🐛 **FIX:** Corrected API URL to include `/api/v2.0` path
- 🐛 **FIX:** Updated API endpoints from `/nfs/share` to `/sharing/nfs`
- 🐛 **FIX:** Changed HTTP method from PATCH to PUT (TrueNAS requirement)
- 🐛 **FIX:** Added `-k` flag for self-signed SSL certificates
- 🐛 **FIX:** Redirected all logging to stderr (keeps stdout clean for function returns)
- 🐛 **FIX:** Made script self-sourcing (loads own config file)
- ✨ **NEW:** Dynamic share ID discovery (no hardcoded IDs)
- ✨ **NEW:** JSON response validation using jq
- ✨ **NEW:** State verification after toggle operations
- ✨ **NEW:** Retry logic with exponential backoff
- ✨ **NEW:** TrueNAS API health checks
- ✨ **NEW:** Flexible path matching (handles /mnt prefix variations)
- 📝 **DOCS:** Comprehensive API reference
- 📝 **DOCS:** Enhanced troubleshooting guide
- 📝 **DOCS:** Logging best practices
- 📝 **DOCS:** Complete testing workflow

**SABnzbd Plugin:**

- ✨ **NEW:** Multi-criteria busy detection (queue, speed, post-processing)
- ✨ **NEW:** Retry logic with exponential backoff
- ✨ **NEW:** Pure-bash JSON parsing (no jq dependency)
- ✨ **NEW:** Post-processing activity detection
- ✨ **NEW:** Configurable busy thresholds
- ✨ **NEW:** Health check before API calls
- 📝 **DOCS:** Complete environment variable reference
- 📝 **DOCS:** Busy detection criteria explained
- 🧪 **TEST:** 13/13 tests passing

### v1.0 (2024)

**Initial Implementation:**

- Basic container pause/unpause/stop/start operations
- Systemd timer-based scheduling
- Uptime Kuma integration
- Basic SABnzbd queue checking
- TrueNAS NFS/SMB share control (limited)
