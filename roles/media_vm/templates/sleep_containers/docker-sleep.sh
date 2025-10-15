#!/usr/bin/env bash
# vim: ft=sh

set -uo pipefail

# Optional bash -x tracing when QUIET_DEBUG=1
export PS4='+ ts=$(date +%FT%T%z) line=${LINENO} cmd='
[[ "${QUIET_DEBUG:-0}" == "1" ]] && set -x

ACTION="${1:-}"
LIST="${QUIET_LIST:-/etc/sleep-hours/containers.list}"

# -------- logging with levels --------
# QUIET_LOG_LEVEL: debug|info|warn|error (default info)
_log_level="${QUIET_LOG_LEVEL:-info}"
case "${_log_level}" in
  debug) LOG_THRESH=10 ;;
  info)  LOG_THRESH=20 ;;
  warn)  LOG_THRESH=30 ;;
  error) LOG_THRESH=40 ;;
  *)     LOG_THRESH=20 ;;
esac
level_num() {
  case "$1" in
    debug) echo 10 ;;
    info)  echo 20 ;;
    warn)  echo 30 ;;
    error) echo 40 ;;
    *)     echo 20 ;;
  esac
}
should_log() {
  local want; want=$(level_num "$1")
  [[ $want -ge $LOG_THRESH ]]
}

# one-line logfmt
_log() {
  local level="$1" container="$2" event="$3" reason="$4"; shift 4
  if should_log "$level"; then
    printf 'ts=%s level=%s container=%s action=%s event=%s reason=%s' \
      "$(date +%FT%T%z)" "$level" "${container:-_}" "${ACTION:-unknown}" "$event" "$reason"
    for kv in "$@"; do printf ' %s' "$kv"; done
    printf '\n'
  fi
}
log_debug(){ _log debug "$@"; }
log_info(){  _log info  "$@"; }
log_warn(){  _log warn  "$@"; }
log_err(){   _log error "$@"; }

fail_early() { _log error "_" "failed" "$1" "$2"; exit "${3:-1}"; }

# -------- config for retries/timeouts --------
QUIET_RETRIES="${QUIET_RETRIES:-3}"
QUIET_RETRY_DELAY_S="${QUIET_RETRY_DELAY_S:-2}"
QUIET_CMD_TIMEOUT_S="${QUIET_CMD_TIMEOUT_S:-15}"

HAS_TIMEOUT=0
if command -v timeout >/dev/null 2>&1; then
  HAS_TIMEOUT=1
fi

# -------- validate action --------
case "$ACTION" in
  pause|unpause) ;;
  *) fail_early usage "usage=$0 {pause|unpause}" 2 ;;
esac

# -------- docker binary --------
DOCKER_BIN="$(command -v docker || true)"
[[ -x "${DOCKER_BIN:-}" ]] || fail_early docker_not_found "PATH=$PATH" 1

# -------- container source --------
get_containers() {
  if [[ "${LIST}" == "-" ]]; then
    "$DOCKER_BIN" ps --filter "label=quiet-hours=true" --format '{{.Names}}'
  else
    [[ -r "$LIST" ]] || fail_early list_missing "path=$LIST" 1
    cat -- "$LIST"
  fi
}

# -------- helpers --------
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
  # optional timeout wrapper
  if [[ $HAS_TIMEOUT -eq 1 && ${QUIET_CMD_TIMEOUT_S:-0} -gt 0 ]]; then
    timeout --preserve-status "${QUIET_CMD_TIMEOUT_S}" "$@"
  else
    "$@"
  fi
}

with_retries() {
  # $1 description, $2... command
  local desc="$1"; shift
  local attempt=1
  local start_all end_all
  start_all=$(date +%s)
  while :; do
    local start end
    start=$(date +%s)
    if out="$(run_cmd "$@" 2>&1)"; then
      end=$(date +%s)
      local dur=$(( end - start ))
      log_debug "_" attempt "${desc}_ok" "out=$(printf %q "$out")" attempt="$attempt" duration_s="$dur"
      echo "$out"
      return 0
    else
      local rc=$?
      end=$(date +%s)
      local dur=$(( end - start ))
      log_warn "_" attempt "${desc}_failed" rc="$rc" attempt="$attempt" duration_s="$dur" err="$(printf %q "$out")"
      if [[ $attempt -ge ${QUIET_RETRIES} ]]; then
        local end_all; end_all=$(date +%s)
        log_err "_" attempt "${desc}_giving_up" attempts="$attempt" total_duration_s="$(( end_all - start_all ))"
        return $rc
      fi
      attempt=$(( attempt + 1 ))
      sleep "${QUIET_RETRY_DELAY_S}"
    fi
  done
}

