#!/bin/bash

# Version: 2025-01-24 10:00

# Location: /mnt/swift/scripts/spindown_hdds.sh
# Purpose: Safely spin down ONLY the explicitly listed HDDs (by-id) when idle.

# Notes:
#   - Uses ANSI color in logs for readability. Disable with NO_COLOR=1 env var.
#   - Disks are configured as "by-id|label" pairs in TARGETS.
#   - Plain logs (no color escape codes), run it with: NO_COLOR=1 /mnt/swift/scripts/spindown_hdds.sh

# ---------- RIGOR ----------
set -Eeuo pipefail
shopt -s lastpipe
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

# ---------- CONFIG ----------
# Pair each device with a friendly label: "<by-id>|<label>"
# original 3TB backup disk "/dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG|backup"
TARGETS=(
  "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90|backup"
  "/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF|backup"
  "/dev/disk/by-id/ata-ST16000NT001-3LV101_K3S04BKQ|tank"
  "/dev/disk/by-id/ata-ST16000NT001-3LV101_ZR5GK5G9|tank"
)

SAMPLE_DURATION=900                          # seconds for iostat sampling (all disks sampled in parallel)
UTIL_THRESHOLD=0.03                          # %util below this (0.1 = 0.1%) => allow spindown
LOG_FILE="/mnt/swift/logs/spindown_hdds.log" # keep on SSD; never wakes HDDs
COOLDOWN_SECS=1800                           # 30 min cooldown to reduce thrash (0 disables)
LOCK_FILE="/var/run/spindown_hdds.lock"
STAMP_DIR="/var/run/spindown-stamps"

# ---------- ABSOLUTE PATHS (cron-safe) ----------
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
MKDIR=/usr/bin/mkdir

