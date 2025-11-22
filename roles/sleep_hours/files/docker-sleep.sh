#!/usr/bin/env bash
# vim: ft=sh

# Safer defaults
set -uo pipefail

# Optional bash -x tracing when QUIET_DEBUG=1
export PS4='+ ts=$(date +%FT%T%z) line=${LINENO} cmd='
[[ "${QUIET_DEBUG:-0}" == "1" ]] && set -x

ACTION="${1:-}"

# Select list file based on action
case "$ACTION" in
  pause|unpause) LIST="${QUIET_LIST:-/etc/sleep-hours/containers.pause.list}" ;;
  stop|start) LIST="${QUIET_LIST:-/etc/sleep-hours/containers.stop.list}" ;;
esac

# Validate required tools and environment variables early
validate_environment() {
   local errors=0
   
   # Check for required commands
   for cmd in docker timeout; do
      if ! command -v "$cmd" >/dev/null 2>&1; then
         printf 'ERROR: Required command not found: %s\n' "$cmd" >&2
         ((errors += 1))
      fi
   done
   
   # Validate numeric environment variables
   if [[ -n "${QUIET_CMD_TIMEOUT_S:-}" ]]; then
      if ! [[ "$QUIET_CMD_TIMEOUT_S" =~ ^[0-9]+$ ]]; then
         printf 'ERROR: QUIET_CMD_TIMEOUT_S must be a positive integer, got: %s\n' "$QUIET_CMD_TIMEOUT_S" >&2
         ((errors += 1))
      fi
   fi
   
   if [[ -n "${DOCKER_STOP_TIMEOUT_S:-}" ]]; then
      if ! [[ "$DOCKER_STOP_TIMEOUT_S" =~ ^[0-9]+$ ]]; then
         printf 'ERROR: DOCKER_STOP_TIMEOUT_S must be a positive integer, got: %s\n' "$DOCKER_STOP_TIMEOUT_S" >&2
         ((errors += 1))
      fi
   fi
   
   if [[ -n "${IO_SAMPLE_S:-}" ]]; then
      if ! [[ "$IO_SAMPLE_S" =~ ^[0-9]+$ ]] || [[ "$IO_SAMPLE_S" -eq 0 ]]; then
         printf 'ERROR: IO_SAMPLE_S must be a positive integer, got: %s\n' "$IO_SAMPLE_S" >&2
         ((errors += 1))
      fi
   fi
   
   if [[ $errors -gt 0 ]]; then
      exit 1
   fi
}

# -------- logging with levels --------
# QUIET_LOG_LEVEL: debug|info|warn|error (default info)
_log_level="${QUIET_LOG_LEVEL:-info}"
case "${_log_level}" in
debug) LOG_THRESH=10 ;;
info) LOG_THRESH=20 ;;
warn) LOG_THRESH=30 ;;
error) LOG_THRESH=40 ;;
*) LOG_THRESH=20 ;;
esac
level_num() {
  case "$1" in
  debug) echo 10 ;;
  info) echo 20 ;;
  warn) echo 30 ;;
  error) echo 40 ;;
  *) echo 20 ;;
  esac
}
should_log() {
  local want
  want=$(level_num "$1")
  [[ $want -ge $LOG_THRESH ]]
}
_log() {
  local level="$1" container="$2" event="$3" reason="$4"
  shift 4
  if should_log "$level"; then
    printf 'ts=%s level=%s container=%s action=%s event=%s reason=%s' \
      "$(date +%FT%T%z)" "$level" "${container:-_}" "${ACTION:-unknown}" "$event" "$reason"
    for kv in "$@"; do printf ' %s' "$kv"; done
    printf '\n'
  fi
}
log_debug() { _log debug "$@"; }
log_info() { _log info "$@"; }
log_warn() { _log warn "$@"; }
log_err() { _log error "$@"; }

# -------- human-readable messages (plain text) --------
msg() {
   printf '%s\n' "$@"
}

fail_early() {
   _log error "_" "failed" "$1" "$2"
   exit "${3:-1}"
}

