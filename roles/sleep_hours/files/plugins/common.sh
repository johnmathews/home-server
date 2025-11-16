# Helpers used by all plugins

DOCKER_BIN="$(command -v docker || echo docker)"

# Tunables (seconds + thresholds)
BUSY_CPU_PCT="${BUSY_CPU_PCT:-1.0}"             # >= => busy
IO_SAMPLE_S="${IO_SAMPLE_S:-2}"                  # seconds between samples
BUSY_READ_BPS="${BUSY_READ_BPS:-65536}"          # 64 KiB/s default
BUSY_WRITE_BPS="${BUSY_WRITE_BPS:-65536}"        # 64 KiB/s default

# -- internal helpers ---------------------------------------------------------

# Parse "4.88MB" or "512kB" or "0B" into integer bytes
_to_bytes() {
   # input like "4.88MB" "512kB" "0B"
   local v="${1:-0B}"
   
   # Trim whitespace
   v="$(echo "$v" | xargs)"
   [[ -z "$v" ]] && { echo "0"; return 0; }
   
   # Extract number part - must start with digit
   local num unit
   if [[ "$v" =~ ^([0-9]+(\.[0-9]+)?)(.*)$ ]]; then
     num="${BASH_REMATCH[1]}"
     unit="${BASH_REMATCH[3]}"
   else
     # No number found - return 0
     echo "0"
     return 0
   fi
   
    # Normalize unit to upper-case, remove spaces/underscores
    unit="$(echo "$unit" | sed 's/[[:space:]_]//g' | tr '[:lower:]' '[:upper:]')"
    [[ -z "$unit" ]] && unit="B"

   # default: bytes
   local mul=1
   case "$unit" in
     B ) mul=1 ;;
     KB|KIB|K ) mul=1024 ;;
     MB|MIB|M ) mul=$((1024*1024)) ;;
     GB|GIB|G ) mul=$((1024*1024*1024)) ;;
     TB|TIB|T ) mul=$((1024*1024*1024*1024)) ;;
     * ) mul=1 ;;  # unknown unit, treat as bytes
   esac

   # Use awk for float multiplication to handle decimals
   awk -v n="$num" -v m="$mul" 'BEGIN{printf "%.0f\n", int(n)*m + int((n-int(n))*m)}'
}

# Read one stats line for a container: "<name> <cpu%> <read> / <write>"
# Prints: "cpu_raw read_raw write_raw" (space-separated)
_read_stats_line() {
   local name="$1"
   # Example docker stats line: qbittorrent 0.63% 4.88MB / 3.77MB
   local line stats_timeout=5
   
   # Add timeout with KILL signal to prevent hanging zombie processes
   # Use --preserve-status to get the actual exit code
   line="$(timeout --preserve-status -s KILL "$stats_timeout" "$DOCKER_BIN" stats --no-stream "$name" --format '{{.Name}} {{.CPUPerc}} {{.BlockIO}}' 2>/dev/null)" || true
   
   if [[ -z "$line" ]]; then
     echo ""
     return 1
   fi
  # cpu_raw is $2; blockio is $3 $4 $5 => "<read> / <write>"
  # shellcheck disable=SC2086
  local cpu_raw read_raw slash write_raw
  cpu_raw="$(echo "$line" | awk '{print $2}')"
  read_raw="$(echo "$line" | awk '{print $3}')"
  slash="$(echo "$line" | awk '{print $4}')"    # "/"
  write_raw="$(echo "$line" | awk '{print $5}')"
  echo "$cpu_raw $read_raw $write_raw"
  return 0
}

# -- public API ---------------------------------------------------------------

