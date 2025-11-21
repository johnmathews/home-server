#!/usr/bin/env bash
# vim: ft=sh

# TrueNAS NFS/SMB Share Control via REST API
# Disables/enables shares during docker sleep-hours to allow HDD spindown
# Usage: truenas-shares.sh {disable|enable|status} [shares_list] [containers_list]
# Example: truenas-shares.sh disable "tank/paperless tank/media"

# Safer defaults
set -uo pipefail

# Optional bash -x tracing when QUIET_DEBUG=1
export PS4='+ ts=$(date +%FT%T%z) line=${LINENO} cmd='
[[ "${QUIET_DEBUG:-0}" == "1" ]] && set -x

ACTION="${1:-}"
SHARES_LIST="${2:-}"
CONTAINERS_LIST="${3:-}"

# -------- configuration --------
TRUENAS_IP="${TRUENAS_IP:-192.168.2.104}"
TRUENAS_API_URL="${TRUENAS_API_URL:-https://${TRUENAS_IP}/api/v2.0}"
TRUENAS_API_KEY="${TRUENAS_API_KEY:-}"
TIMEOUT_HEALTH_CHECK_S="${TIMEOUT_HEALTH_CHECK_S:-60}"
HEALTH_CHECK_INTERVAL_S="${HEALTH_CHECK_INTERVAL_S:-2}"
API_RETRIES="${API_RETRIES:-3}"
API_RETRY_DELAY_S="${API_RETRY_DELAY_S:-2}"

# -------- logging with levels --------
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
  local level="$1" resource="$2" event="$3" reason="$4"
  shift 4
  if should_log "$level"; then
    printf 'ts=%s level=%s resource=%s action=%s event=%s reason=%s' \
      "$(date +%FT%T%z)" "$level" "${resource:-_}" "${ACTION:-unknown}" "$event" "$reason"
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

# -------- API helpers --------

# Make authenticated curl request to TrueNAS API
api_call() {
   local method="$1" endpoint="$2" data="${3:-}"
   local url="${TRUENAS_API_URL}${endpoint}"
   local attempt=1
   local curl_timeout="${TRUENAS_API_TIMEOUT_S:-10}"

   [[ -z "$TRUENAS_API_KEY" ]] && fail_early api_auth "TRUENAS_API_KEY not set" 1

   while :; do
     local output
     if [[ -z "$data" ]]; then
       output=$(curl -s --max-time "$curl_timeout" -X "$method" "$url" \
         -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
         -H "Content-Type: application/json" \
         2>&1)
     else
       output=$(curl -s --max-time "$curl_timeout" -X "$method" "$url" \
         -H "Authorization: Bearer ${TRUENAS_API_KEY}" \
         -H "Content-Type: application/json" \
         -d "$data" \
         2>&1)
     fi
     local rc=$?

     if [[ $rc -eq 0 ]]; then
       echo "$output"
       return 0
     else
       log_warn "_" api_call "curl_failed" "method=$method endpoint=$endpoint attempt=$attempt rc=$rc"
       if [[ $attempt -ge $API_RETRIES ]]; then
         log_err "_" api_call "failed_after_retries" "method=$method endpoint=$endpoint attempts=$API_RETRIES"
         return $rc
       fi
       attempt=$((attempt + 1))
       sleep "$API_RETRY_DELAY_S"
     fi
   done
}

# Get NFS share ID by path
get_nfs_share_id() {
   local dataset="$1"
   local response rc
   response=$(api_call GET "/nfs/share")
   rc=$?
   
   if [[ $rc -ne 0 ]]; then
     log_err "$dataset" nfs_share_api_failed "could not fetch NFS shares"
     return 1
   fi
   
   # Parse JSON to find share with matching path using jq if available
   local share_id
   if command -v jq >/dev/null 2>&1; then
     share_id=$(echo "$response" | jq -r ".[] | select(.path==\"$dataset\") | .id" 2>/dev/null | head -1)
   else
     # Fallback to grep if jq unavailable
     log_warn "$dataset" jq_unavailable "falling back to grep parsing"
     share_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "")
   fi
   
   if [[ -z "$share_id" ]] || [[ "$share_id" == "null" ]]; then
     log_warn "$dataset" nfs_share_not_found "share ID not found in response"
     return 1
   fi
   echo "$share_id"
   return 0
}

# Get SMB share ID by path
get_smb_share_id() {
   local dataset="$1"
   local response rc
   response=$(api_call GET "/smb/share")
   rc=$?
   
   if [[ $rc -ne 0 ]]; then
     log_err "$dataset" smb_share_api_failed "could not fetch SMB shares"
     return 1
   fi
   
   # Parse JSON to find share with matching path using jq if available
   local share_id
   if command -v jq >/dev/null 2>&1; then
     share_id=$(echo "$response" | jq -r ".[] | select(.path==\"$dataset\") | .id" 2>/dev/null | head -1)
   else
     # Fallback to grep if jq unavailable
     log_warn "$dataset" jq_unavailable "falling back to grep parsing"
     share_id=$(echo "$response" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || echo "")
   fi
   
   if [[ -z "$share_id" ]] || [[ "$share_id" == "null" ]]; then
     log_warn "$dataset" smb_share_not_found "share ID not found in response"
     return 1
   fi
   echo "$share_id"
   return 0
}

