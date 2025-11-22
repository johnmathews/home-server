#!/usr/bin/env bats
# Integration tests for idempotency when already in sleep mode

load ../setup_test_env
load ../docker_helpers
load ../assertions

setup() {
    test_setup
}

teardown() {
    test_teardown
}

@test "Already sleeping: pause operation is idempotent" {
    # Setup: Containers already paused
    create_test_container "test-nginx-1" "paused"
    create_test_container "test-nginx-2" "paused"

    # Setup: Config
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    echo -e "test-nginx-1\ntest-nginx-2" > /etc/sleep-hours/containers.pause.list

    # Execute: Run pause again
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers still paused (no state change)
    assert_container_paused "test-nginx-1"
    assert_container_paused "test-nginx-2"

    # Assert: Log shows "already paused, skipping"
    assert_log_contains "already paused, skipping" "$output"

    # Assert: Summary shows changed=0, skipped=2
    assert_summary_stats "$output" 2 0 2 0
}

@test "Already sleeping: stop operation is idempotent" {
    # Setup: Containers already stopped
    create_test_container "test-app-1" "stopped"
    create_test_container "test-app-2" "stopped"

    # Setup: Config
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    echo -e "test-app-1\ntest-app-2" > /etc/sleep-hours/containers.stop.list

    # Execute: Run stop again
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" stop

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers still stopped
    assert_container_stopped "test-app-1"
    assert_container_stopped "test-app-2"

    # Assert: Log shows "already stopped, skipping"
    assert_log_contains "already stopped, skipping" "$output"

    # Assert: Summary shows changed=0, skipped=2
    assert_summary_stats "$output" 2 0 2 0
}

@test "Already sleeping: mixed states handled correctly" {
    # Setup: Mix of running and paused containers
    create_test_container "test-running" "running"
    create_test_container "test-paused" "paused"

    # Setup: Config
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    echo -e "test-running\ntest-paused" > /etc/sleep-hours/containers.pause.list

    # Execute: Run pause
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause

    # Assert: Success
    assert_exit_success $status

    # Assert: Both containers now paused
    assert_container_paused "test-running"
    assert_container_paused "test-paused"

    # Assert: One changed, one skipped
    assert_summary_stats "$output" 2 1 1 0
}