# -------- config for retries/timeouts --------
QUIET_RETRIES="${QUIET_RETRIES:-3}"
QUIET_RETRY_DELAY_S="${QUIET_RETRY_DELAY_S:-2}"
QUIET_CMD_TIMEOUT_S="${QUIET_CMD_TIMEOUT_S:-15}"
DOCKER_LOG_LINES="${DOCKER_LOG_LINES:-5}"

# Check for timeout command (use command -v or which for compatibility)
HAS_TIMEOUT=0
if command -v timeout >/dev/null 2>&1 || which timeout >/dev/null 2>&1; then 
   HAS_TIMEOUT=1
fi

# -------- process locking --------
# Prevent concurrent executions of the same action to avoid race conditions
LOCK_DIR="${LOCK_DIR:-/run/sleep-hours}"
LOCK_FILE="${LOCK_DIR}/docker-sleep-${ACTION}.lock"

acquire_lock() {
   # Create lock directory if needed
   mkdir -p "$LOCK_DIR" 2>/dev/null || true
   
   # Try to acquire exclusive lock using flock (atomic operation)
   if command -v flock >/dev/null 2>&1; then
      exec {lock_fd}>"$LOCK_FILE" 2>/dev/null || return 1
      if ! flock -n "$lock_fd" 2>/dev/null; then
         _log warn "_" lock "already_running" "action=$ACTION"
         msg "WARNING: Another $ACTION operation is already running, waiting..."
         flock "$lock_fd"  # Wait for lock
      fi
      _log debug "_" lock "acquired" "action=$ACTION"
      return 0
   else
      # Fallback: simple file-based lock if flock unavailable
      if [[ -f "$LOCK_FILE" ]]; then
         local lock_pid
         lock_pid=$(cat "$LOCK_FILE" 2>/dev/null) || return 1
         if kill -0 "$lock_pid" 2>/dev/null; then
            _log warn "_" lock "already_running_pid=$lock_pid" "action=$ACTION"
            return 1
         fi
      fi
      echo "$$" > "$LOCK_FILE" 2>/dev/null || return 1
      return 0
   fi
}

release_lock() {
   if [[ -f "$LOCK_FILE" ]]; then
      rm -f "$LOCK_FILE" 2>/dev/null || true
   fi
}

# Ensure lock is released on exit
trap 'release_lock' EXIT

# Optional quiet-hours window guard (skip work if we're outside)
QUIET_START="${QUIET_HOURS_START:-${docker_quiet_hours_start:-}}"
QUIET_END="${QUIET_HOURS_END:-${docker_quiet_hours_end:-}}"

is_within_quiet_window() {
  # If not configured, do nothing (treat as outside window)
  [[ -z "${QUIET_START}" || -z "${QUIET_END}" ]] && return 1
  # Compare seconds since midnight (localtime)
  local now_s start_s end_s
  now_s=$(date +%s)
  # build today's times
  local today
  today=$(date +%F)
  start_s=$(date -d "${today} ${QUIET_START}" +%s 2>/dev/null || echo 0)
  end_s=$(date -d "${today} ${QUIET_END}" +%s 2>/dev/null || echo 0)

  # If end is "next day" (e.g., 23:55 .. 08:45), treat wrap-around
  if ((end_s <= start_s)); then
    # within if time >= start OR time < end(next day)
    if ((now_s >= start_s)); then return 0; fi
    local tomorrow
    tomorrow=$(date -d "${today} +1 day" +%F)
    end_s=$(date -d "${tomorrow} ${QUIET_END}" +%s)
    if ((now_s < end_s)); then return 0; fi
    return 1
  else
    # same-day window
    ((now_s >= start_s && now_s < end_s))
  fi
}

# -------- validate action and environment --------
case "$ACTION" in
pause | unpause | stop | start) ;;
*) fail_early usage "usage=$0 {pause|unpause|stop|start}" 2 ;;
esac

# Validate environment at startup
validate_environment

# Acquire lock to prevent concurrent execution
if ! acquire_lock; then
   fail_early lock_failed "Could not acquire lock for action=$ACTION" 1
fi