# Disable NFS share by ID
disable_nfs_share() {
  local share_id="$1" dataset="$2"
  local data='{"enabled":false}'
  
  api_call PATCH "/nfs/share/$share_id" "$data" >/dev/null 2>&1 || {
    log_warn "$dataset" nfs_disable "api_failed" "share_id=$share_id"
    return 1
  }
  
  log_info "$dataset" nfs_disable "success" "share_id=$share_id"
  return 0
}

# Enable NFS share by ID
enable_nfs_share() {
  local share_id="$1" dataset="$2"
  local data='{"enabled":true}'
  
  api_call PATCH "/nfs/share/$share_id" "$data" >/dev/null 2>&1 || {
    log_warn "$dataset" nfs_enable "api_failed" "share_id=$share_id"
    return 1
  }
  
  log_info "$dataset" nfs_enable "success" "share_id=$share_id"
  return 0
}

# Disable SMB share by ID
disable_smb_share() {
  local share_id="$1" dataset="$2"
  local data='{"enabled":false}'
  
  api_call PATCH "/smb/share/$share_id" "$data" >/dev/null 2>&1 || {
    log_warn "$dataset" smb_disable "api_failed" "share_id=$share_id"
    return 1
  }
  
  log_info "$dataset" smb_disable "success" "share_id=$share_id"
  return 0
}

# Enable SMB share by ID
enable_smb_share() {
  local share_id="$1" dataset="$2"
  local data='{"enabled":true}'
  
  api_call PATCH "/smb/share/$share_id" "$data" >/dev/null 2>&1 || {
    log_warn "$dataset" smb_enable "api_failed" "share_id=$share_id"
    return 1
  }
  
  log_info "$dataset" smb_enable "success" "share_id=$share_id"
  return 0
}

# -------- health check --------

# Wait for container to be healthy or running
wait_for_container_health() {
  local container="$1" timeout="${2:-$TIMEOUT_HEALTH_CHECK_S}"
  local elapsed=0
  local start_time
  start_time=$(date +%s)
  
  msg "  - $container: checking health..."

  while [[ $elapsed -lt $timeout ]]; do
    local state
    state=$(docker inspect -f '{{.State.Running}} {{.State.Health.Status}}' "$container" 2>/dev/null || echo "false none")
    
    read -r running health <<<"$state"
    
    # Accept: running=true + (health=healthy OR health=none)
    if [[ "$running" == "true" && ("$health" == "healthy" || "$health" == "none") ]]; then
      local duration=$(($(date +%s) - start_time))
      log_info "$container" health "ok" "duration_s=$duration health=$health"
      # Clear success message distinguishing healthy vs no-health-check
      if [[ "$health" == "healthy" ]]; then
        msg "    ✓ $container is healthy (${duration}s)"
      else
        msg "    ✓ $container is running (no health check, ${duration}s)"
      fi
      return 0
    fi
    
    sleep "$HEALTH_CHECK_INTERVAL_S"
    elapsed=$(($(date +%s) - start_time))
  done
  
  # Timeout but don't fail (container may still be starting)
  log_warn "$container" health "timeout" "waited=${timeout}s"
  msg "    ⚠ $container: health check timeout after ${timeout}s (may still be starting)"
  return 0
}

# -------- main actions --------

disable_shares() {
  local total=0 changed=0 skipped=0 failed=0
  
  if [[ -z "$SHARES_LIST" ]]; then
    msg "No shares to disable"
    return 0
  fi
  
  msg "=========================================="
  msg "Disabling NFS/SMB Shares"
  msg "=========================================="
  msg "Shares to disable: $SHARES_LIST"
  msg ""
  
  for dataset in $SHARES_LIST; do
    ((total += 1))
    
    # Try NFS
    local nfs_id
    nfs_id=$(get_nfs_share_id "$dataset" 2>/dev/null)
    if [[ -n "$nfs_id" ]]; then
      if disable_nfs_share "$nfs_id" "$dataset"; then
        msg "  ✓ $dataset NFS disabled"
        ((changed += 1))
      else
        msg "  ✗ FAILED: $dataset NFS disable failed"
        ((failed += 1))
      fi
    else
      log_warn "$dataset" nfs_not_found "skipped" ""
      msg "  - $dataset NFS not found, skipping"
      ((skipped += 1))
    fi
    
    # Try SMB
    local smb_id
    smb_id=$(get_smb_share_id "$dataset" 2>/dev/null)
    if [[ -n "$smb_id" ]]; then
      if disable_smb_share "$smb_id" "$dataset"; then
        msg "  ✓ $dataset SMB disabled"
        ((changed += 1))
      else
        msg "  ✗ FAILED: $dataset SMB disable failed"
        ((failed += 1))
      fi
    else
      log_warn "$dataset" smb_not_found "skipped" ""
      msg "  - $dataset SMB not found, skipping"
      ((skipped += 1))
    fi
  done
  
  msg ""
  msg "=========================================="
  msg "Share Disable Summary"
  msg "=========================================="
  msg "Total operations: $((total*2))"
  msg "Successfully changed: $changed"
  msg "Skipped: $skipped"
  msg "Failed: $failed"
  
  if [[ $failed -eq 0 ]]; then
    msg "Status: Success"
    _log info _ summary done total=$((total*2)) changed=$changed skipped=$skipped failed=$failed
    return 0
  else
    msg "Status: PARTIAL - some shares failed to disable"
    _log warn _ summary done total=$((total*2)) changed=$changed skipped=$skipped failed=$failed
    return 1
  fi
}