# Prints detail and returns:
#   0 if BUSY (by CPU% or IO bps thresholds)
#   1 if IDLE
check_busy_generic() {
  local name="$1"

  # First sample
  local s1 cpu1_raw r1_raw w1_raw
  s1="$(_read_stats_line "$name")" || {
    echo "source=generic_stats_unavailable"
    return 1
  }
   cpu1_raw="$(echo "$s1" | awk '{print $1}')"
   r1_raw="$(echo "$s1"   | awk '{print $2}')"
   w1_raw="$(echo "$s1"   | awk '{print $3}')"

   # CPU% as float without '%' - validate format
   local cpu1
   if [[ "$cpu1_raw" =~ %$ ]]; then
     cpu1="${cpu1_raw%%%}"  # Remove trailing %
     cpu1="$(echo "$cpu1" | grep -oE '^[0-9]+(\.[0-9]+)?$')"  # Validate format
     [[ -z "$cpu1" ]] && cpu1="0"
   else
     cpu1="0"
   fi
   
   # Early CPU decision (single-sample is fine for CPU)
   if awk -v c="$cpu1" -v th="$BUSY_CPU_PCT" 'BEGIN{exit !(c>=th)}'; then
     echo "source=generic cpu_pct=${cpu1} cpu_threshold=${BUSY_CPU_PCT} read_bps=0 write_bps=0 read_bps_threshold=${BUSY_READ_BPS} write_bps_threshold=${BUSY_WRITE_BPS} sample_s=${IO_SAMPLE_S}"
     return 0
   fi

  # Sleep to establish IO delta
  sleep "${IO_SAMPLE_S}"

  # Second sample
  local s2 cpu2_raw r2_raw w2_raw
  s2="$(_read_stats_line "$name")" || {
    # If we cannot read the second sample, stick with CPU-only decision above
    echo "source=generic cpu_pct=${cpu1} cpu_threshold=${BUSY_CPU_PCT} read_bps=0 write_bps=0 read_bps_threshold=${BUSY_READ_BPS} write_bps_threshold=${BUSY_WRITE_BPS} sample_s=${IO_SAMPLE_S}"
    return 1
  }
  cpu2_raw="$(echo "$s2" | awk '{print $1}')"
  r2_raw="$(echo "$s2"   | awk '{print $2}')"
  w2_raw="$(echo "$s2"   | awk '{print $3}')"

  # Convert human sizes to bytes (cumulative)
  local r1_bytes r2_bytes w1_bytes w2_bytes
  r1_bytes="$(_to_bytes "$r1_raw")"
  r2_bytes="$(_to_bytes "$r2_raw")"
  w1_bytes="$(_to_bytes "$w1_raw")"
  w2_bytes="$(_to_bytes "$w2_raw")"

  # Deltas (bytes)
  local r_delta w_delta
  r_delta=$(( r2_bytes - r1_bytes ))
  w_delta=$(( w2_bytes - w1_bytes ))
  if (( r_delta < 0 )); then r_delta=0; fi
  if (( w_delta < 0 )); then w_delta=0; fi

  # Rates (bytes/sec), integer division
  local read_bps write_bps
  if (( IO_SAMPLE_S > 0 )); then
    read_bps=$(( r_delta / IO_SAMPLE_S ))
    write_bps=$(( w_delta / IO_SAMPLE_S ))
  else
    read_bps=0; write_bps=0
  fi

  # Decide busy by IO thresholds
  if (( read_bps >= BUSY_READ_BPS || write_bps >= BUSY_WRITE_BPS )); then
    echo "source=generic cpu_pct=${cpu1} cpu_threshold=${BUSY_CPU_PCT} read_bps=${read_bps} write_bps=${write_bps} read_bps_threshold=${BUSY_READ_BPS} write_bps_threshold=${BUSY_WRITE_BPS} sample_s=${IO_SAMPLE_S}"
    return 0
  fi

  # Idle
  echo "source=generic cpu_pct=${cpu1} cpu_threshold=${BUSY_CPU_PCT} read_bps=${read_bps} write_bps=${write_bps} read_bps_threshold=${BUSY_READ_BPS} write_bps_threshold=${BUSY_WRITE_BPS} sample_s=${IO_SAMPLE_S}"
  return 1
}
