#!/usr/bin/env bats
# Integration tests for sleep hours beginning (pause/stop operations)

load ../setup_test_env
load ../docker_helpers
load ../assertions

setup() {
    test_setup
}

teardown() {
    test_teardown
}

@test "Sleep beginning: pause operation runs successfully" {
    # Setup: Create running containers
    create_test_container "test-nginx-1" "running"
    create_test_container "test-nginx-2" "running"

    # Setup: Config files
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo -e "test-nginx-1\ntest-nginx-2" > /etc/sleep-hours/containers.pause.list

    # Execute: Run pause operation
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers are paused
    assert_container_paused "test-nginx-1"
    assert_container_paused "test-nginx-2"

    # Assert: Log shows correct phases
    assert_log_contains "PHASE 1: PROCESS CONTAINERS" "$output"
    assert_log_contains "PHASE 2: DISABLE NFS/SMB SHARES" "$output"
}

@test "Sleep beginning: stop operation runs successfully" {
    # Setup: Create running containers
    create_test_container "test-app-1" "running"
    create_test_container "test-app-2" "running"

    # Setup: Config files
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo -e "test-app-1\ntest-app-2" > /etc/sleep-hours/containers.stop.list

    # Execute: Run stop operation
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" stop

    # Assert: Success
    assert_exit_success $status

    # Assert: Containers are stopped
    assert_container_stopped "test-app-1"
    assert_container_stopped "test-app-2"

    # Assert: Summary shows correct stats
    assert_summary_stats "$output" 2 2 0 0
}

@test "Sleep beginning: shares are disabled via TrueNAS API" {
    # Setup: Running container
    create_test_container "test-nginx-1" "running"

    # Setup: Config
    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo "test-nginx-1" > /etc/sleep-hours/containers.pause.list

    # Verify shares are enabled initially
    assert_share_enabled 1 nfs
    assert_share_enabled 2 nfs

    # Execute: Run pause
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause

    # Assert: Success
    assert_exit_success $status

    # Assert: Shares are now disabled
    assert_share_disabled 1 nfs
    assert_share_disabled 2 nfs

    # Assert: Log shows share disable
    assert_log_contains "NFS disabled" "$output" || \
    assert_log_contains "disable_success" "$output"
}

@test "Sleep beginning: phase execution order is correct" {
    # Setup
    create_test_container "test-nginx-1" "running"

    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    cp "$FIXTURES_DIR/configs/truenas-nfs-shares.list" /etc/sleep-hours/
    echo "test-nginx-1" > /etc/sleep-hours/containers.pause.list

    # Execute
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause

    # Assert: Phases appear in correct order
    # Containers paused first, then shares disabled
    assert_log_sequence "$output" \
        "PHASE 1: PROCESS CONTAINERS" \
        "test-nginx-1 paused" \
        "PHASE 2: DISABLE NFS/SMB SHARES"
}

@test "Sleep beginning: summary stats are accurate" {
    # Setup: 3 containers
    create_test_container "test-1" "running"
    create_test_container "test-2" "running"
    create_test_container "test-3" "running"

    mkdir -p /etc/sleep-hours
    cp "$FIXTURES_DIR/configs/truenas.conf" /etc/sleep-hours/
    echo -e "test-1\ntest-2\ntest-3" > /etc/sleep-hours/containers.pause.list

    # Execute
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause

    # Assert: total=3, changed=3, skipped=0, failed=0
    assert_summary_stats "$output" 3 3 0 0
}
