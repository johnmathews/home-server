#!/bin/bash

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

# ---------- CONFIG ----------
# Pair each device with a friendly label: "<by-id>|<label>"
TARGETS=(
	"/dev/disk/by-id/ata-ST3000DM007-1WY10G_ZFN19YRG|backup"
	"/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5AS90|tank"
	"/dev/disk/by-id/ata-ST8000VN004-3CP101_WWZ5TZSF|tank"
)

LOG_FILE="/mnt/swift/scripts/spindown.log" # keep on SSD; never wakes HDDs
SAMPLE_DURATION=120                        # seconds for iostat sampling
UTIL_THRESHOLD=0.10                        # %util below this (0.1 = 0.1%) => allow spindown
LOCK_FILE="/var/run/spindown_hdds.lock"
COOLDOWN_SECS=600 # anti-thrash; 0 disables
STAMP_DIR="/var/run/spindown-stamps"

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
		log_ok "Spindown pass complete."
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
	log_note "Another run is active; exiting."
	exit 0
}

# Small jitter so multiple cron hosts don't collide (max 10s)
sleep $((RANDOM % 10))

((${#TARGETS[@]} > 0)) || die "No TARGETS configured."

log "============================================================"
log "Starting HDD spindown  ${C_DIM}(SAMPLE_DURATION=${SAMPLE_DURATION}s, UTIL_THRESHOLD=${UTIL_THRESHOLD}%)${C_RESET}"
for pair in "${TARGETS[@]}"; do
	IFS='|' read -r devid label <<<"$pair"
	log "  target: ${C_BOLD}${label}${C_RESET} [$devid]"
done

# Abort if any ZFS scrub/resilver is running
if "$ZPOOL" status 2>/dev/null | "$GREP" -Eq "scan: (resilver|scrub) in progress"; then
	log_warn "ZFS scan in progress; skipping spindown."
	exit 0
fi

# ---------- MAIN LOOP ----------
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
  # Already in standby?
  rc=0
  "$NICE" -n 10 "$IONICE" -c3 "$SMARTCTL" -n standby -i "$devid" >/dev/null 2>&1 || rc=$?

  case "$rc" in
    0) ;;  # OK, proceed
    2)
      log_note "${label} [$devid] (${sdnode}): already in standby; skipping."
      continue
      ;;
    *)
      log_warn "${label} [$devid]: smartctl returned rc=$rc (non-fatal); continuing."
      ;;
  esac

	if [[ $rc -eq 0 ]]; then
		# Skip if a SMART self-test is running (won’t wake due to -n standby)
		if "$NICE" -n 10 "$IONICE" -c3 "$SMARTCTL" -n standby -c "$devid" 2>/dev/null | "$GREP" -qi "Self-test routine in progress"; then
			log_note "${label} [$devid] (${sdnode}): SMART self-test running; skipping."
			continue
		fi
	fi

	# Anti-thrash cooldown
	stamp="$STAMP_DIR/${sdnode}.stamp"
	if [[ $COOLDOWN_SECS -gt 0 && -f "$stamp" ]]; then
		last=$("$STAT" -c %Y "$stamp" 2>/dev/null || echo 0)
		now=$("$DATE" +%s)
		if ((now - last < COOLDOWN_SECS)); then
			log_note "${label} [$devid] (${sdnode}): cooldown active $((now - last))s < ${COOLDOWN_SECS}s; skipping."
			continue
		fi
	fi

	# Sample iostat and read final %util
	echo | "$TEE" -a "$LOG_FILE"
	log "${label} [$devid] (${sdnode}): sampling I/O for ${SAMPLE_DURATION}s…"
	util_line="$(
		"$NICE" -n 10 "$IONICE" -c3 \
			"$IOSTAT" -d -x -y "$sdnode" "$SAMPLE_DURATION" 2 2>/dev/null |
			"$GREP" -E "^[[:space:]]*$sdnode[[:space:]]" | "$TAIL" -n1 || true
	)"

	if [[ -z "$util_line" ]]; then
		util="0.00"
		log_warn "${label} [$devid]: no iostat line captured; treating as idle."
	else
		util=$("$AWK" '{print $(NF)+0}' <<<"$util_line")
	fi
	log "${label} [$devid] (${sdnode}): utilisation=${C_BOLD}${util}%${C_RESET}"

	# ZFS-aware guard: if reads/writes non-zero, skip
	devlabel_byid="$("$BASENAME" "$devid")"
	devlabel_sdx="$sdnode"
	devlabel_real="$("$BASENAME" "$realnode")"
	if "$NICE" -n 10 "$IONICE" -c3 "$ZPOOL" iostat -v -p 1 1 2>/dev/null |
		"$AWK" -v d1="$devlabel_byid" -v d2="$devlabel_sdx" -v d3="$devlabel_real" '
       { name=$1; r=$(NF-1)+0; w=$(NF)+0; if (index(name,d1)||index(name,d2)||index(name,d3)) if (r+w>0) act=1 }
       END{ exit act?0:1 }'; then
		log_note "${label} [$devid] (${sdnode}): zpool iostat shows activity; skipping."
		continue
	fi

	# Compare as numbers: spin down if util < threshold
	if "$AWK" -v u="$util" -v t="$UTIL_THRESHOLD" 'BEGIN{exit !(u < t)}'; then
		log_warn "Spinning down ${label} [$devid] (${sdnode})…"
		if "$HDPARM" -y "$devid" >/dev/null 2>&1; then
			log_ok "${label} [$devid]: sent to standby."
			"$TOUCH" "$stamp" || true
		else
			log_err "${label} [$devid]: hdparm -y failed; backing off."
			"$TOUCH" "$stamp" || true
		fi
	else
		log_note "${label} [$devid] (${sdnode}): busy (util >= ${UTIL_THRESHOLD}%), skipping."
	fi
done
