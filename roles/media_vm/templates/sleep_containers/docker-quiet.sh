#!/usr/bin/env bash
set -euo pipefail

# Enable bash tracing when QUIET_DEBUG=1 (handy under systemd)
export PS4='+ ts=$(date +%FT%T%z) line=${LINENO} cmd='
[[ "${QUIET_DEBUG:-0}" == "1" ]] && set -x

trap 'rc=$?; echo "ts=$(date +%FT%T%z) level=error line=${LINENO} rc=${rc} msg=\"script error\""; exit $rc' ERR

ACTION="${1:-}"
LIST="/etc/quiet-hours/containers.list"

log() {
  local level="$1" name="$2" msg="$3"; shift 3
  printf 'ts=%s level=%s action=%s container=%s msg="%s' \
    "$(date +%FT%T%z)" "$level" "${ACTION:-unknown}" "${name:-_}" "$msg"
  for kv in "$@"; do printf ' %s' "$kv"; done
  printf '"\n'
}

fail() { log error "_" "$1" "$2"; exit "${3:-1}"; }

# Validate args
[[ "${ACTION}" == "pause" || "${ACTION}" == "unpause" ]] \
  || fail "usage" "usage=\"$0 {pause|unpause}\"" 2

# Validate list
[[ -r "$LIST" ]] || fail "container list not found" "path=$LIST" 1

# Find docker binary
DOCKER_BIN="$(command -v docker || true)"
[[ -x "${DOCKER_BIN:-}" ]] || fail "docker binary not found in PATH" "PATH=$PATH" 1

total=0 changed=0 skipped=0 failed=0

# Normalize CRLF and trim lines while reading
while IFS= read -r raw; do
  # strip CR and trim
  name="${raw%$'\r'}"
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
  [[ -z "$name" ]] && continue

  (( total += 1 ))

  if ! status="$("$DOCKER_BIN" inspect -f '{{.State.Status}} {{.State.Paused}}' "$name" 2>/dev/null)"; then
    log warn "$name" "container not found"; ((skipped += 1)); continue
  fi
  read -r state paused <<<"$status"

  if [[ "$ACTION" == "pause" ]]; then
    if [[ "$state" != "running" ]]; then
      log info "$name" "skip: not running" state="$state" paused="$paused"; ((skipped += 1)); continue
    fi
    if [[ "$paused" == "true" ]]; then
      log info "$name" "skip: already paused"; ((skipped += 1)); continue
    fi
    if out="$("$DOCKER_BIN" pause "$name" 2>&1)"; then
      log info "$name" "paused successfully" state_before="$state" paused_before="$paused"; ((changed += 1))
    else
      rc=$?; out_one="${out//$'\n'/; }"
      log error "$name" "pause failed" rc="$rc" err="$out_one"; ((failed += 1))
    fi
  else
    if [[ "$paused" != "true" ]]; then
      log info "$name" "skip: not paused" state="$state" paused="$paused"; ((skipped += 1)); continue
    fi
    if out="$("$DOCKER_BIN" unpause "$name" 2>&1)"; then
      log info "$name" "unpaused successfully" state_before="$state" paused_before="$paused"; ((changed += 1))
    else
      rc=$?; out_one="${out//$'\n'/; }"
      log error "$name" "unpause failed" rc="$rc" err="$out_one"; ((failed += 1))
    fi
  fi
done < "$LIST"

echo "ts=$(date +%FT%T%z) level=info action=$ACTION msg=\"summary\" total=$total changed=$changed skipped=$skipped failed=$failed"
exit $(( failed > 0 ? 1 : 0 ))
