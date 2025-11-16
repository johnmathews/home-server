# Paperless-specific graceful shutdown plugin
# Detects if paperless-webserver is busy with active HTTP requests
# Validate common.sh was sourced
if [[ "${COMMON_SH_LOADED:-0}" != "1" ]]; then
   echo "ERROR: common.sh must be sourced before this plugin" >&2
   exit 1
fi

check_busy() {
  local name="$1"

  # Only paperless-webserver can be checked for active HTTP traffic
  [[ "$name" == "paperless-webserver" ]] || return 1

  # Check if there are active HTTP connections to port 8000
  # Use netstat/ss to count ESTABLISHED connections
  local active_conns
  active_conns=$(ss -tnp 2>/dev/null | grep -c ":8000.*ESTABLISHED" || echo 0)

  if [[ $active_conns -gt 0 ]]; then
    echo "source=paperless active_http_connections=$active_conns"
    return 0  # busy
  fi

  # Fallback to generic check (CPU/IO)
  check_busy_generic "$name"
}