# Skip work if outside window for pause/stop
if [[ "$ACTION" == "pause" || "$ACTION" == "stop" ]] && ! is_within_quiet_window; then
   _log info _ window outside "start=${QUIET_START:-na} end=${QUIET_END:-na}"
   msg "Outside quiet window (${QUIET_START:-na} to ${QUIET_END:-na}), skipping $ACTION"
   exit 0
fi

# Print action header
msg "Starting $ACTION action"
msg "Using container list: $LIST"

# -------- docker binary --------
DOCKER_BIN="$(command -v docker || true)"
[[ -x "${DOCKER_BIN:-}" ]] || fail_early docker_not_found "PATH=$PATH" 1

# -------- grace logic plugins --------
common_loaded=0
load_common() {
  if ((common_loaded == 0)) && [[ -r "${GRACE_DIR}/common.sh" ]]; then
    # shellcheck source=/dev/null
    . "${GRACE_DIR}/common.sh"
    common_loaded=1
  fi
}

# choose plugin by container name (override here if names differ)
plugin_for() {
  case "$1" in
  qbittorrent) echo "qbittorrent.sh" ;;
  sabnzbd) echo "sabnzbd.sh" ;;
  radarr) echo "radarr.sh" ;;
  sonarr) echo "sonarr.sh" ;;
  prowlarr) echo "prowlarr.sh" ;;
  jellyseerr) echo "jellyseerr.sh" ;;
  bazarr) echo "bazarr.sh" ;;
  filebrowser) echo "filebrowser.sh" ;;
  booklore) echo "booklore.sh" ;;
  booklore-mariadb) echo "booklore-mariadb.sh" ;;
  *) echo "default.sh" ;;
  esac
}

# Each plugin must define:
#   check_busy <container>   -> exit 0 if BUSY, 1 if IDLE/unknown
#   (they can use helpers from common.sh)
is_busy() {
  local name="$1"
  local plug
  plug="$(plugin_for "$name")"
  load_common
  if [[ -r "${GRACE_DIR}/${plug}" ]]; then
    # shellcheck source=/dev/null
    . "${GRACE_DIR}/${plug}"
    if declare -F check_busy >/dev/null 2>&1; then
      if check_busy "$name"; then
        return 0 # busy
      else
        return 1 # idle
      fi
    fi
  fi
  # If no plugin, fall back to generic heuristic
  if declare -F check_busy_generic >/dev/null 2>&1; then
    check_busy_generic "$name" && return 0 || return 1
  fi
  return 1
}

# -------- container source --------
get_containers() {
   if [[ "${LIST}" == "-" ]]; then
     "$DOCKER_BIN" ps --filter "label=quiet-hours=true" --format '{{.Names}}'
   else
     [[ -r "$LIST" ]] || fail_early list_missing "path=$LIST cannot be read (check permissions)" 1
     # Use direct read to catch permission changes between check and use
     cat -- "$LIST" 2>/dev/null || fail_early list_read "failed to read $LIST" 1
   fi
}

# -------- helpers --------
is_comment_or_empty() {
   # Check if line is a comment or empty (more explicit than regex)
   # Lines starting with # are comments, empty or whitespace-only lines are skipped
   local line="$1"
   [[ -z "$line" ]] && return 0  # empty line
   [[ "${line:0:1}" == "#" ]] && return 0  # comment line
   return 1  # not a comment or empty
}

