#!/bin/bash
# File: /home/truenas_admin/spindown_hdds.sh
# Purpose: Safely spin down ONLY the explicitly listed HDDs (by-id) when idle.

set -euo pipefail

# --------- CONFIG: list your target disks by stable /dev/disk/by-id paths ---------

# Example entries (replace with your own):
#   /dev/disk/by-id/ata-ST8000VN004-2M2101_ZCT0ABCDE
#   /dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN1TN5X
TARGET_DEVICES_BY_ID=(
  # "/dev/disk/by-id/ata-XXXXXXXX"
  # "/dev/disk/by-id/scsi-XXXXXXXX"
)

LOG_FILE="${HOME}/spindown.log"
SAMPLE_DURATION=120           # seconds to sample iostat
UTIL_THRESHOLD=0.1           # %util threshold below which we allow spindown
LOCK_FILE="/var/run/spindown_hdds.lock"

# Absolute paths (cron-safe)
AWK=/usr/bin/awk
BASENAME=/usr/bin/basename
DATE=/bin/date
FLOCK=/usr/bin/flock
GREP=/usr/bin/grep
HDPARM=/usr/sbin/hdparm
IOSTAT=/usr/bin/iostat
SED=/usr/bin/sed
SMARTCTL=/usr/sbin/smartctl
TEE=/usr/bin/tee
ZPOOL=/usr/sbin/zpool

PATH=/usr/sbin:/usr/bin:/sbin:/bin

die() { echo "[$($DATE -Is)] ERROR: $*" | $TEE -a "$LOG_FILE"; exit 1; }
info(){ echo "[$($DATE -Is)] $*" | $TEE -a "$LOG_FILE"; }

# Root check
[[ $EUID -eq 0 ]] || die "Run as root (TrueNAS cron usually runs as root)."

# Single-run lock
exec {LOCKFD}>$LOCK_FILE || die "Cannot open lock file $LOCK_FILE"
$FLOCK -n "$LOCKFD" || { info "Another run is active; exiting."; exit 0; }

# Sanity: require at least one device
[[ ${#TARGET_DEVICES_BY_ID[@]} -gt 0 ]] || die "No TARGET_DEVICES_BY_ID set."

info "Starting HDD spindown (SAMPLE_DURATION=${SAMPLE_DURATION}s, UTIL_THRESHOLD=${UTIL_THRESHOLD}%)."
info "Targets:"
for d in "${TARGET_DEVICES_BY_ID[@]}"; do info "  $d"; done

# 1) Abort if any ZFS scrub/resilver is running (prevents spin-up thrash)
if $ZPOOL status | $GREP -Eq "scan: (resilver|scrub) in progress"; then
  info "ZFS scan in progress; skipping spindown."
  exit 0
fi

# Iterate each explicit by-id device
for devid in "${TARGET_DEVICES_BY_ID[@]}"; do
  # Must exist & be a symlink
  if [[ ! -e "$devid" ]]; then
    info "$devid does not exist, skipping."
    continue
  fi

  # Resolve to real block node (e.g., /dev/sdX)
  realnode=$(readlink -f "$devid" || true)
  if [[ -z "$realnode" || ! -e "$realnode" ]]; then
    info "$devid could not resolve to a block node; skipping."
    continue
  fi
  sdnode=$($BASENAME "$realnode" 2>/dev/null || true)
  if [[ -z "$sdnode" ]]; then
    info "$devid could not resolve a device name; skipping."
    continue
  fi

  # Rotational check (skip SSDs)
  rota="/sys/block/${sdnode}/queue/rotational"
  if [[ ! -f "$rota" ]]; then
    info "$devid ($sdnode) has no rotational attribute; skipping."
    continue
  fi
  if [[ "$(< "$rota")" != "1" ]]; then
    info "$devid ($sdnode) is non-rotational (SSD); skipping."
    continue
  fi

  # Already in standby? Use smartctl -n standby (exit code 2 means standby) to avoid waking
  if $SMARTCTL -n standby -i "$devid" >/dev/null 2>&1; then
    if [[ $? -eq 2 ]]; then
      info "$devid already in standby; skipping."
      continue
    fi
  fi

  # Skip if a SMART self-test is running
  if $SMARTCTL -c "$devid" 2>/dev/null | $GREP -qi "Self-test routine in progress"; then
    info "$devid SMART self-test running; skipping."
    continue
  fi

  # Sample iostat for SAMPLE_DURATION and grab the last %util for this device
  info "$devid sampling I/O for ${SAMPLE_DURATION}s…"
  util_line=$($IOSTAT -d -x -y "$sdnode" "$SAMPLE_DURATION" 2 | $GREP -E "^[[:space:]]*$sdnode[[:space:]]" | tail -n1 || true)
  if [[ -z "$util_line" ]]; then
    info "$devid no iostat line captured; treating as idle."
    util=0.00
  else
    util=$($AWK '{print $NF+0}' <<<"$util_line")
  fi
  info "$devid %util=${util}%"

  # Numeric compare
  if awk -v u="$util" -v t="$UTIL_THRESHOLD" 'BEGIN{exit !(u < t)}'; then
    info "Spinning down $devid…"
    if $HDPARM -y "$devid" >/dev/null 2>&1; then
      info "$devid sent to standby."
    else
      info "$devid hdparm -y failed."
    fi
  else
    info "$devid busy; skipping."
  fi
done

info "Spindown pass complete."
