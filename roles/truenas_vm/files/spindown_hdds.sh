#!/bin/bash

# Locations /mnt/swift/scripts/spindown_hdds.sh
# Purpose: Safely spin down ONLY the explicitly listed HDDs (by-id) when idle.

# LOG_FILE must live on SSD so logging never wakes HDDs.
# UTIL_THRESHOLD is in PERCENT (e.g. 10 = ten percent, 0.1 = one‑tenth percent)

set -euo pipefail
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# Absolute paths (cron-safe)
AWK=/usr/bin/awk
BASENAME=/usr/bin/basename
DATE=/bin/date
FLOCK=/usr/bin/flock
GREP=/usr/bin/grep
HDPARM=/usr/sbin/hdparm
IOSTAT=/usr/bin/iostat
SMARTCTL=/usr/sbin/smartctl
TEE=/usr/bin/tee
ZPOOL=/usr/sbin/zpool
NICE=/usr/bin/nice
IONICE=/usr/bin/ionice
READLINK=/usr/bin/readlink
STAT=/usr/bin/stat
TAIL=/usr/bin/tail
TOUCH=/usr/bin/touch

TARGET_DEVICES_BY_ID=(
  "/dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG" # backup 3TB
  "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90" # tank 8TB
  "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF" # tank 8TB
)

LOG_FILE="/mnt/swift/scripts/spindown.log" # TrueNAS cron runs as root
SAMPLE_DURATION=120           # seconds to sample iostat
UTIL_THRESHOLD=0.10           # %util below this => allow spindown
LOCK_FILE="/var/run/spindown_hdds.lock"
COOLDOWN_SECS=600             # optional anti-thrash; set 0 to disable
STAMP_DIR="/var/run/spindown-stamps"; mkdir -p "$STAMP_DIR"

HAD_ERROR=0

die() {
  HAD_ERROR=1
  echo "[$($DATE -Is)] ERROR: $*" | $TEE -a "$LOG_FILE"
  exit 1
}

info(){ echo "[$($DATE -Is)] $*"        | $TEE -a "$LOG_FILE"; }

mkdir -p "$(dirname "$LOG_FILE")" || die "Cannot create log dir"

for bin in $AWK $BASENAME $DATE $FLOCK $GREP $HDPARM $IOSTAT $SMARTCTL $TEE $ZPOOL $NICE $IONICE $READLINK $STAT $TAIL $TOUCH; do
  [[ -x "$bin" ]] || die "Required binary missing: $bin"
done

[[ $EUID -eq 0 ]] || die "Run as root."

# Single-run lock
exec {LOCKFD}>$LOCK_FILE || die "Cannot open lock file $LOCK_FILE"
$FLOCK -n "$LOCKFD" || { info "Another run is active; exiting."; exit 0; }

# Traps early so we always log completion/errors
trap 'HAD_ERROR=1; info "Aborted due to an error."' ERR
trap 'if [[ $HAD_ERROR -eq 0 ]]; then info "Spindown pass complete."; fi' EXIT

sleep $((RANDOM % 10))

[[ ${#TARGET_DEVICES_BY_ID[@]} -gt 0 ]] || die "No TARGET_DEVICES_BY_ID set."

info "Starting HDD spindown (SAMPLE_DURATION=${SAMPLE_DURATION}s, UTIL_THRESHOLD=${UTIL_THRESHOLD}%)."
for d in "${TARGET_DEVICES_BY_ID[@]}"; do info "  target: $d"; done

# 1) Abort if any ZFS scrub/resilver is running
if $ZPOOL status | $GREP -Eq "scan: (resilver|scrub) in progress"; then
  info "ZFS scan in progress; skipping spindown."
  exit 0
fi

for devid in "${TARGET_DEVICES_BY_ID[@]}"; do
  if [[ ! -e "$devid" ]]; then
    info "$devid does not exist; skipping."
    continue
  fi

  realnode=$($READLINK -f "$devid" || true)
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

  # Already in standby? Don't wake it
  $NICE -n 10 $IONICE -c3 $SMARTCTL -n standby -i "$devid" >/dev/null 2>&1

  rc=$?
  if [[ $rc -eq 2 ]]; then
    info "$devid already in standby; skipping."
    continue
  fi
  # If SMART not supported or other error, just log and continue
  if [[ $rc -ne 0 && $rc -ne 2 ]]; then
    info "$devid smartctl returned rc=$rc (non-fatal); continuing."
  fi

  # Skip if a SMART self-test is running
  if $NICE -n 10 $IONICE -c3 $SMARTCTL -n standby -c "$devid" 2>/dev/null | $GREP -qi "Self-test routine in progress"; then
    info "$devid SMART self-test running; skipping."
    continue
  fi

  # Optional: anti-thrash cooldown
  stamp="$STAMP_DIR/${sdnode}.stamp"
  if [[ $COOLDOWN_SECS -gt 0 && -f "$stamp" ]]; then
    last=$($STAT -c %Y "$stamp" 2>/dev/null || echo 0)
    now=$($DATE +%s)
    if (( now - last < COOLDOWN_SECS )); then
      info "$devid cooldown active ($(($now - $last))s < ${COOLDOWN_SECS}s); skipping."
      continue
    fi
  fi

  # Sample iostat for SAMPLE_DURATION and read final %util
  info "$devid sampling I/O for ${SAMPLE_DURATION}s…"
  util_line=$($NICE -n 10 $IONICE -c3 $IOSTAT -d -x -y "$sdnode" "$SAMPLE_DURATION" 2>/dev/null \
              | $GREP -E "^[[:space:]]*$sdnode[[:space:]]" | $TAIL -n1 || true)

  if [[ -z "$util_line" ]]; then
    info "$devid no iostat line captured; treating as idle."
    util="0.00"
  else
    util=$($AWK '{print $(NF)+0}' <<<"$util_line")
  fi
  info "$devid %util=${util}%"

  [[ -n "$util_line" ]] && info "$devid iostat: $util_line"

  # ZFS-aware guard: match by the label actually used in pools
  # Try match by by-id first, then by sd node, then by the real node's basename
  devlabel_byid="$($BASENAME "$devid")"
  devlabel_sdx="$sdnode"
  devlabel_real="$($BASENAME "$realnode")"

  # Use on zpool iostat:
  if $NICE -n 10 $IONICE -c3 $ZPOOL iostat -v -p 1 1 2>/dev/null | $AWK \
    -v d1="$devlabel_byid" -v d2="$devlabel_sdx" -v d3="$devlabel_real" '
    {
      # name is col 1; last two cols are read/write B/s (with -p)
      name=$1; r=$(NF-1)+0; w=$(NF)+0
      # match by substring to handle paths/by-id variations
      if (index(name,d1)>0 || index(name,d2)>0 || index(name,d3)>0) { if (r+w>0) act=1 }
    }
    END{ exit (act?0:1) }'
  then
    info "$devid zpool iostat shows activity; skipping."
    continue
  fi

  # Compare as numbers
  if $AWK -v u="$util" -v t="$UTIL_THRESHOLD" 'BEGIN{exit !(u < t)}'; then
    info "Spinning down $devid…"
    if $HDPARM -y "$devid" >/dev/null 2>&1; then
      info "$devid sent to standby."
      $TOUCH "$stamp" || true
    else
      info "$devid hdparm -y failed; backing off."
      $TOUCH "$stamp" || true
    fi
  else
    info "$devid busy; skipping."
  fi
done