trim_line() {
   local s="${1%$'\r'}"
   s="${s#"${s%%[![:space:]]*}"}"
   s="${s%"${s##*[![:space:]]}"}"
   printf '%s' "$s"
}

inspect_fields() {
  # running paused healthStatus
  "$DOCKER_BIN" inspect -f '{{.State.Running}} {{.State.Paused}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$1" 2>/dev/null || true
}
normalize_state() {
  local running="$1" paused="$2"
  if [[ "$running" == "true" && "$paused" == "true" ]]; then
    printf 'paused'
  elif [[ "$running" == "true" && "$paused" != "true" ]]; then
    printf 'running'
  elif [[ "$running" == "false" ]]; then
    printf 'exited'
  else
    printf 'unknown'
  fi
}

run_cmd() {
  if [[ $HAS_TIMEOUT -eq 1 && ${QUIET_CMD_TIMEOUT_S:-0} -gt 0 ]]; then
    timeout --preserve-status "${QUIET_CMD_TIMEOUT_S}" "$@"
  else
    "$@"
  fi
}

with_retries() {
  # $1 description, $2... command
  local desc="$1"
  shift
  local attempt=1
  local start_all
  start_all=$(date +%s)
  while :; do
    local start
    start=$(date +%s)
    if out="$(run_cmd "$@" 2>&1)"; then
      log_debug "_" attempt "${desc}_ok" "out=$(printf %q "$out")" attempt="$attempt" duration_s="$(($(date +%s) - start))"
      echo "$out"
      return 0
    else
      local rc=$?
      log_warn "_" attempt "${desc}_failed" rc="$rc" attempt="$attempt" duration_s="$(($(date +%s) - start))" err="$(printf %q "$out")"
      if [[ $attempt -ge ${QUIET_RETRIES} ]]; then
        log_err "_" attempt "${desc}_giving_up" attempts="$attempt" total_duration_s="$(($(date +%s) - start_all))"
        return $rc
      fi
      attempt=$((attempt + 1))
      sleep "${QUIET_RETRY_DELAY_S}"
    fi
  done
}

show_docker_logs() {
    local name="$1"
    local lines="${2:-$DOCKER_LOG_LINES}"
    if lines_out="$("$DOCKER_BIN" logs --tail "$lines" "$name" 2>&1)"; then
      msg "Docker logs (last $lines lines):"
      # Use safe printf to avoid format string injection
      printf '%s\n' "$lines_out" | sed 's/^/  /'
    else
      msg "Could not retrieve Docker logs for $name"
    fi
}

# -------- NFS/SMB share control --------
# CRITICAL: This function must be called in a specific order:
#   - During PAUSE/STOP: Shares are disabled BEFORE containers are paused/stopped (safe)
#   - During UNPAUSE/START: Shares are enabled BEFORE containers are unpaused/started (REQUIRED)
#
# Containers depend on NFS/SMB shares being available to start properly.
# If shares are not enabled before starting containers, they will fail to initialize.
manage_nfs_smb_shares() {
    local action="$1" shares="${2:-}" containers="${3:-}"
    
    # Skip if no truenas config file exists (feature disabled)
    [[ ! -f /etc/sleep-hours/truenas.conf ]] && return 0
    
    # Source configuration
    # shellcheck source=/dev/null
    . /etc/sleep-hours/truenas.conf
    
    # Read shares from file if not provided
    if [[ -z "$shares" && -f /etc/sleep-hours/truenas-nfs-shares.list ]]; then
      shares=$(grep -v '^#' /etc/sleep-hours/truenas-nfs-shares.list | tr '\n' ' ')
    fi
    
    [[ -z "$shares" ]] && return 0
    
     case "$action" in
     disable)
       # Safe to disable shares before stopping containers
       # Capture output and exit code separately to avoid masking exit status in pipe
       local tmpfile rc
       tmpfile="$(mktemp /tmp/sleep-hours-nfs.XXXXXX)" || fail_early tmpfile "failed to create temp file"
       /usr/local/bin/truenas-shares.sh disable "$shares" >"$tmpfile" 2>&1
       rc=$?
       # Output captured messages
       while IFS= read -r line; do msg "$line"; done < "$tmpfile"
       rm -f "$tmpfile"
       
       if [[ $rc -eq 0 ]]; then
         log_info "_" nfs_smb disable_success "shares=$shares"
         return 0
       else
         log_warn "_" nfs_smb disable_failed "shares=$shares rc=$rc"
         # Don't fail - share control is nice-to-have, not critical
         return 0
       fi
       ;;
     enable)
       # CRITICAL: Must enable shares BEFORE unpausing/starting containers
       # Containers will fail to start if shares are not available
       # Capture output and exit code separately to avoid masking exit status in pipe
       local tmpfile rc
       tmpfile="$(mktemp /tmp/sleep-hours-nfs.XXXXXX)" || fail_early tmpfile "failed to create temp file"
       /usr/local/bin/truenas-shares.sh enable "$shares" "$containers" >"$tmpfile" 2>&1
       rc=$?
       # Output captured messages
       while IFS= read -r line; do msg "$line"; done < "$tmpfile"
       rm -f "$tmpfile"
       
       if [[ $rc -eq 0 ]]; then
         log_info "_" nfs_smb enable_success "shares=$shares"
         return 0
       else
         log_warn "_" nfs_smb enable_failed "shares=$shares rc=$rc"
         # Don't fail - share control is nice-to-have, not critical
         return 0
       fi
       ;;
     esac
    
    return 0
}

