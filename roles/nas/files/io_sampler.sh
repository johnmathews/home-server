#!/bin/bash

# IO Sampler - Measures disk I/O using kernel counters from /sys/block/*/stat
#
# Usage:
#   source io_sampler.sh
#   sample_io_start sda sdb sdc
#   sleep 60
#   sample_io_end
#   for disk in sda sdb sdc; do
#     if is_disk_idle "$disk" 100; then
#       echo "$disk is idle"
#     fi
#   done
#
# The /sys/block/<dev>/stat file contains space-separated fields:
#   Field 1:  reads completed successfully
#   Field 2:  reads merged
#   Field 3:  sectors read
#   Field 4:  time spent reading (ms)
#   Field 5:  writes completed successfully
#   Field 6:  writes merged
#   Field 7:  sectors written
#   Field 8:  time spent writing (ms)
#   ...
#
# We track sectors read (field 3) and sectors written (field 7) as they
# represent actual data transfer, not just I/O operations.

# Allow overriding for testing
: "${SYS_BLOCK_PATH:=/sys/block}"

# Temp directory for storing sample data (bash 3.x compatible - no assoc arrays)
IO_SAMPLE_DIR=""
IO_SAMPLED_DISKS=""

# Initialize/reset sample storage
_init_sample_dir() {
  if [[ -n "$IO_SAMPLE_DIR" ]] && [[ -d "$IO_SAMPLE_DIR" ]]; then
    rm -rf "$IO_SAMPLE_DIR"
  fi
  IO_SAMPLE_DIR=$(mktemp -d)
  IO_SAMPLED_DISKS=""
}

# Clean up sample storage
_cleanup_sample_dir() {
  if [[ -n "$IO_SAMPLE_DIR" ]] && [[ -d "$IO_SAMPLE_DIR" ]]; then
    rm -rf "$IO_SAMPLE_DIR"
  fi
  IO_SAMPLE_DIR=""
  IO_SAMPLED_DISKS=""
}

# Read current I/O stats for a disk
# Args: $1 = disk name (e.g., "sda")
# Returns: "sectors_read sectors_written" or empty on error
_read_disk_stat() {
  local disk="$1"
  local stat_file="${SYS_BLOCK_PATH}/${disk}/stat"

  if [[ ! -f "$stat_file" ]]; then
    return 1
  fi

  # Read and parse stat file
  local line
  line=$(cat "$stat_file") || return 1

  # Convert to array (works in bash 3.x)
  set -- $line
  local sectors_read="${3:-0}"
  local sectors_written="${7:-0}"

  echo "$sectors_read $sectors_written"
}

# Store sample data to file
# Args: $1=disk, $2=phase (start|end), $3=sectors_read, $4=sectors_written
_store_sample() {
  local disk="$1" phase="$2" sectors_read="$3" sectors_written="$4"
  echo "$sectors_read $sectors_written" > "$IO_SAMPLE_DIR/${disk}.${phase}"
}

# Read sample data from file
# Args: $1=disk, $2=phase (start|end)
# Returns: "sectors_read sectors_written" or empty
_read_sample() {
  local disk="$1" phase="$2"
  local file="$IO_SAMPLE_DIR/${disk}.${phase}"
  if [[ -f "$file" ]]; then
    cat "$file"
  fi
}

# Start I/O sampling for specified disks
# Args: $@ = disk names (e.g., "sda" "sdb" "sdc")
# Returns: 0 on success, 1 if any disk fails
sample_io_start() {
  local rc=0

  _init_sample_dir

  for disk in "$@"; do
    local stats
    if stats=$(_read_disk_stat "$disk"); then
      set -- $stats
      _store_sample "$disk" "start" "$1" "$2"
      IO_SAMPLED_DISKS="$IO_SAMPLED_DISKS $disk"
    else
      echo "Warning: Could not read stats for $disk" >&2
      rc=1
    fi
  done

  # Trim leading space
  IO_SAMPLED_DISKS="${IO_SAMPLED_DISKS# }"

  return $rc
}

# End I/O sampling - captures final stats for all sampled disks
# Returns: 0 on success, 1 if any disk fails
sample_io_end() {
  local rc=0

  for disk in $IO_SAMPLED_DISKS; do
    local stats
    if stats=$(_read_disk_stat "$disk"); then
      set -- $stats
      _store_sample "$disk" "end" "$1" "$2"
    else
      echo "Warning: Could not read end stats for $disk" >&2
      rc=1
    fi
  done

  return $rc
}

# Get I/O delta for a disk (sectors read + written during sample period)
# Args: $1 = disk name
# Returns: total sectors transferred, or -1 on error
get_io_delta() {
  local disk="$1"

  local start_data end_data
  start_data=$(_read_sample "$disk" "start")
  end_data=$(_read_sample "$disk" "end")

  if [[ -z "$start_data" ]] || [[ -z "$end_data" ]]; then
    echo "-1"
    return 1
  fi

  set -- $start_data
  local start_read="$1" start_write="$2"

  set -- $end_data
  local end_read="$1" end_write="$2"

  local delta_read=$((end_read - start_read))
  local delta_write=$((end_write - start_write))
  local total=$((delta_read + delta_write))

  echo "$total"
}