enable_shares() {
  local total=0 changed=0 skipped=0 failed=0
  
  if [[ -z "$SHARES_LIST" ]]; then
    msg "No shares to enable"
    return 0
  fi
  
  msg "=========================================="
  msg "Enabling NFS/SMB Shares"
  msg "=========================================="
  msg "Shares to enable: $SHARES_LIST"
  msg ""
  
  for dataset in $SHARES_LIST; do
    ((total += 1))
    
    # Try NFS
    local nfs_id
    nfs_id=$(get_nfs_share_id "$dataset" 2>/dev/null)
    if [[ -n "$nfs_id" ]]; then
      if enable_nfs_share "$nfs_id" "$dataset"; then
        msg "  ✓ $dataset NFS enabled"
        ((changed += 1))
      else
        msg "  ✗ FAILED: $dataset NFS enable failed"
        ((failed += 1))
      fi
    else
      log_warn "$dataset" nfs_not_found "skipped" ""
      msg "  - $dataset NFS not found, skipping"
      ((skipped += 1))
    fi
    
    # Try SMB
    local smb_id
    smb_id=$(get_smb_share_id "$dataset" 2>/dev/null)
    if [[ -n "$smb_id" ]]; then
      if enable_smb_share "$smb_id" "$dataset"; then
        msg "  ✓ $dataset SMB enabled"
        ((changed += 1))
      else
        msg "  ✗ FAILED: $dataset SMB enable failed"
        ((failed += 1))
      fi
    else
      log_warn "$dataset" smb_not_found "skipped" ""
      msg "  - $dataset SMB not found, skipping"
      ((skipped += 1))
    fi
  done
  
  msg ""
  msg "=========================================="
  msg "Share Enable Summary"
  msg "=========================================="
  msg "Total operations: $((total*2))"
  msg "Successfully changed: $changed"
  msg "Skipped: $skipped"
  msg "Failed: $failed"
  
  # Health check containers if provided
  if [[ -n "$CONTAINERS_LIST" ]]; then
    msg ""
    msg "=========================================="
    msg "Verifying Container Health"
    msg "=========================================="
    # Count containers for display
    local container_count=0
    for c in $CONTAINERS_LIST; do ((container_count += 1)); done
    msg "Checking $container_count container(s)..."
    msg ""
    
    for container in $CONTAINERS_LIST; do
      wait_for_container_health "$container"
    done
    
    msg ""
    msg "=========================================="
    msg "Health Check Complete"
    msg "=========================================="
  fi
  
  msg ""
  
  if [[ $failed -eq 0 ]]; then
    msg "Status: Success"
    _log info _ summary done total=$((total*2)) changed=$changed skipped=$skipped failed=$failed
    return 0
  else
    msg "Status: PARTIAL - some shares failed to enable"
    _log warn _ summary done total=$((total*2)) changed=$changed skipped=$skipped failed=$failed
    return 1
  fi
}

status_shares() {
  if [[ -z "$SHARES_LIST" ]]; then
    msg "No shares configured"
    return 0
  fi
  
  msg "Checking share status..."
  msg ""
  
  for dataset in $SHARES_LIST; do
    local nfs_id smb_id
    nfs_id=$(get_nfs_share_id "$dataset" 2>/dev/null)
    smb_id=$(get_smb_share_id "$dataset" 2>/dev/null)
    
    local nfs_status="unknown" smb_status="unknown"
    
    [[ -n "$nfs_id" ]] && nfs_status="found" || nfs_status="not_found"
    [[ -n "$smb_id" ]] && smb_status="found" || smb_status="not_found"
    
    msg "  $dataset: NFS=$nfs_status SMB=$smb_status"
  done
  
  msg ""
  return 0
}

# -------- validate action --------
case "$ACTION" in
disable | enable | status) ;;
*) fail_early usage "usage=$0 {disable|enable|status} [shares] [containers]" 2 ;;
esac

# Execute action
msg "Starting $ACTION action"

case "$ACTION" in
disable)
  disable_shares
  exit $?
  ;;
unpause)
  enable_shares
  exit $?
  ;;
status)
  status_shares
  exit $?
  ;;
esac