kuma_notify() {
     local act="$1" name="$2"
     if out="$(/usr/local/bin/kumactl.py "$act" --container "$name" 2>&1)"; then
       echo "$out"
       log_info "$name" notified kuma_ok action="$act"
       return 0
     else
       local rc=$?
       [[ -n "$out" ]] && echo "$out"
       log_warn "$name" notified kuma_failed action="$act" rc="$rc"
       msg "  ⚠ WARNING: Uptime Kuma notification failed for $name (will continue)"
       return $rc
     fi
}

pushover_notify() {
     # Send Pushover notification for container failures
     # Usage: pushover_notify "title" "message"
     local title="$1" message="$2"
     
     # Check if Pushover credentials are configured
     [[ -z "${PUSHOVER_USER_KEY:-}" || -z "${PUSHOVER_API_TOKEN:-}" ]] && return 0
     
     # URL encode message (simple version - replaces spaces with +)
     local encoded_msg="${message// /+}"
     
     # Send to Pushover API with timeout
     local pushover_url="https://api.pushover.net/1/messages.json"
     local response pushover_timeout="${PUSHOVER_TIMEOUT_S:-5}"
     
     response="$(timeout "$pushover_timeout" curl -sS --max-time "$pushover_timeout" \
       --form-string "token=${PUSHOVER_API_TOKEN}" \
       --form-string "user=${PUSHOVER_USER_KEY}" \
       --form-string "title=${title}" \
       --form-string "message=${message}" \
       --form-string "priority=1" \
       "${pushover_url}" 2>&1)" || true
    
    if echo "$response" | grep -q '"status":1'; then
      log_info "_" pushover notification_sent "title=$title"
    else
      log_warn "_" pushover notification_failed "title=$title" "response=$response"
    fi
}

verify_state() {
   local name="$1" expect="$2"
   local status running paused health
   status="$(inspect_fields "$name")" || true
   [[ -z "$status" ]] && return 1
   read -r running paused health <<<"$status"
   local cur
   cur="$(normalize_state "$running" "$paused")"
   [[ "$cur" == "$expect" ]]
}

validate_containers() {
   local invalid_count=0
    while IFS= read -r raw; do
       name="$(trim_line "$raw")"
       is_comment_or_empty "$name" && continue
       status="$(inspect_fields "$name")" || true
      if [[ -z "$status" ]]; then
         log_warn "$name" validation failed "likely_typo_in_configuration"
         ((invalid_count += 1))
      fi
   done < <(get_containers)
   
   if [[ $invalid_count -gt 0 ]]; then
      msg "⚠ WARNING: Found $invalid_count container(s) that do not exist - check configuration for typos"
      msg ""
   fi
}

total=0 changed=0 skipped=0 failed=0
container_count=0

# Count containers first to display accurate total
while IFS= read -r raw; do
   name="$(trim_line "$raw")"
   is_comment_or_empty "$name" && continue
   ((container_count += 1))
done < <(get_containers)

msg "Processing $container_count container(s)..."
msg ""

# Validate containers before processing
validate_containers
msg ""

