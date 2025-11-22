#!/usr/bin/env bats
# Regression tests for the enable/unpause bug
# Prevents the bug from returning in future changes

load ../setup_test_env
load ../docker_helpers
load ../assertions

setup() {
    test_setup
}

teardown() {
    test_teardown
}

@test "REGRESSION: truenas-shares.sh accepts 'enable' action" {
    # This test prevents the bug that was fixed on 2025-11-22
    # Bug: Case statement had 'unpause)' instead of 'enable)'
    # Result: enable action was silently ignored

    # Setup: Disable shares first
    curl -s -X PUT \
        "http://localhost:$TRUENAS_MOCK_PORT/api/v2.0/sharing/nfs/id/1" \
        -H "Content-Type: application/json" \
        -d '{"enabled":false}' > /dev/null

    # Verify share is disabled
    assert_share_disabled 1 nfs

    # Setup: Config files
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/

    # Execute: Call truenas-shares.sh with 'enable' action
    run "$PROJECT_ROOT/roles/sleep_hours/files/truenas-shares.sh" enable "/mnt/tank/downloads"

    # Assert: Command succeeds (not "unknown action" error)
    assert_exit_success $status

    # Assert: Share is actually enabled
    assert_share_enabled 1 nfs

    # Assert: Log shows "Starting enable action"
    assert_log_contains "Starting enable action" "$output"

    # Assert: Does NOT show usage error
    assert_log_not_contains "usage=" "$output"
}

@test "REGRESSION: truenas-shares.sh does NOT accept 'unpause' action" {
    # The bug had 'unpause)' in the case statement
    # This should NOT be a valid action for this script

    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/

    # Execute: Call with invalid 'unpause' action
    run "$PROJECT_ROOT/roles/sleep_hours/files/truenas-shares.sh" unpause "/mnt/tank/downloads"

    # Assert: Command fails (invalid action)
    assert_exit_failure $status

    # Assert: Shows usage error
    assert_log_contains "usage=" "$output"
}

@test "REGRESSION: docker-sleep.sh unpause actually enables shares" {
    # End-to-end regression test
    # Verifies the full workflow works after the bug fix

    # Setup: Create paused container
    create_test_container "test-nginx-1" "paused"

    # Setup: Disable shares (simulate sleep hours state)
    curl -s -X PUT \
        "http://localhost:$TRUENAS_MOCK_PORT/api/v2.0/sharing/nfs/id/1" \
        -H "Content-Type: application/json" \
        -d '{"enabled":false}' > /dev/null

    curl -s -X PUT \
        "http://localhost:$TRUENAS_MOCK_PORT/api/v2.0/sharing/nfs/id/2" \
        -H "Content-Type: application/json" \
        -d '{"enabled":false}' > /dev/null

    # Verify shares are disabled
    assert_share_disabled 1 nfs
    assert_share_disabled 2 nfs

    # Setup: Config files
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo "test-nginx-1" > /etc/sleep-hours/containers.pause.list

    # Execute: Run unpause
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" unpause

    # Assert: Success
    assert_exit_success $status

    # CRITICAL: Shares must be enabled (this was the bug!)
    assert_share_enabled 1 nfs
    assert_share_enabled 2 nfs

    # Assert: Container is running
    assert_container_running "test-nginx-1"

    # Assert: Log shows enable operation
    assert_log_contains "PHASE 2: ENABLE NFS/SMB SHARES" "$output"
}

@test "REGRESSION: docker-sleep.sh start actually enables shares" {
    # Same regression test but for stop/start workflow

    # Setup: Create stopped container
    create_test_container "test-app-1" "stopped"

    # Setup: Disable shares
    curl -s -X PUT \
        "http://localhost:$TRUENAS_MOCK_PORT/api/v2.0/sharing/nfs/id/1" \
        -H "Content-Type: application/json" \
        -d '{"enabled":false}' > /dev/null

    # Verify share is disabled
    assert_share_disabled 1 nfs

    # Setup: Config files
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo "test-app-1" > /etc/sleep-hours/containers.stop.list

    # Execute: Run start
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" start

    # Assert: Success
    assert_exit_success $status

    # CRITICAL: Share must be enabled
    assert_share_enabled 1 nfs

    # Assert: Container is running
    assert_container_running "test-app-1"
}

@test "REGRESSION: Single case statement prevents validation/execution mismatch" {
    # This test verifies the code refactoring that prevents future bugs
    # By having a single case statement, we can't have mismatched validation/execution

    # Read the truenas-shares.sh file
    local script="$PROJECT_ROOT/roles/sleep_hours/files/truenas-shares.sh"

    # Count case statements (should be exactly 1)
    local case_count=$(grep -c "^case.*in$" "$script")

    # Assert: Only 1 case statement
    if [[ $case_count -ne 1 ]]; then
        echo "ASSERTION FAILED: Expected 1 case statement, found $case_count" >&2
        echo "This prevents validation/execution mismatch bugs" >&2
        return 1
    fi

    # Assert: The single case statement has 'enable)' not 'unpause)'
    if ! grep -A 20 "^case.*ACTION.*in" "$script" | grep -q "^enable)"; then
        echo "ASSERTION FAILED: Case statement missing 'enable)' handler" >&2
        return 1
    fi

    # Assert: No 'unpause)' in case statement
    if grep -A 20 "^case.*ACTION.*in" "$script" | grep -q "^unpause)"; then
        echo "ASSERTION FAILED: Case statement should not have 'unpause)' handler" >&2
        return 1
    fi
}
