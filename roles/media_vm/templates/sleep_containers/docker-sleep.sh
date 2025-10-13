#!/usr/bin/env bash
# vim: ft=sh

# Safer defaults; handle errors explicitly so we can keep summarizing
set -uo pipefail

# bash -x when QUIET_DEBUG=1 (with pretty PS4)
export PS4='+ ts=$(date +%FT%T%z) line=${LINENO} cmd='
[[ "${QUIET_DEBUG:-0}" == "1" ]] && set -x

ACTION="${1:-}"
LIST="${QUIET_LIST:-/etc/sleep-hours/containers.list}"

# this log function prints 1 row of logs only.
log() {
  # Uniform logfmt (no quotes around values)
  # shift 4 removes the first 4 args from the $@ variable, so that $@ doesnt print $1, $2, $3,$4
  local level="$1" container="$2" event="$3" reason="$4"; shift 4
  # no new-line char after this first part
  # the string placeholders (%s) order (in the first half of the row) matches the order to the variables (in double quotes) in the second half of the row
  printf 'ts=%s level=%s container=%s action=%s event=%s reason=%s' "$(date +%FT%T%z)" "$level" "${container:-_}" "${ACTION:-unknown}" "$event" "$reason"
  for kv in "$@"; do printf ' %s' "$kv"; done
  # the only new-line char
  printf '\n'
}

fail_early() { log error "_" "failed" "$1" "$2"; exit "${3:-1}"; }

# Validate ACTION
case "$ACTION" in
  pause|unpause) ;;
  *) fail_early usage "usage=$0 {pause|unpause}" 2 ;;
esac

# docker binary
DOCKER_BIN="$(command -v docker || true)"
[[ -x "${DOCKER_BIN:-}" ]] || fail_early docker_not_found "PATH=$PATH" 1

# Resolve container source
get_containers() {
  if [[ "${LIST}" == "-" ]]; then
    "$DOCKER_BIN" ps --filter "label=quiet-hours=true" --format '{{.Names}}'
  else
    [[ -r "$LIST" ]] || fail_early list_missing "path=$LIST" 1
    cat -- "$LIST"
  fi
}

# Trim helpers (handles CRLF + outer whitespace)
trim_line() {
  local s="${1%$'\r'}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Return "running paused" booleans from docker inspect; echo nothing on failure
inspect_running_paused() {
  local name="$1"
  "$DOCKER_BIN" inspect -f '{{.State.Running}} {{.State.Paused}}' "$name" 2>/dev/null || true
}

# Normalize two booleans into one of: running|paused|exited|unknown
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

kuma_notify() {
  # $1: pause|resume  $2: container
  # We let kumactl print its own logfmt line; we add one line to correlate outcome.
  local act="$1" name="$2"
  if out="$(/usr/local/bin/kumactl.py "$act" --container "$name" 2>&1)"; then
    # kumactl itself prints a logfmt line; echo it as-is so it shows in journal
    echo "$out"
    log info "$name" notified kuma_ok action="$act"
  else
    local rc=$?
    # print whatever kumactl said; then summarize
    [[ -n "$out" ]] && echo "$out"
    log warn "$name" notified kuma_failed action="$act" rc="$rc"
  fi
}

total=0 changed=0 skipped=0 failed=0

handle_one() {
  local name="$1"
  (( total += 1 ))

  local status running paused
  status="$(inspect_running_paused "$name")" || true
  if [[ -z "$status" ]]; then
    log warn "$name" skipped not_found; (( skipped += 1 )); return 0
  fi
  read -r running paused <<<"$status"

  local state_before
  state_before="$(normalize_state "$running" "$paused")"
  local pre="state_before=$state_before"

  if [[ "$ACTION" == "pause" ]]; then
    if [[ "$state_before" != "running" ]]; then
      log info "$name" skipped not_running "$pre"; (( skipped += 1 )); return 0
    fi

    local out rc
    # pause the docker container
    if out="$("$DOCKER_BIN" pause "$name" 2>&1)"; then
      status="$(inspect_running_paused "$name")"
      if [[ -n "$status" ]]; then
        read -r running paused <<<"$status"
        log info "$name" changed paused "$pre" state_after="$(normalize_state "$running" "$paused")"
      else
        log info "$name" changed paused "$pre"
      fi
      (( changed += 1 ))
      kuma_notify pause "$name"
    else
      rc=$?; log error "$name" failed pause_error "$pre" rc="$rc" err="$(printf %q "$out")"
      (( failed += 1 ))
    fi

  else # unpause
    if [[ "$state_before" != "paused" ]]; then
      log info "$name" skipped not_paused "$pre"; (( skipped += 1 )); return 0
    fi

    local out rc
    # unpause the docker container
    if out="$("$DOCKER_BIN" unpause "$name" 2>&1)"; then
      status="$(inspect_running_paused "$name")"
      if [[ -n "$status" ]]; then
        read -r running paused <<<"$status"
        log info "$name" changed unpaused "$pre" state_after="$(normalize_state "$running" "$paused")"
      else
        log info "$name" changed unpaused "$pre"
      fi
      (( changed += 1 ))
      kuma_notify resume "$name"
    else
      rc=$?; log error "$name" failed unpause_error "$pre" rc="$rc" err="$(printf %q "$out")"
      (( failed += 1 ))
    fi
  fi
}

while IFS= read -r raw; do
  name="$(trim_line "$raw")"
  [[ -z "$name" || "$name" =~ ^# ]] && continue
  handle_one "$name"
done < <(get_containers)

log info _ summary done total=$total changed=$changed skipped=$skipped failed=$failed
exit $(( failed > 0 ? 1 : 0 ))
