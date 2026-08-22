#!/usr/bin/env bash
# Common setup and teardown for sleep_hours tests

export TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"
export MOCK_DIR="$TEST_DIR/mocks"
export FIXTURES_DIR="$TEST_DIR/fixtures"
export TEST_TMP="/tmp/sleep-hours-test-$$"

# Mock server ports
export TRUENAS_MOCK_PORT=8888
export KUMA_MOCK_PORT=3001

# PID files for cleanup
export TRUENAS_MOCK_PID_FILE="$TEST_TMP/truenas_mock.pid"
export KUMA_MOCK_PID_FILE="$TEST_TMP/kuma_mock.pid"

wait_for_port() {
    local port=$1 timeout=${2:-10}
    local elapsed=0

    while ! nc -z localhost "$port" 2>/dev/null; do
        sleep 0.5
        elapsed=$((elapsed + 1))
        if [[ $elapsed -gt $((timeout * 2)) ]]; then
            echo "ERROR: Timeout waiting for port $port" >&2
            return 1
        fi
    done
    return 0
}

setup_mock_servers() {
    echo "Starting mock servers..."

    # Start TrueNAS mock
    python3 "$MOCK_DIR/truenas_mock.py" &
    echo $! > "$TRUENAS_MOCK_PID_FILE"

    # Start Kuma mock
    python3 "$MOCK_DIR/kuma_mock.py" &
    echo $! > "$KUMA_MOCK_PID_FILE"

    # Wait for servers to be ready
    if ! wait_for_port $TRUENAS_MOCK_PORT 10; then
        echo "ERROR: TrueNAS mock failed to start" >&2
        return 1
    fi

    if ! wait_for_port $KUMA_MOCK_PORT 10; then
        echo "ERROR: Kuma mock failed to start" >&2
        return 1
    fi

    echo "Mock servers running"
    return 0
}

stop_mock_servers() {
    echo "Stopping mock servers..."

    if [[ -f "$TRUENAS_MOCK_PID_FILE" ]]; then
        kill $(cat "$TRUENAS_MOCK_PID_FILE") 2>/dev/null || true
        rm -f "$TRUENAS_MOCK_PID_FILE"
    fi

    if [[ -f "$KUMA_MOCK_PID_FILE" ]]; then
        kill $(cat "$KUMA_MOCK_PID_FILE") 2>/dev/null || true
        rm -f "$KUMA_MOCK_PID_FILE"
    fi

    # Wait a bit for ports to be released
    sleep 0.5
}

setup_test_config() {
    echo "Setting up test configuration..."

    # Create test config directory
    mkdir -p "$TEST_TMP/config"

    # Copy test fixtures
    cp -r "$FIXTURES_DIR/configs/"* "$TEST_TMP/config/" 2>/dev/null || true

    # Set environment variables for scripts
    export TRUENAS_API_URL="http://localhost:$TRUENAS_MOCK_PORT/api/v2.0"
    export TRUENAS_API_KEY="test-api-key-12345"
    export UPTIME_KUMA_URL="http://localhost:$KUMA_MOCK_PORT"
    export UPTIME_KUMA_USER="test"
    export UPTIME_KUMA_PASSWORD="test"

    # Override config file paths (scripts check these env vars)
    export CONFIG_DIR="$TEST_TMP/config"
    # Deliberately NOT exporting QUIET_LIST.
    #
    # It used to be exported here, hardcoded to the PAUSE list. But
    # docker-sleep.sh uses QUIET_LIST for every action, so a `stop` or `start`
    # run also read the pause list, found none of its containers, and did
    # nothing — while still exiting 0. CONFIG_DIR alone is the right override:
    # the script derives containers.pause.list or containers.stop.list from it
    # per action (docker-sleep.sh:15-19).
    #
    # This was also why the suite behaved differently depending on how it was
    # started: run_tests.sh leaked this export into bats, direct `bats` did not,
    # so the same test passed one way and failed the other.
    export TRUENAS_CONF_FILE="$TEST_TMP/config/truenas.conf"

    # docker-sleep.sh defaults LOCK_DIR to /run/sleep-hours, which is a tmpfs
    # that only exists on a real systemd host. Without this override the whole
    # suite fails before doing any work, and it fails SILENTLY: `mkdir -p` is
    # swallowed by `|| true`, and on a box with no flock(1) the fallback branch
    # just returns 1 without logging, so every test reports a bare "Exit code: 1"
    # with no cause. That is why this looked like a test-logic bug for months.
    mkdir -p "$TEST_TMP/run"
    export LOCK_DIR="$TEST_TMP/run"

    # Force the quiet-hours window OPEN for tests.
    #
    # These used to be set to "" with the comment "disable the window check".
    # That is the opposite of what docker-sleep.sh does: is_within_quiet_window()
    # returns FALSE when either bound is empty, and the pause/stop guard then
    # exits 0 without touching a container. The suite therefore ran clean and
    # asserted on containers nothing had acted upon.
    #
    # Do not "fix" that in the script — unconfigured window means do nothing is
    # the correct production behaviour. Configure a window here instead.
    #
    # 00:00-00:00 is deliberate, not a placeholder: equal bounds take the
    # wrap-around branch, which returns true whenever now >= today 00:00, i.e.
    # always. A 00:00-23:59 window would leave a one-minute hole at 23:59.
    export QUIET_HOURS_START="00:00"
    export QUIET_HOURS_END="00:00"

    # Set log level
    export QUIET_LOG_LEVEL="${QUIET_LOG_LEVEL:-info}"

    echo "Test config ready at $TEST_TMP"
}

