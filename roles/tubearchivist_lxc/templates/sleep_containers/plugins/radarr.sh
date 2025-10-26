# Radarr: busy if queue has items
# Requires:
#   RADARR_URL (e.g., http://127.0.0.1:7878)
#   RADARR_API_KEY
# Optional:
#   CURL_TIMEOUT_S, CURL_INSECURE

_radarr_queue_busy() {
  [[ -z "${RADARR_URL:-}" || -z "${RADARR_API_KEY:-}" ]] && return 2
  # Minimal page read; Radarr v3 returns JSON with totalRecords
  # Use header for API key
  local body
  body="$(http_get "${RADARR_URL%/}/api/v3/queue?page=1&pageSize=1" -H "X-Api-Key: ${RADARR_API_KEY}" || true)"
  [[ -z "$body" ]] && return 2

  # Busy if "totalRecords":[1-9...]
  echo "$body" | grep -Eq '"totalRecords"\s*:\s*[1-9]' && return 0
  return 1
}

check_busy() {
  if _radarr_queue_busy; then
    return 0  # busy
  elif [[ $? -eq 2 ]]; then
    # API not configured or failed; fall back
    :
  fi
  check_busy_generic "$1"
}
