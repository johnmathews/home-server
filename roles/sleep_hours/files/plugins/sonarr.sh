# Sonarr: busy if queue has items
# Requires:
#   SONARR_URL (e.g., http://127.0.0.1:8989)
#   SONARR_API_KEY
# Optional:
#   CURL_TIMEOUT_S, CURL_INSECURE

_sonarr_queue_busy() {
  [[ -z "${SONARR_URL:-}" || -z "${SONARR_API_KEY:-}" ]] && return 2
  local body
  body="$(http_get "${SONARR_URL%/}/api/v3/queue?page=1&pageSize=1" -H "X-Api-Key: ${SONARR_API_KEY}" || true)"
  [[ -z "$body" ]] && return 2

  # Busy if "totalRecords":[1-9...]
  echo "$body" | grep -Eq '"totalRecords"\s*:\s*[1-9]' && return 0
  return 1
}

check_busy() {
  if _sonarr_queue_busy; then
    return 0
  elif [[ $? -eq 2 ]]; then
    :
  fi
  check_busy_generic "$1"
}