handle_one() {
   local name="$1"

    local status running paused health
    status="$(inspect_fields "$name")" || true
    if [[ -z "$status" ]]; then
      log_warn "$name" skipped not_found "hint=check_container_name_for_typos"
      msg "  ⚠ WARNING: $name not found - check configuration for typos"
      ((skipped += 1))
      return 0
    fi
    
    # Only count as total if container actually exists
    ((total += 1))
  read -r running paused health <<<"$status"
  local state_before
  state_before="$(normalize_state "$running" "$paused")"
  local pre="state_before=$state_before health=$health"
  log_debug "$name" inspect before "$pre"

   if [[ "$ACTION" == "pause" ]]; then
      if [[ "$state_before" != "running" ]]; then
        log_info "$name" skipped not_running "$pre"
        msg "  - $name already paused, skipping"
        ((skipped += 1))
        return 0
      fi

      # --- GRACEFUL BUSY CHECK ---
      if is_busy "$name"; then
        log_info "$name" skipped busy_detected "$pre"
        msg "  - $name busy, will retry in 1 minute"
        ((skipped += 1))
        return 0
      fi

      local start_container
      start_container=$(date +%s)
      if with_retries "docker_pause:$name" "$DOCKER_BIN" pause "$name" >/dev/null; then
        if verify_state "$name" "paused"; then
          local status2
          status2="$(inspect_fields "$name")"
          read -r r2 p2 h2 <<<"$status2"
          local duration=$(($(date +%s) - start_container))
           log_info "$name" changed paused "$pre" state_after="$(normalize_state "$r2" "$p2")" health_after="$h2" duration_s="$duration"
           msg "  ✓ $name paused (${duration}s)"
           ((changed += 1))
           kuma_notify pause "$name" || true  # Log errors but don't block
         else
           log_warn "$name" failed verify_pause "$pre"
           msg "  ✗ FAILED: $name pause verification failed"
           show_docker_logs "$name"
           ((failed += 1))
           pushover_notify "Sleep Hours Failure" "Failed to pause container: $name (verification failed)"
         fi
       else
         log_err "$name" failed pause_error "$pre"
         msg "  ✗ FAILED: $name pause failed after $QUIET_RETRIES retries"
         show_docker_logs "$name"
         ((failed += 1))
         pushover_notify "Sleep Hours Failure" "Failed to pause container: $name (after $QUIET_RETRIES retries)"
       fi

    elif [[ "$ACTION" == "unpause" ]]; then
      if [[ "$state_before" != "paused" ]]; then
        log_info "$name" skipped not_paused "$pre"
        msg "  - $name already running, skipping"
        ((skipped += 1))
        return 0
      fi

      local start_container
      start_container=$(date +%s)
      if with_retries "docker_unpause:$name" "$DOCKER_BIN" unpause "$name" >/dev/null; then
        if verify_state "$name" "running"; then
          local status2
          status2="$(inspect_fields "$name")"
          read -r r2 p2 h2 <<<"$status2"
          local duration=$(($(date +%s) - start_container))
          log_info "$name" changed unpaused "$pre" state_after="$(normalize_state "$r2" "$p2")" health_after="$h2" duration_s="$duration"
          msg "  ✓ $name unpaused (${duration}s)"
          ((changed += 1))
          kuma_notify resume "$name" || true  # Log errors but don't block
        else
          log_warn "$name" failed verify_unpause "$pre"
          msg "  ✗ FAILED: $name unpause verification failed"
          show_docker_logs "$name"
          ((failed += 1))
        fi
      else
        log_err "$name" failed unpause_error "$pre"
        msg "  ✗ FAILED: $name unpause failed after $QUIET_RETRIES retries"
        show_docker_logs "$name"
        ((failed += 1))
      fi

    elif [[ "$ACTION" == "stop" ]]; then
      if [[ "$state_before" != "running" ]]; then
        log_info "$name" skipped not_running_stop "$pre"
        msg "  - $name already stopped, skipping"
        ((skipped += 1))
        return 0
      fi

      # --- GRACEFUL BUSY CHECK FOR STOP ---
      if is_busy "$name"; then
        log_info "$name" deferred busy_stop "$pre"
        msg "  ⚠ $name busy, will retry in 1 minute"
        ((skipped += 1))
        return 1  # Signal retry
      fi

      local STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT_S:-30}"
      local start_container
      start_container=$(date +%s)
      if with_retries "docker_stop:$name" "$DOCKER_BIN" stop --time="$STOP_TIMEOUT" "$name" >/dev/null; then
        if verify_state "$name" "exited"; then
          local status2
          status2="$(inspect_fields "$name")"
          read -r r2 p2 h2 <<<"$status2"
          local duration=$(($(date +%s) - start_container))
          log_info "$name" changed stopped "$pre" state_after="$(normalize_state "$r2" "$p2")" health_after="$h2" duration_s="$duration"
          msg "  ✓ $name stopped gracefully (${STOP_TIMEOUT}s timeout, ${duration}s total)"
          ((changed += 1))
          kuma_notify pause "$name" || true  # Log errors but don't block
         else
           log_warn "$name" failed verify_stop "$pre"
           msg "  ✗ FAILED: $name stop verification failed"
           show_docker_logs "$name"
           ((failed += 1))
           pushover_notify "Sleep Hours Failure" "Failed to stop container: $name (verification failed)"
         fi
       else
         log_err "$name" failed stop_error "$pre"
         msg "  ✗ FAILED: $name stop failed after $QUIET_RETRIES retries"
         show_docker_logs "$name"
         ((failed += 1))
         pushover_notify "Sleep Hours Failure" "Failed to stop container: $name (after $QUIET_RETRIES retries)"
       fi

    elif [[ "$ACTION" == "start" ]]; then
      if [[ "$state_before" != "exited" ]]; then
        log_info "$name" skipped not_exited "$pre"
        msg "  - $name already running, skipping"
        ((skipped += 1))
        return 0
      fi

      local start_container
      start_container=$(date +%s)
      if with_retries "docker_start:$name" "$DOCKER_BIN" start "$name" >/dev/null; then
        if verify_state "$name" "running"; then
          local status2
          status2="$(inspect_fields "$name")"
          read -r r2 p2 h2 <<<"$status2"
          local duration=$(($(date +%s) - start_container))
          log_info "$name" changed started "$pre" state_after="$(normalize_state "$r2" "$p2")" health_after="$h2" duration_s="$duration"
          msg "  ✓ $name started (${duration}s)"
          ((changed += 1))
          kuma_notify resume "$name" || true  # Log errors but don't block
        else
          log_warn "$name" failed verify_start "$pre"
          msg "  ✗ FAILED: $name start verification failed"
          show_docker_logs "$name"
          ((failed += 1))
        fi
      else
        log_err "$name" failed start_error "$pre"
        msg "  ✗ FAILED: $name start failed after $QUIET_RETRIES retries"
        show_docker_logs "$name"
        ((failed += 1))
      fi
    fi
}

