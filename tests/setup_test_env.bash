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
    export QUIET_LIST="$TEST_TMP/config/containers.pause.list"
    export TRUENAS_CONF_FILE="$TEST_TMP/config/truenas.conf"

    # Disable quiet hours window check for tests (always allow operations)
    export QUIET_HOURS_START=""
    export QUIET_HOURS_END=""

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
    # Ensure TEST_TMP is available (bats runs tests in subshells)
    if [[ -z "$TEST_TMP" ]]; then
        export TEST_TMP="/tmp/sleep-hours-test-$$"
    fi

    # Ensure config directory exists for this test
    mkdir -p "$TEST_TMP/config"

    # Copy fixture configs if they exist and aren't already there
    if [[ -d "$FIXTURES_DIR/configs" && ! -f "$TEST_TMP/config/truenas.conf" ]]; then
        cp "$FIXTURES_DIR/configs/"* "$TEST_TMP/config/" 2>/dev/null || true
    fi

    # Re-export environment variables for this test
    export CONFIG_DIR="$TEST_TMP/config"
    export TRUENAS_CONF_FILE="$TEST_TMP/config/truenas.conf"
    export TRUENAS_API_URL="http://localhost:${TRUENAS_MOCK_PORT:-8888}/api/v2.0"
    export TRUENAS_API_KEY="test-api-key-12345"

    # Note: QUIET_LIST is set by docker-sleep.sh based on action
    # But we can't override the hardcoded paths in the script easily
    # So tests must write files to both possible locations

    # Clean up any leftover containers from previous tests
    cleanup_test_containers
}

# Per-test teardown (called after each test)
test_teardown() {
    # Clean up containers created during test
    cleanup_test_containers
}