# Get detailed I/O delta breakdown
# Args: $1 = disk name
# Outputs: "read_sectors write_sectors total_sectors"
get_io_delta_detailed() {
  local disk="$1"

  local start_data end_data
  start_data=$(_read_sample "$disk" "start")
  end_data=$(_read_sample "$disk" "end")

  if [[ -z "$start_data" ]] || [[ -z "$end_data" ]]; then
    echo "-1 -1 -1"
    return 1
  fi

  set -- $start_data
  local start_read="$1" start_write="$2"

  set -- $end_data
  local end_read="$1" end_write="$2"

  local delta_read=$((end_read - start_read))
  local delta_write=$((end_write - start_write))
  local total=$((delta_read + delta_write))

  echo "$delta_read $delta_write $total"
}

# Check if disk is idle (I/O below threshold)
# Args: $1 = disk name, $2 = threshold in sectors (default: 0 = truly zero I/O)
# Returns: 0 if idle, 1 if active
is_disk_idle() {
  local disk="$1"
  local threshold="${2:-0}"

  local delta
  delta=$(get_io_delta "$disk")

  if [[ "$delta" == "-1" ]]; then
    return 1  # Error reading stats, assume not idle (safe default)
  fi

  if [[ "$delta" -le "$threshold" ]]; then
    return 0  # Idle
  else
    return 1  # Active
  fi
}

# Convert sectors to human-readable bytes
# Args: $1 = sectors (512 bytes each)
sectors_to_human() {
  local sectors="$1"
  local bytes=$((sectors * 512))

  if [[ $bytes -ge 1073741824 ]]; then
    # Use awk for floating point (bc may not be available)
    awk "BEGIN {printf \"%.2fGB\", $bytes / 1073741824}"
  elif [[ $bytes -ge 1048576 ]]; then
    awk "BEGIN {printf \"%.2fMB\", $bytes / 1048576}"
  elif [[ $bytes -ge 1024 ]]; then
    awk "BEGIN {printf \"%.2fKB\", $bytes / 1024}"
  else
    echo "${bytes}B"
  fi
}

# Print summary of all sampled disks
# Args: $1 = threshold (optional, for idle determination)
print_io_summary() {
  local threshold="${1:-0}"

  printf "%-10s %12s %12s %12s %8s\n" "DISK" "READ" "WRITE" "TOTAL" "STATUS"
  printf "%-10s %12s %12s %12s %8s\n" "----" "----" "-----" "-----" "------"

  for disk in $IO_SAMPLED_DISKS; do
    local details
    details=$(get_io_delta_detailed "$disk")
    set -- $details
    local delta_read="$1" delta_write="$2" total="$3"

    local status="ACTIVE"
    if [[ "$total" -le "$threshold" ]]; then
      status="IDLE"
    fi

    printf "%-10s %12s %12s %12s %8s\n" \
      "$disk" \
      "$(sectors_to_human "$delta_read")" \
      "$(sectors_to_human "$delta_write")" \
      "$(sectors_to_human "$total")" \
      "$status"
  done
}

# Get list of sampled disks
get_sampled_disks() {
  echo "$IO_SAMPLED_DISKS"
}

# If run directly (not sourced), provide a simple CLI
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    --help|-h)
      echo "Usage: $0 <disk1> [disk2] ... [--duration=SECONDS] [--threshold=SECTORS]"
      echo ""
      echo "Samples I/O activity on specified disks and reports if they are idle."
      echo ""
      echo "Options:"
      echo "  --duration=N   Sample duration in seconds (default: 10)"
      echo "  --threshold=N  Sectors threshold for idle (default: 0 = zero I/O)"
      echo ""
      echo "Example:"
      echo "  $0 sda sdb --duration=60 --threshold=100"
      exit 0
      ;;
  esac

  # Parse arguments
  DURATION=10
  THRESHOLD=0
  DISKS=""

  for arg in "$@"; do
    case "$arg" in
      --duration=*) DURATION="${arg#*=}" ;;
      --threshold=*) THRESHOLD="${arg#*=}" ;;
      *) DISKS="$DISKS $arg" ;;
    esac
  done

  DISKS="${DISKS# }"  # Trim leading space

  if [[ -z "$DISKS" ]]; then
    echo "Error: No disks specified" >&2
    exit 1
  fi

  echo "Sampling I/O on: $DISKS"
  echo "Duration: ${DURATION}s, Threshold: ${THRESHOLD} sectors"
  echo ""

  # shellcheck disable=SC2086
  sample_io_start $DISKS
  echo "Waiting ${DURATION} seconds..."
  sleep "$DURATION"
  sample_io_end

  echo ""
  print_io_summary "$THRESHOLD"

  # Cleanup
  _cleanup_sample_dir
fi
