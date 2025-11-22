#!/usr/bin/env bats
# Integration tests for idempotency when already awake (running)

load ../setup_test_env
load ../docker_helpers
load ../assertions

setup() {
    test_setup
}

teardown() {
    test_teardown
}

@test "Already awake: unpause operation is idempotent" {
    # Setup: Containers already running
    create_test_container "test-nginx-1" "running"
    create_test_container "test-nginx-2" "running"

    # Setup: Config
    mkdir -p "$TEST_TMP/config"
    cp "$FIXTURES_DIR/configs/truenas.conf" "$TEST_TMP/config/"
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" "$TEST_TMP/config/"
    echo -e "test-nginx-1\ntest-nginx-2" > $TEST_TMP/config/containers.pause.list

    # Execute: Run unpause
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" unpause

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers still running
    assert_container_running "test-nginx-1"
    assert_container_running "test-nginx-2"

    # Assert: Log shows "already running, skipping"
    assert_log_contains "already running, skipping" "$output"

    # Assert: Summary shows changed=0, skipped=2
    assert_summary_stats "$output" 2 0 2 0
}

@test "Already awake: start operation is idempotent" {
    # Setup: Containers already running
    create_test_container "test-app-1" "running"
    create_test_container "test-app-2" "running"

    # Setup: Config
    mkdir -p "$TEST_TMP/config"
    cp "$FIXTURES_DIR/configs/truenas.conf" "$TEST_TMP/config/"
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" "$TEST_TMP/config/"
    echo -e "test-app-1\ntest-app-2" > $TEST_TMP/config/containers.stop.list

    # Execute: Run start
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" start

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers still running
    assert_container_running "test-app-1"
    assert_container_running "test-app-2"

    # Assert: Log shows "already running, skipping"
    assert_log_contains "already running, skipping" "$output"

    # Assert: Summary shows changed=0, skipped=2
    assert_summary_stats "$output" 2 0 2 0
}

@test "Already awake: shares already enabled is handled gracefully" {
    # Setup: Running container
    create_test_container "test-nginx-1" "running"

    # Setup: Shares already enabled
    assert_share_enabled 1 nfs
    assert_share_enabled 2 nfs

    # Setup: Config
    mkdir -p "$TEST_TMP/config"
    cp "$FIXTURES_DIR/configs/truenas.conf" "$TEST_TMP/config/"
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" "$TEST_TMP/config/"
    echo "test-nginx-1" > $TEST_TMP/config/containers.pause.list

    # Execute: Run unpause (containers already running, shares already enabled)
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" unpause

    # Assert: Success (no errors even though everything is already in desired state)
    assert_exit_success $status

    # Assert: Shares still enabled
    assert_share_enabled 1 nfs
    assert_share_enabled 2 nfs
}
