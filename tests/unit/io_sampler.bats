#!/usr/bin/env bats
# Unit tests for io_sampler.sh
#
# Run with: bats tests/unit/io_sampler.bats

# Setup mock /sys/block filesystem before each test
setup() {
  # Create temp directory for mock sysfs
  TEST_TMP=$(mktemp -d)
  export SYS_BLOCK_PATH="$TEST_TMP/sys/block"
  mkdir -p "$SYS_BLOCK_PATH"

  # Source the module under test
  PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  source "$PROJECT_ROOT/roles/nas/files/io_sampler.sh"
}

# Clean up after each test
teardown() {
  _cleanup_sample_dir 2>/dev/null || true
  rm -rf "$TEST_TMP"
}

# Helper: Create a mock disk with specified stats
# Args: $1=disk_name, $2=sectors_read, $3=sectors_written
create_mock_disk() {
  local disk="$1"
  local sectors_read="${2:-0}"
  local sectors_written="${3:-0}"

  mkdir -p "$SYS_BLOCK_PATH/$disk"

  # Format: reads_completed reads_merged sectors_read read_time
  #         writes_completed writes_merged sectors_written write_time
  #         ios_in_progress io_time weighted_io_time
  # We only care about fields 3 and 7 (sectors read/written)
  cat > "$SYS_BLOCK_PATH/$disk/stat" << EOF
    1234    567 $sectors_read   8901   2345    678 $sectors_written   9012    0   5678   12345
EOF
}

# Helper: Update mock disk stats
update_mock_disk() {
  local disk="$1"
  local sectors_read="$2"
  local sectors_written="$3"

  cat > "$SYS_BLOCK_PATH/$disk/stat" << EOF
    1234    567 $sectors_read   8901   2345    678 $sectors_written   9012    0   5678   12345
EOF
}

# =============================================================================
# Basic functionality tests
# =============================================================================

@test "sample_io_start: reads initial stats from single disk" {
  create_mock_disk "sda" 1000 2000

  sample_io_start "sda"
  local rc=$?
  [ "$rc" -eq 0 ]

  # Verify sample was stored
  local output
  output=$(_read_sample "sda" "start")
  [ "$output" = "1000 2000" ]
}

@test "sample_io_start: reads initial stats from multiple disks" {
  create_mock_disk "sda" 1000 2000
  create_mock_disk "sdb" 3000 4000
  create_mock_disk "sdc" 5000 6000

  sample_io_start "sda" "sdb" "sdc"
  local rc=$?
  [ "$rc" -eq 0 ]

  local output
  output=$(_read_sample "sda" "start")
  [ "$output" = "1000 2000" ]

  output=$(_read_sample "sdb" "start")
  [ "$output" = "3000 4000" ]

  output=$(_read_sample "sdc" "start")
  [ "$output" = "5000 6000" ]
}

@test "sample_io_start: warns on missing disk but continues" {
  create_mock_disk "sda" 1000 2000
  # sdb does not exist

  # Capture stderr to file to check warning, call directly to preserve state
  local stderr_file="$TEST_TMP/stderr"
  local rc=0
  sample_io_start "sda" "sdb" 2>"$stderr_file" || rc=$?

  [ "$rc" -eq 1 ]  # Returns error due to missing disk
  grep -q "Warning.*sdb" "$stderr_file"

  # sda should still be sampled
  local output
  output=$(_read_sample "sda" "start")
  [ "$output" = "1000 2000" ]
}

@test "sample_io_end: captures final stats" {
  create_mock_disk "sda" 1000 2000

  sample_io_start "sda"

  # Simulate I/O activity
  update_mock_disk "sda" 1500 2500

  run sample_io_end
  [ "$status" -eq 0 ]

  run _read_sample "sda" "end"
  [ "$output" = "1500 2500" ]
}

# =============================================================================
# Delta calculation tests
# =============================================================================

@test "get_io_delta: calculates total sectors transferred" {
  create_mock_disk "sda" 1000 2000
  sample_io_start "sda"

  update_mock_disk "sda" 1100 2200  # +100 read, +200 write
  sample_io_end

  run get_io_delta "sda"

  [ "$status" -eq 0 ]
  [ "$output" = "300" ]  # 100 + 200
}

@test "get_io_delta: returns zero for no activity" {
  create_mock_disk "sda" 1000 2000
  sample_io_start "sda"

  # No change
  sample_io_end

  run get_io_delta "sda"

  [ "$status" -eq 0 ]
  [ "$output" = "0" ]
}

@test "get_io_delta: returns -1 for unsampled disk" {
  run get_io_delta "nonexistent"

  [ "$status" -eq 1 ]
  [ "$output" = "-1" ]
}

@test "get_io_delta_detailed: returns read, write, and total" {
  create_mock_disk "sda" 1000 2000
  sample_io_start "sda"

  update_mock_disk "sda" 1100 2300  # +100 read, +300 write
  sample_io_end

  run get_io_delta_detailed "sda"

  [ "$status" -eq 0 ]
  [ "$output" = "100 300 400" ]
}

# =============================================================================
# Idle detection tests
# =============================================================================

@test "is_disk_idle: returns true for zero I/O with default threshold" {
  create_mock_disk "sda" 1000 2000
  sample_io_start "sda"
  sample_io_end  # No change

  run is_disk_idle "sda"

  [ "$status" -eq 0 ]  # 0 = idle
}

