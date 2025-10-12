#!/usr/bin/env bash
# vim: ft=sh

# Safer defaults; handle errors explicitly so we can keep summarizing
set -uo pipefail

# bash -x when QUIET_DEBUG=1 (with pretty PS4)
export PS4='+ ts=$(date +%FT%T%z) line=${LINENO} cmd='
[[ "${QUIET_DEBUG:-0}" == "1" ]] && set -x

ACTION="${1:-}"
LIST="${QUIET_LIST:-/etc/quiet-hours/containers.list}"

log() {
  # logfmt: ts=... level=... action=... container=... event=... reason=... k=v ...
  local level="$1" container="$2" event="$3" reason="$4"; shift 4
  printf 'ts=%s level=%s action=%s container=%s event=%s reason="%s' \
    "$(date +%FT%T%z)" "$level" "${ACTION:-unknown}" "${container:-_}" "$event" "$reason"
  # extra k=v pairs (already key=value)
  for kv in "$@"; do printf ' %s' "$kv"; done
  printf '"\n'
}

fail_early() { log error "_" "failed" "$1" "$2"; exit "${3:-1}"; }

# Validate ACTION
case "$ACTION" in
  pause|unpause) ;;
  *) fail_early "usage" "usage=\"$0 {pause|unpause}\"" 2 ;;
esac

# docker binary
DOCKER_BIN="$(command -v docker || true)"
[[ -x "${DOCKER_BIN:-}" ]] || fail_early "docker_not_found" "PATH=$PATH" 1

# Resolve container source
get_containers() {
  # If LIST is "-", use label discovery; else read the file
  if [[ "${LIST}" == "-" ]]; then
    "$DOCKER_BIN" ps --filter "label=quiet-hours=true" --format '{{.Names}}'
  else
    [[ -r "$LIST" ]] || fail_early "list_missing" "path=$LIST" 1
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

total=0 changed=0 skipped=0 failed=0

handle_one() {
  local name="$1"
  (( total += 1 ))

  # status: Running(bool) Paused(bool); avoid free-text Status parsing
  local status
  if ! status="$("$DOCKER_BIN" inspect -f '{{.State.Running}} {{.State.Paused}}' "$name" 2>/dev/null)"; then
    log warn "$name" "skipped" "not_found"; (( skipped += 1 )); return 0
  fi

  local running paused
  read -r running paused <<<"$status"

  # Common pre-state in every log line so you don't repeat different keys
  local pre="running_before=$running paused_before=$paused"

  if [[ "$ACTION" == "pause" ]]; then
    if [[ "$running" != "true" ]]; then
      log info "$name" "skipped" "not_running" "$pre"; (( skipped += 1 )); return 0
    fi
    if [[ "$paused" == "true" ]]; then
      log info "$name" "skipped" "already_paused" "$pre"; (( skipped += 1 )); return 0
    fi

    local out rc
    if out="$("$DOCKER_BIN" pause "$name" 2>&1)"; then
      log info "$name" "changed" "paused" "$pre" out="$(printf %q "$out")"
      (( changed += 1 ))
    else
      rc=$?; log error "$name" "failed" "pause_error" "$pre" rc="$rc" err="$(printf %q "$out")"
      (( failed += 1 ))
    fi

  else # unpause
    if [[ "$paused" != "true" ]]; then
      log info "$name" "skipped" "not_paused" "$pre"; (( skipped += 1 )); return 0
    fi

    local out rc
    if out="$("$DOCKER_BIN" unpause "$name" 2>&1)"; then
      log info "$name" "changed" "unpaused" "$pre" out="$(printf %q "$out")"
      (( changed += 1 ))
    else
      rc=$?; log error "$name" "failed" "unpause_error" "$pre" rc="$rc" err="$(printf %q "$out")"
      (( failed += 1 ))
    fi
  fi
}

# Read containers (file or label discovery)
while IFS= read -r raw; do
  name="$(trim_line "$raw")"
  [[ -z "$name" || "$name" =~ ^# ]] && continue
  handle_one "$name"
done < <(get_containers)

log info "_" "summary" "done" total="$total" changed="$changed" skipped="$skipped" failed="$failed"
exit $(( failed > 0 ? 1 : 0 ))
