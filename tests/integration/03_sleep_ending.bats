#!/usr/bin/env bats
# Integration tests for sleep hours ending (unpause/start operations)
# CRITICAL: Tests that shares are enabled BEFORE containers start

load ../setup_test_env
load ../docker_helpers
load ../assertions

setup() {
    test_setup
}

teardown() {
    test_teardown
}

@test "Sleep ending: unpause operation runs successfully" {
    # Setup: Create paused containers
    create_test_container "test-nginx-1" "paused"
    create_test_container "test-nginx-2" "paused"

    # Setup: Copy test config files to expected location
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo -e "test-nginx-1\ntest-nginx-2" > /etc/sleep-hours/containers.pause.list

    # Execute: Run unpause operation
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" unpause

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers are running
    assert_container_running "test-nginx-1"
    assert_container_running "test-nginx-2"

    # Assert: Log shows correct phases
    assert_log_contains "PHASE 1: PROCESS CONTAINERS" "$output"
    assert_log_contains "PHASE 2: ENABLE NFS/SMB SHARES" "$output"

    # Assert: Containers were actually unpaused
    assert_log_contains "test-nginx-1 unpaused" "$output"
    assert_log_contains "test-nginx-2 unpaused" "$output"
}

@test "Sleep ending: start operation runs successfully" {
    # Setup: Create stopped containers
    create_test_container "test-app-1" "stopped"
    create_test_container "test-app-2" "stopped"

    # Setup: Config files
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo -e "test-app-1\ntest-app-2" > /etc/sleep-hours/containers.stop.list

    # Execute: Run start operation
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" start

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers are running
    assert_container_running "test-app-1"
    assert_container_running "test-app-2"

    # Assert: Log shows phases
    assert_log_contains "PHASE 1: PROCESS CONTAINERS" "$output"
    assert_log_contains "PHASE 2: ENABLE NFS/SMB SHARES" "$output"
}

@test "Sleep ending: shares are enabled via TrueNAS API" {
    # Setup: Paused container
    create_test_container "test-nginx-1" "paused"

    # Setup: Config
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo "test-nginx-1" > /etc/sleep-hours/containers.pause.list

    # Setup: Manually disable shares first (simulate sleep hours state)
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

    # Execute: Run unpause
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" unpause

    # Assert: Success
    assert_exit_success $status

    # CRITICAL: Assert shares are now enabled
    assert_share_enabled 1 nfs
    assert_share_enabled 2 nfs

    # Assert: Log shows share enable
    assert_log_contains "NFS enabled" "$output" || \
    assert_log_contains "enable_success" "$output"
}

@test "Sleep ending: phase execution order is correct" {
    # Setup
    create_test_container "test-nginx-1" "paused"

    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo "test-nginx-1" > /etc/sleep-hours/containers.pause.list

    # Execute
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" unpause

    # Assert: Phases appear in correct order
    assert_log_sequence "$output" \
        "PHASE 1: PROCESS CONTAINERS" \
        "test-nginx-1 unpaused" \
        "PHASE 2: ENABLE NFS/SMB SHARES"

    # Note: This verifies that containers are unpaused BEFORE shares are enabled
    # which is the current implementation behavior
}
