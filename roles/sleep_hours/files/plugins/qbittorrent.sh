# qBittorrent "busy" check with automatic WebUI login.
# Busy if active download/upload speed > 0 via /api/v2/transfer/info
#
# Requires (set in systemd Environment= or an EnvironmentFile=):
#   QBIT_URL      (e.g., http://127.0.0.1:8080)
#   QBIT_USER
#   QBIT_PASS
#
# Optional:
#   QBIT_COOKIE_DIR   (default: /run/sleep-hours)
#   QBIT_COOKIE_FILE  (default: $QBIT_COOKIE_DIR/qbit.cookie)
#   CURL_TIMEOUT_S    (from common.sh; default 5)
#   CURL_INSECURE=1   (to allow -k)
#
# Returns:
#   check_busy <container>
#     0 => BUSY, 1 => IDLE
#   If API not configured or unusable, falls back to check_busy_generic.

# Validate qBittorrent environment and tools
_validate_qbit_env() {
   # Ensure curl is available
   CURL_BIN="${CURL_BIN:-$(command -v curl)}"
   if [[ -z "$CURL_BIN" ]] || ! command -v "$CURL_BIN" >/dev/null 2>&1; then
      return 2  # curl not available
   fi
   
   # Check required variables
   [[ -z "${QBIT_URL:-}" ]] && return 2
   [[ -z "${QBIT_USER:-}" ]] && return 2
   [[ -z "${QBIT_PASS:-}" ]] && return 2
   
   return 0
}

_qbit_cookie_file() {
   local dir="${QBIT_COOKIE_DIR:-/run/sleep-hours}"
   local file="${QBIT_COOKIE_FILE:-$dir/qbit.cookie}"
   if ! mkdir -p "$dir" 2>/dev/null; then
      # Log mkdir failure but continue (may already exist)
      :
   fi
   echo "$file"
}

_qbit_login() {
   # Validate environment first
   if ! _validate_qbit_env; then
      return 2
   fi
   
   local cookie; cookie="$(_qbit_cookie_file)"

   # Do login (expects body "Ok." or "Ok" exactly)
   if [[ "${CURL_INSECURE:-0}" = "1" ]]; then
     out="$("$CURL_BIN" -sS --max-time "${CURL_TIMEOUT_S:-5}" -k \
       -c "$cookie" -b "$cookie" \
       -d "username=${QBIT_USER}&password=${QBIT_PASS}" \
       "${QBIT_URL%/}/api/v2/auth/login" 2>&1)" || return 2
   else
     out="$("$CURL_BIN" -sS --max-time "${CURL_TIMEOUT_S:-5}" \
       -c "$cookie" -b "$cookie" \
       -d "username=${QBIT_USER}&password=${QBIT_PASS}" \
       "${QBIT_URL%/}/api/v2/auth/login" 2>&1)" || return 2
   fi

   # qBittorrent returns "Ok." or "Ok" on success - validate more strictly
   if echo "$out" | grep -qE '^Ok\.?$'; then
      return 0
   else
      return 2
   fi
}

_qbit_get_transfer_info() {
  # Ensures we have a valid cookie; tries once, relogins on 401/403, tries again
  [[ -z "${QBIT_URL:-}" ]] && return 2
  local cookie; cookie="$(_qbit_cookie_file)"

  # function to GET with cookie and capture body+status
  _do_get() {
    if [[ "${CURL_INSECURE:-0}" = "1" ]]; then
      "$CURL_BIN" -sS -m "${CURL_TIMEOUT_S:-5}" -k \
        -b "$cookie" -c "$cookie" \
        -w ' HTTP_STATUS:%{http_code}' \
        "${QBIT_URL%/}/api/v2/transfer/info"
    else
      "$CURL_BIN" -sS -m "${CURL_TIMEOUT_S:-5}" \
        -b "$cookie" -c "$cookie" \
        -w ' HTTP_STATUS:%{http_code}' \
        "${QBIT_URL%/}/api/v2/transfer/info"
    fi
  }

  # First attempt
  local resp status body
  resp="$(_do_get)" || resp=""
  status="${resp##* HTTP_STATUS:}"
  body="${resp% HTTP_STATUS:*}"

  # If unauthorized/forbidden, re-login and retry once
  if [[ "$status" != "200" ]]; then
    case "$status" in
      401|403|"") _qbit_login || return 2
                  resp="$(_do_get)" || resp=""
                  status="${resp##* HTTP_STATUS:}"
                  body="${resp% HTTP_STATUS:*}"
                  ;;
    esac
  fi

  [[ "$status" = "200" && -n "$body" ]] || return 2
  printf '%s' "$body"
  return 0
}

_qbit_api_busy() {
  # Missing creds? signal 2 so caller can fall back
  [[ -z "${QBIT_URL:-}" || -z "${QBIT_USER:-}" || -z "${QBIT_PASS:-}" ]] && return 2

  local js
  js="$(_qbit_get_transfer_info)" || return 2

  # crude parse without jq: speed > 0 means busy
  # dl_info_speed and up_info_speed are integers (bytes/sec)
  echo "$js" | grep -Eq '"dl_info_speed":[1-9]' && return 0
  echo "$js" | grep -Eq '"up_info_speed":[1-9]' && return 0
  return 1
}

check_busy() {
  if _qbit_api_busy; then
    return 0   # BUSY
  elif [[ $? -eq 2 ]]; then
    # API not configured/unavailable; fall back to generic heuristic
    :
  fi
  check_busy_generic "$1"
}