cleanup_test_containers() {
    echo "Cleaning up test containers..."
    docker ps -a --filter label=quiet-hours-test=true -q 2>/dev/null | \
        xargs -r docker rm -f >/dev/null 2>&1 || true
}

cleanup_all() {
    echo "Cleaning up test environment..."
    stop_mock_servers
    cleanup_test_containers
    rm -rf "$TEST_TMP"
}

# Global setup function (called once before all tests)
global_setup() {
    echo "=========================================="
    echo "Sleep Hours Test Suite - Setup"
    echo "=========================================="

    # Create temp directory
    mkdir -p "$TEST_TMP/config" "$TEST_TMP/logs"

    # Start mock servers
    if ! setup_mock_servers; then
        echo "ERROR: Failed to start mock servers" >&2
        cleanup_all
        exit 1
    fi

    # Setup config
    setup_test_config

    echo "Setup complete"
    echo ""
}

# Global teardown function (called once after all tests)
global_teardown() {
    echo ""
    echo "=========================================="
    echo "Sleep Hours Test Suite - Teardown"
    echo "=========================================="
    cleanup_all
    echo "Teardown complete"
}

# Per-test setup (called before each test)
test_setup() {
    # Use the global TEST_TMP set by global_setup
    # Don't create a new one with $$ since that changes per subprocess
    if [[ -z "$TEST_TMP" ]]; then
        # Fallback if global_setup wasn't called (shouldn't happen)
        export TEST_TMP="/tmp/sleep-hours-test-bats"
        mkdir -p "$TEST_TMP/config"
    fi

    # Ensure config directory exists for this test
    mkdir -p "$TEST_TMP/config"

    # Copy fixture configs if they exist and aren't already there
    if [[ -d "$FIXTURES_DIR/configs" && ! -f "$TEST_TMP/config/truenas.conf" ]]; then
        cp "$FIXTURES_DIR/configs/"* "$TEST_TMP/config/" 2>/dev/null || true
    fi

    # Re-export environment variables for this test (bats runs in subshells).
    #
    # This list must stay complete. Anything the script reads that is set only in
    # setup_test_config() does NOT reach here: that function runs once inside
    # global_setup, and whether its exports survive depends on whether bats was
    # invoked from run_tests.sh (they leak through the environment) or directly
    # (they do not). That inconsistency is why the suite failed differently
    # depending on how it was started, and why the cause looked like it moved.
    export CONFIG_DIR="$TEST_TMP/config"
    export TRUENAS_CONF_FILE="$TEST_TMP/config/truenas.conf"
    export TRUENAS_API_URL="http://localhost:${TRUENAS_MOCK_PORT:-8888}/api/v2.0"
    export TRUENAS_API_KEY="test-api-key-12345"

    # docker-sleep.sh defaults LOCK_DIR to /run/sleep-hours — a tmpfs that only
    # exists on a real systemd host. On macOS /run is a read-only filesystem, so
    # `mkdir -p` fails, `|| true` swallows it, and the lock write then fails.
    mkdir -p "$TEST_TMP/run"
    export LOCK_DIR="$TEST_TMP/run"

    # Force the quiet-hours window OPEN. See setup_test_config() for why equal
    # bounds mean "always inside" and why the script must not be changed instead.
    export QUIET_HOURS_START="00:00"
    export QUIET_HOURS_END="00:00"

    # docker-sleep.sh reads GRACE_DIR with `set -u` and never assigns it — in
    # production it comes from the systemd unit
    # (roles/sleep_hours/templates/docker-sleep@.service:48), which points at
    # /usr/local/lib/sleep-hours/plugins. Running the script outside systemd, as
    # these tests do, leaves it unbound and the script dies at PHASE 1. The repo
    # copy of those plugins is files/plugins.
    #
    # More broadly: that unit sets ~30 environment variables and this harness
    # replicates a handful. If a test fails on an unbound variable, check the
    # unit file first — it is the production environment these tests approximate.
    export GRACE_DIR="$PROJECT_ROOT/roles/sleep_hours/files/plugins"

    # Same reason: docker-sleep.sh shells out to the TrueNAS share helper at its
    # installed path. Point it at the repo copy.
    export TRUENAS_SHARES_BIN="$PROJECT_ROOT/roles/sleep_hours/files/truenas-shares.sh"

    # Clean up any leftover containers from previous tests
    cleanup_test_containers

    # Reset TrueNAS mock share state. All tests share one mock process, so a
    # test that runs `pause` leaves the shares disabled and the next test's
    # "shares start enabled" precondition fails for reasons unrelated to what it
    # is testing. Silent if the mock is not running (direct `bats` invocation).
    curl -s -m 2 "http://localhost:${TRUENAS_MOCK_PORT:-8888}/_test/reset" >/dev/null 2>&1 || true
}

# Per-test teardown (called after each test)
test_teardown() {
    # Clean up containers created during test
    cleanup_test_containers
}