@test "is_disk_idle: returns false for any I/O with default threshold" {
  create_mock_disk "sda" 1000 2000
  sample_io_start "sda"

  update_mock_disk "sda" 1001 2000  # Just 1 sector read
  sample_io_end

  run is_disk_idle "sda"

  [ "$status" -eq 1 ]  # 1 = not idle
}

@test "is_disk_idle: respects custom threshold - below threshold" {
  create_mock_disk "sda" 1000 2000
  sample_io_start "sda"

  update_mock_disk "sda" 1050 2000  # 50 sectors read
  sample_io_end

  run is_disk_idle "sda" 100  # threshold = 100

  [ "$status" -eq 0 ]  # 50 <= 100, so idle
}

@test "is_disk_idle: respects custom threshold - above threshold" {
  create_mock_disk "sda" 1000 2000
  sample_io_start "sda"

  update_mock_disk "sda" 1150 2000  # 150 sectors read
  sample_io_end

  run is_disk_idle "sda" 100  # threshold = 100

  [ "$status" -eq 1 ]  # 150 > 100, not idle
}

@test "is_disk_idle: returns not-idle for unsampled disk (safe default)" {
  run is_disk_idle "nonexistent"

  [ "$status" -eq 1 ]  # Assume active if we can't read stats
}

# =============================================================================
# Multiple disk tests
# =============================================================================

@test "multiple disks: independent tracking" {
  create_mock_disk "sda" 1000 2000
  create_mock_disk "sdb" 5000 6000

  sample_io_start "sda" "sdb"

  # sda has activity, sdb is idle
  update_mock_disk "sda" 2000 3000  # +1000 read, +1000 write
  update_mock_disk "sdb" 5000 6000  # no change

  sample_io_end

  # Check sda
  run get_io_delta "sda"
  [ "$output" = "2000" ]

  # Check sdb
  run get_io_delta "sdb"
  [ "$output" = "0" ]

  # Idle checks
  run is_disk_idle "sda"
  [ "$status" -eq 1 ]  # not idle

  run is_disk_idle "sdb"
  [ "$status" -eq 0 ]  # idle
}

@test "multiple disks: mixed activity with threshold" {
  create_mock_disk "sda" 1000 2000
  create_mock_disk "sdb" 5000 6000
  create_mock_disk "sdc" 8000 9000

  sample_io_start "sda" "sdb" "sdc"

  # sda: heavy activity (1000 sectors)
  # sdb: light activity (50 sectors)
  # sdc: no activity (0 sectors)
  update_mock_disk "sda" 1500 2500
  update_mock_disk "sdb" 5025 6025
  update_mock_disk "sdc" 8000 9000

  sample_io_end

  # With threshold of 100 sectors
  run is_disk_idle "sda" 100
  [ "$status" -eq 1 ]  # 1000 > 100, not idle

  run is_disk_idle "sdb" 100
  [ "$status" -eq 0 ]  # 50 <= 100, idle

  run is_disk_idle "sdc" 100
  [ "$status" -eq 0 ]  # 0 <= 100, idle
}

# =============================================================================
# Edge cases
# =============================================================================

@test "handles large sector counts" {
  # Simulate a disk with billions of sectors (large disk, lots of historical I/O)
  create_mock_disk "sda" 999999999000 888888888000

  sample_io_start "sda"

  update_mock_disk "sda" 999999999100 888888888200
  sample_io_end

  run get_io_delta "sda"

  [ "$status" -eq 0 ]
  [ "$output" = "300" ]  # 100 + 200
}

@test "handles stat file with extra whitespace" {
  mkdir -p "$SYS_BLOCK_PATH/sda"
  # Extra leading/trailing whitespace
  echo "   1234    567    1000   8901   2345    678    2000   9012    0   5678   12345   " \
    > "$SYS_BLOCK_PATH/sda/stat"

  sample_io_start "sda"

  echo "   1234    567    1100   8901   2345    678    2200   9012    0   5678   12345   " \
    > "$SYS_BLOCK_PATH/sda/stat"

  sample_io_end

  run get_io_delta "sda"

  [ "$status" -eq 0 ]
  [ "$output" = "300" ]
}

@test "sectors_to_human: converts correctly" {
  run sectors_to_human 0
  [ "$output" = "0B" ]

  run sectors_to_human 1
  [ "$output" = "512B" ]

  run sectors_to_human 2048
  [ "$output" = "1.00MB" ]

  run sectors_to_human 2097152
  [ "$output" = "1.00GB" ]
}

# =============================================================================
# Re-sampling tests (ensure clean state between samples)
# =============================================================================

@test "resampling: new sample_io_start clears previous data" {
  create_mock_disk "sda" 1000 2000
  create_mock_disk "sdb" 3000 4000

  # First sample
  sample_io_start "sda"
  update_mock_disk "sda" 1100 2100
  sample_io_end

  # Second sample with different disk
  sample_io_start "sdb"
  update_mock_disk "sdb" 3500 4500
  sample_io_end

  # sda should no longer have valid data
  run get_io_delta "sda"
  [ "$output" = "-1" ]

  # sdb should have new data
  run get_io_delta "sdb"
  [ "$output" = "1000" ]
}

# =============================================================================
# get_sampled_disks tests
# =============================================================================

@test "get_sampled_disks: returns list of sampled disks" {
  create_mock_disk "sda" 1000 2000
  create_mock_disk "sdb" 3000 4000

  sample_io_start "sda" "sdb"

  run get_sampled_disks
  [ "$output" = "sda sdb" ]
}
