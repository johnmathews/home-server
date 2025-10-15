# Helpers used by all plugins

DOCKER_BIN="$(command -v docker || echo docker)"
CURL_BIN="$(command -v curl || echo curl)"

# Tunables
BUSY_CPU_PCT="${BUSY_CPU_PCT:-1.0}"               # >= 1.0% is busy
BUSY_BLOCKIO_NONZERO="${BUSY_BLOCKIO_NONZERO:-1}" # 1 => any non-zero BlockIO is busy
CURL_TIMEOUT_S="${CURL_TIMEOUT_S:-5}"             # HTTP timeout in seconds
CURL_INSECURE="${CURL_INSECURE:-0}"               # 1 => -k

plugin_note() {
  # usage: plugin_note <container> <event> <kvs...>
  # falls back to echo if log_debug is unavailable
  if command -v log_debug >/dev/null 2>&1; then
    log_debug "$1" plugin "$2" "${@:3}"
  else
    echo "level=debug container=$1 event=plugin reason=$2 ${*:3}"
  fi
}

http_get() {
  # Usage: http_get <url> [header1] [header2] ...
  # Echos body; returns non-zero on failure
  local url="$1"; shift
  if [[ "${CURL_INSECURE}" = "1" ]]; then
    "$CURL_BIN" -sS -m "${CURL_TIMEOUT_S}" -k "$url" "$@"
  else
    "$CURL_BIN" -sS -m "${CURL_TIMEOUT_S}" "$url" "$@"
  fi
}

# Returns 0 if BUSY, 1 if IDLE
check_busy_generic() {
  local name="$1"
  local line
  line="$("$DOCKER_BIN" stats --no-stream --format '{{.Name}} {{.CPUPerc}} {{.BlockIO}}' 2>/dev/null | awk -v n="$name" '$1==n {print; exit}')" || true
  if [[ -z "$line" ]]; then
    # If we can't read stats, be conservative: IDLE (don't block pausing everything)
    return 1
  fi

  # name cpu blockio
  # Example: qbittorrent 0.63% 4.88MB / 3.77MB
  local cpu_raw blockio
  cpu_raw="$(echo "$line" | awk '{print $2}')"
  blockio="$(echo "$line" | awk '{print $3" "$4" "$5}' )"

  # strip trailing % from CPU
  local cpu_val
  cpu_val="$(echo "${cpu_raw%%%}" | tr -d '%')" || cpu_val="0"

  # busy if CPU >= threshold
  awk -v c="${cpu_val:-0}" -v th="$BUSY_CPU_PCT" 'BEGIN{exit !(c>=th)}' && return 0

  if [[ "$BUSY_BLOCKIO_NONZERO" = "1" ]]; then
    # detect any non-zero BlockIO numbers like 1B, 2KB, 3MB, etc.
    if echo "$blockio" | grep -Eq '(^| )([1-9][0-9]*[KMG]?B|[1-9]\.[0-9]*[KMG]B)'; then
      return 0
    fi
  fi

  return 1
}