msg ""
msg "========================================"
msg "PHASE 1: PROCESS CONTAINERS"
msg "========================================"
msg ""

while IFS= read -r raw; do
   name="$(trim_line "$raw")"
   is_comment_or_empty "$name" && continue
   handle_one "$name"
done < <(get_containers)

# For PAUSE/STOP: control shares after pausing/stopping containers
if [[ "$ACTION" == "pause" || "$ACTION" == "stop" ]]; then
  msg ""
  msg "========================================"
  msg "PHASE 2: DISABLE NFS/SMB SHARES"
  msg "========================================"
  msg ""
  manage_nfs_smb_shares disable
  msg ""
fi

# For UNPAUSE/START: control shares then verify containers
if [[ "$ACTION" == "unpause" || "$ACTION" == "start" ]]; then
  msg ""
  msg "========================================"
  msg "PHASE 2: ENABLE NFS/SMB SHARES & VERIFY HEALTH"
  msg "========================================"
  msg ""
  # Build list of containers for health checking
  container_list=""
   while IFS= read -r raw; do
     name="$(trim_line "$raw")"
     is_comment_or_empty "$name" && continue
     [[ -n "$container_list" ]] && container_list="$container_list "
     container_list="$container_list$name"
   done < <(get_containers)
   manage_nfs_smb_shares enable "" "$container_list"
  msg ""
fi

msg ""
msg "Summary: total=$total changed=$changed skipped=$skipped failed=$failed"
if [[ $failed -eq 0 ]]; then
   msg "Success"
else
   msg "FAILED - check logs above"
fi
_log info _ summary done total=$total changed=$changed skipped=$skipped failed=$failed
exit $((failed > 0 ? 1 : 0))