# ---------- COLORS ----------
if [[ -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_INFO=$'\033[36m' # cyan
  C_WARN=$'\033[33m' # yellow
  C_ERR=$'\033[31m'  # red
  C_OK=$'\033[32m'   # green
  C_NOTE=$'\033[35m' # magenta
else
  C_RESET= C_DIM= C_BOLD= C_INFO= C_WARN= C_ERR= C_OK= C_NOTE=
fi

HAD_ERROR=0

ts() { "$DATE" "+%F %T"; }

_log() {
  # $1=color  $2=level  $3=message
  local color="$1" lvl="$2" msg="$3"
  # Timestamp + level padded to width 5
  printf "[%s] %s%-5s%s %s\n" "$(ts)" "$color" "$lvl" "$C_RESET" "$msg" | "$TEE" -a "$LOG_FILE"
}

log() { _log "$C_INFO" "INFO" "$*"; }
log_warn() { _log "$C_WARN" "WARN" "$*"; }
log_err() { _log "$C_ERR" "ERROR" "$*"; }
log_ok() { _log "$C_OK" "OK" "$*"; }
log_note() { _log "$C_NOTE" "NOTE" "$*"; }

die() {
  HAD_ERROR=1
  log_err "$*"
  exit 1
}

# ---------- ERROR/EXIT TRAPS ----------
on_err() {
  local exit_code=$?
  local line=${BASH_LINENO[0]:-?}
  local cmd=${BASH_COMMAND:-?}

  HAD_ERROR=1
  log_err "Aborted with exit code ${exit_code}"
  log_err "Failing command: ${C_BOLD}${cmd}${C_RESET}"
  log_err "At line: ${line} in ${BASH_SOURCE[1]:-main}"

  # Mini stack (skip this function & trap frame)
  local i
  for ((i = 1; i < ${#FUNCNAME[@]}; i++)); do
    local fn="${FUNCNAME[$i]}"
    local src="${BASH_SOURCE[$i]}"
    local lno="${BASH_LINENO[$((i - 1))]}"
    [[ -n "$fn" ]] || fn="main"
    log_note "  at ${fn} (${src}:${lno})"
  done
  exit "$exit_code"
}

on_exit() {
  if [[ $HAD_ERROR -eq 0 ]]; then
    echo | "$TEE" -a "$LOG_FILE"
    log_ok "Spindown script complete. Exiting."
  fi
}

trap on_err ERR
trap on_exit EXIT

# ---------- PRECHECKS ----------
"$MKDIR" -p "$(dirname "$LOG_FILE")" || die "Cannot create log dir: $(dirname "$LOG_FILE")"
"$MKDIR" -p "$STAMP_DIR" || die "Cannot create stamp dir: $STAMP_DIR"

for bin in "$AWK" "$BASENAME" "$DATE" "$FLOCK" "$GREP" "$HDPARM" "$IOSTAT" "$SMARTCTL" "$TEE" "$ZPOOL" "$NICE" "$IONICE" "$READLINK" "$STAT" "$TAIL" "$TOUCH" "$MKDIR"; do
  [[ -x "$bin" ]] || die "Required binary missing: $bin"
done

[[ $EUID -eq 0 ]] || die "Run as root."

# Single-run lock
exec {LOCKFD}>"$LOCK_FILE" || die "Cannot open lock file $LOCK_FILE"
"$FLOCK" -n "$LOCKFD" || {
  echo | "$TEE" -a "$LOG_FILE"
  log_note "Another run is active; exiting."
  exit 0
}

# Small jitter so multiple cron hosts don't collide (max 10s)
sleep $((RANDOM % 10))

((${#TARGETS[@]} > 0)) || die "No TARGETS configured."

echo | "$TEE" -a "$LOG_FILE"
log "============================================================"
log "Starting HDD spindown  ${C_DIM}(SAMPLE_DURATION=${SAMPLE_DURATION}s, UTIL_THRESHOLD=${UTIL_THRESHOLD}%)${C_RESET}"
for pair in "${TARGETS[@]}"; do
  IFS='|' read -r devid label <<<"$pair"
  sdnode=""
  if [[ -e "$devid" ]]; then
    realnode=$("$READLINK" -f "$devid") || true
    if [[ -n "$realnode" && -e "$realnode" ]]; then
      sdnode=$("$BASENAME" "$realnode")
    else
      sdnode="(unresolved)"
    fi
  else
    sdnode="(missing)"
  fi
  log "  target: ${C_BOLD}${sdnode}${C_RESET} - ${label} [$devid]"
done

# Abort if any ZFS scrub/resilver is running
if "$ZPOOL" status 2>/dev/null | "$GREP" -Eq "scan: (resilver|scrub) in progress"; then
  log_warn "ZFS scan in progress; skipping spindown."
  exit 0
fi

# ---------- PRE-FLIGHT: Collect valid spinning disks ----------
# Arrays to track disks that pass all pre-flight checks
declare -a SAMPLE_DISKS=()       # sdnode names for iostat
declare -A DISK_DEVID=()         # sdnode -> by-id path
declare -A DISK_LABEL=()         # sdnode -> friendly label
declare -A DISK_REALNODE=()      # sdnode -> /dev/sdX path

log "Pre-flight: checking disk states…"

for pair in "${TARGETS[@]}"; do
  IFS='|' read -r devid label <<<"$pair"

  if [[ ! -e "$devid" ]]; then
    log_warn "${label}: device not found [$devid]; skipping."
    continue
  fi

  realnode=$("$READLINK" -f "$devid")
  sdnode=$("$BASENAME" "$realnode")
  if [[ -z "${sdnode:-}" || ! -e "$realnode" ]]; then
    log_warn "${label}: could not resolve block node for [$devid]; skipping."
    continue
  fi

  # Rotational check (skip SSDs)
  rota="/sys/block/${sdnode}/queue/rotational"
  if [[ ! -f "$rota" ]]; then
    log_warn "${label} [$devid] (${sdnode}): no rotational attribute; skipping."
    continue
  fi
  if [[ "$(<"$rota")" != "1" ]]; then
    log_note "${label} [$devid] (${sdnode}): non-rotational (SSD); skipping."
    continue
  fi

  # Already in standby?
  rc=0
  "$NICE" -n 10 "$IONICE" -c3 "$SMARTCTL" -n standby -i "$devid" >/dev/null 2>&1 || rc=$?

  case "$rc" in
  0) ;; # OK, proceed
  2)
    log_note "${label} (${sdnode}): already in standby; skipping."
    continue
    ;;
  *)
    log_warn "${label}: smartctl returned rc=$rc (non-fatal); continuing."
    ;;
  esac

  if [[ $rc -eq 0 ]]; then
    # Skip if a SMART self-test is running (won't wake due to -n standby)
    if "$NICE" -n 10 "$IONICE" -c3 "$SMARTCTL" -n standby -c "$devid" 2>/dev/null | "$GREP" -qi "Self-test routine in progress"; then
      log_note "${label} (${sdnode}): SMART self-test running; skipping."
      continue
    fi
  fi

  # Anti-thrash cooldown
  stamp="$STAMP_DIR/${sdnode}.stamp"
  if [[ $COOLDOWN_SECS -gt 0 && -f "$stamp" ]]; then
    last=$("$STAT" -c %Y "$stamp" 2>/dev/null || echo 0)
    now=$("$DATE" +%s)
    if ((now - last < COOLDOWN_SECS)); then
      log_note "${label} (${sdnode}): cooldown active $((now - last))s < ${COOLDOWN_SECS}s; skipping."
      continue
    fi
  fi

  # Disk passed all checks; add to sample list
  SAMPLE_DISKS+=("$sdnode")
  DISK_DEVID["$sdnode"]="$devid"
  DISK_LABEL["$sdnode"]="$label"
  DISK_REALNODE["$sdnode"]="$realnode"
  log "  ${C_OK}✓${C_RESET} ${label} (${sdnode}): queued for sampling"
done

# ---------- PARALLEL IOSTAT SAMPLING ----------
if [[ ${#SAMPLE_DISKS[@]} -eq 0 ]]; then
  log_note "No disks require sampling; exiting."
  exit 0
fi

echo | "$TEE" -a "$LOG_FILE"
log "Sampling ${#SAMPLE_DISKS[@]} disk(s) in parallel for ${SAMPLE_DURATION}s: ${SAMPLE_DISKS[*]}"

# Run iostat on all disks simultaneously; capture output
iostat_output="$(
  "$NICE" -n 10 "$IONICE" -c3 \
    "$IOSTAT" -d -x -y "${SAMPLE_DISKS[@]}" "$SAMPLE_DURATION" 2 2>/dev/null || true
)"

# Parse iostat output into associative array: sdnode -> %util
declare -A DISK_UTIL=()
for sdnode in "${SAMPLE_DISKS[@]}"; do
  # Get the last line for this device (second sample, ignoring first)
  util_line=$("$GREP" -E "^[[:space:]]*${sdnode}[[:space:]]" <<<"$iostat_output" | "$TAIL" -n1 || true)
  if [[ -z "$util_line" ]]; then
    DISK_UTIL["$sdnode"]="0.00"
    log_warn "${DISK_LABEL[$sdnode]}: no iostat line captured; treating as idle."
  else
    DISK_UTIL["$sdnode"]=$("$AWK" '{print $(NF)+0}' <<<"$util_line")
  fi
done

# ---------- DECISION PHASE ----------
echo | "$TEE" -a "$LOG_FILE"
log "Making spindown decisions…"

for sdnode in "${SAMPLE_DISKS[@]}"; do
  devid="${DISK_DEVID[$sdnode]}"
  label="${DISK_LABEL[$sdnode]}"
  realnode="${DISK_REALNODE[$sdnode]}"
  util="${DISK_UTIL[$sdnode]}"

  log "${label} (${sdnode}): ${C_BOLD}${util}%${C_RESET} utilisation (threshold: ${UTIL_THRESHOLD}%)"

  # ZFS-aware guard: if reads/writes non-zero, skip
  devlabel_byid="$("$BASENAME" "$devid")"
  devlabel_sdx="$sdnode"
  devlabel_real="$("$BASENAME" "$realnode")"
  if "$NICE" -n 10 "$IONICE" -c3 "$ZPOOL" iostat -v -p 1 1 2>/dev/null |
    "$AWK" -v d1="$devlabel_byid" -v d2="$devlabel_sdx" -v d3="$devlabel_real" '
       { name=$1; r=$(NF-1)+0; w=$(NF)+0; if (index(name,d1)||index(name,d2)||index(name,d3)) if (r+w>0) act=1 }
       END{ exit act?0:1 }'; then
    log_note "${label} (${sdnode}): zpool iostat shows activity; skipping spindown."
    continue
  fi

  # Compare as numbers: spin down if util < threshold
  stamp="$STAMP_DIR/${sdnode}.stamp"
  if "$AWK" -v u="$util" -v t="$UTIL_THRESHOLD" 'BEGIN{exit !(u < t)}'; then
    log_warn "${label} (${sdnode}): ${util}% < ${UTIL_THRESHOLD}% threshold; spinning down…"
    if "$HDPARM" -y "$devid" >/dev/null 2>&1; then
      log_ok "${label} (${sdnode}): disk in standby."
      "$TOUCH" "$stamp" || true
    else
      log_err "${label} (${sdnode}): hdparm -y failed; backing off."
      "$TOUCH" "$stamp" || true
    fi
  else
    log_note "${label} (${sdnode}): ${util}% >= ${UTIL_THRESHOLD}% threshold; skipping spindown."
  fi
done