kuma_notify() {
  # $1: pause|resume  $2: container
  local act="$1" name="$2"
  if out="$(/usr/local/bin/kumactl.py "$act" --container "$name" 2>&1)"; then
    echo "$out"
    log_info "$name" notified kuma_ok action="$act"
  else
    local rc=$?
    [[ -n "$out" ]] && echo "$out"
    log_warn "$name" notified kuma_failed action="$act" rc="$rc"
  fi
}

verify_state() {
  # $1 container, $2 expected normalized state
  local name="$1" expect="$2"
  local status running paused health
  status="$(inspect_fields "$name")" || true
  [[ -z "$status" ]] && return 1
  read -r running paused health <<<"$status"
  local cur; cur="$(normalize_state "$running" "$paused")"
  [[ "$cur" == "$expect" ]]
}

total=0 changed=0 skipped=0 failed=0

handle_one() {
  local name="$1"
  (( total += 1 ))

  local status running paused health
  status="$(inspect_fields "$name")" || true
  if [[ -z "$status" ]]; then
    log_warn "$name" skipped not_found
    (( skipped += 1 )); return 0
  fi
  read -r running paused health <<<"$status"

  local state_before; state_before="$(normalize_state "$running" "$paused")"
  local pre="state_before=$state_before health=$health"

  log_debug "$name" inspect before "$pre"

  if [[ "$ACTION" == "pause" ]]; then
    if [[ "$state_before" != "running" ]]; then
      log_info "$name" skipped not_running "$pre"
      (( skipped += 1 )); return 0
    fi

    local start_container; start_container=$(date +%s)
    if with_retries "docker_pause:$name" "$DOCKER_BIN" pause "$name" >/dev/null; then
      # verify
      if verify_state "$name" "paused"; then
        local status2; status2="$(inspect_fields "$name")"; read -r r2 p2 h2 <<<"$status2"
        log_info "$name" changed paused "$pre" state_after="$(normalize_state "$r2" "$p2")" health_after="$h2" duration_s="$(( $(date +%s) - start_container ))"
        (( changed += 1 ))
        kuma_notify pause "$name"
      else
        log_warn "$name" failed verify_pause "$pre"
        (( failed += 1 ))
      fi
    else
      log_err "$name" failed pause_error "$pre"
      (( failed += 1 ))
    fi

  else # unpause
    if [[ "$state_before" != "paused" ]]; then
      log_info "$name" skipped not_paused "$pre"
      (( skipped += 1 )); return 0
    fi

    local start_container; start_container=$(date +%s)
    if with_retries "docker_unpause:$name" "$DOCKER_BIN" unpause "$name" >/dev/null; then
      if verify_state "$name" "running"; then
        local status2; status2="$(inspect_fields "$name")"; read -r r2 p2 h2 <<<"$status2"
        log_info "$name" changed unpaused "$pre" state_after="$(normalize_state "$r2" "$p2")" health_after="$h2" duration_s="$(( $(date +%s) - start_container ))"
        (( changed += 1 ))
        kuma_notify resume "$name"
      else
        log_warn "$name" failed verify_unpause "$pre"
        (( failed += 1 ))
      fi
    else
      log_err "$name" failed unpause_error "$pre"
      (( failed += 1 ))
    fi
  fi
}

while IFS= read -r raw; do
  name="$(trim_line "$raw")"
  [[ -z "$name" || "$name" =~ ^# ]] && continue
  handle_one "$name"
done < <(get_containers)

_log info _ summary done total=$total changed=$changed skipped=$skipped failed=$failed
exit $(( failed > 0 ? 1 : 0 ))
