#!/usr/bin/env bash
# Simple direct tests for sleep_hours without bats
# Run: ./tests/simple_test.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Setup
echo "=========================================="
echo "Simple Sleep Hours Tests"
echo "=========================================="
echo ""

# Create test environment
export TEST_TMP="/tmp/sleep-hours-simple-test"
mkdir -p "$TEST_TMP/config"

# Start mock servers
echo "Starting mock servers..."
python3 "$TEST_DIR/mocks/truenas_mock.py" &
TRUENAS_PID=$!
python3 "$TEST_DIR/mocks/kuma_mock.py" &
KUMA_PID=$!

# Wait for servers
sleep 2

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    kill $TRUENAS_PID $KUMA_PID 2>/dev/null || true
    docker ps -a --filter label=quiet-hours-test=true -q | xargs -r docker rm -f 2>/dev/null || true
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Setup environment
export CONFIG_DIR="$TEST_TMP/config"
export TRUENAS_CONF_FILE="$TEST_TMP/config/truenas.conf"
export TRUENAS_API_URL="http://localhost:8888/api/v2.0"
export TRUENAS_API_KEY="test-api-key-12345"

# Copy fixtures
cp "$TEST_DIR/fixtures/configs/"* "$TEST_TMP/config/"

# Test helper functions
test_passed() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
    ((TESTS_PASSED++))
    ((TESTS_RUN++))
}

test_failed() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    echo -e "  ${RED}$2${NC}"
    ((TESTS_FAILED++))
    ((TESTS_RUN++))
}

# ========================================
# TEST 1: truenas-shares.sh accepts 'enable' action
# ========================================
echo "Test 1: truenas-shares.sh accepts 'enable' action"

# Disable share first
curl -s -X PUT "http://localhost:8888/api/v2.0/sharing/nfs/id/1" \
    -H "Content-Type: application/json" \
    -d '{"enabled":false}' > /dev/null

# Run enable
output=$("$PROJECT_ROOT/roles/sleep_hours/files/truenas-shares.sh" enable "/mnt/tank/downloads" 2>&1)
exit_code=$?

# Check if it succeeded
if [[ $exit_code -eq 0 ]]; then
    # Check if share is actually enabled
    enabled=$(curl -s "http://localhost:8888/api/v2.0/sharing/nfs/id/1" | jq -r '.enabled')
    if [[ "$enabled" == "true" ]]; then
        test_passed "enable action works"
    else
        test_failed "enable action ran but share not enabled" "enabled=$enabled"
    fi
else
    test_failed "enable action failed" "Exit code: $exit_code"
fi

# ========================================
# TEST 2: truenas-shares.sh rejects 'unpause' action
# ========================================
echo ""
echo "Test 2: truenas-shares.sh rejects 'unpause' action"

output=$("$PROJECT_ROOT/roles/sleep_hours/files/truenas-shares.sh" unpause "/mnt/tank/downloads" 2>&1)
exit_code=$?

# Should fail with usage error
if [[ $exit_code -ne 0 ]] && echo "$output" | grep -q "usage="; then
    test_passed "unpause action correctly rejected"
else
    test_failed "unpause should be rejected" "Exit code: $exit_code, output: $output"
fi

# ========================================
# TEST 3: docker-sleep.sh can find config files
# ========================================
echo ""
echo "Test 3: docker-sleep.sh can find config files"

# Create test containers
docker run -d --name test-simple-1 --label quiet-hours-test=true nginx:alpine >/dev/null 2>&1
docker run -d --name test-simple-2 --label quiet-hours-test=true nginx:alpine >/dev/null 2>&1

# Create container list
echo -e "test-simple-1\ntest-simple-2" > "$TEST_TMP/config/containers.pause.list"

# Run pause
output=$("$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause 2>&1)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    # Check if containers are paused
    state1=$(docker inspect -f '{{.State.Paused}}' test-simple-1 2>/dev/null)
    state2=$(docker inspect -f '{{.State.Paused}}' test-simple-2 2>/dev/null)

    if [[ "$state1" == "true" && "$state2" == "true" ]]; then
        test_passed "docker-sleep.sh pause works"
    else
        test_failed "containers not paused" "state1=$state1, state2=$state2"
    fi
else
    test_failed "docker-sleep.sh pause failed" "Exit code: $exit_code, output: ${output:0:200}"
fi

# ========================================
# TEST 4: docker-sleep.sh unpause calls truenas-shares.sh enable
# ========================================
echo ""
echo "Test 4: docker-sleep.sh unpause enables shares"

# Disable shares first
curl -s -X PUT "http://localhost:8888/api/v2.0/sharing/nfs/id/1" \
    -H "Content-Type: application/json" \
    -d '{"enabled":false}' > /dev/null

curl -s -X PUT "http://localhost:8888/api/v2.0/sharing/nfs/id/2" \
    -H "Content-Type: application/json" \
    -d '{"enabled":false}' > /dev/null

# Run unpause
output=$("$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" unpause 2>&1)
exit_code=$?

if [[ $exit_code -eq 0 ]]; then
    # Check if shares are enabled
    enabled1=$(curl -s "http://localhost:8888/api/v2.0/sharing/nfs/id/1" | jq -r '.enabled')
    enabled2=$(curl -s "http://localhost:8888/api/v2.0/sharing/nfs/id/2" | jq -r '.enabled')

    if [[ "$enabled1" == "true" && "$enabled2" == "true" ]]; then
        test_passed "unpause enables shares"
    else
        test_failed "shares not enabled after unpause" "share1=$enabled1, share2=$enabled2"
    fi
else
    test_failed "docker-sleep.sh unpause failed" "Exit code: $exit_code"
fi

# ========================================
# TEST 5: Verify single ACTION case statement
# ========================================
echo ""
echo "Test 5: Single ACTION case statement in truenas-shares.sh"

script="$PROJECT_ROOT/roles/sleep_hours/files/truenas-shares.sh"
action_case_count=$(grep -c "^case.*ACTION.*in" "$script")

if [[ $action_case_count -eq 1 ]]; then
    # Check it has 'enable' not 'unpause'
    if grep -A 30 "^case.*ACTION.*in" "$script" | grep -q "^enable)"; then
        if ! grep -A 30 "^case.*ACTION.*in" "$script" | grep -q "^unpause)"; then
            test_passed "single ACTION case statement with enable"
        else
            test_failed "case has unpause instead of enable" ""
        fi
    else
        test_failed "case missing enable handler" ""
    fi
else
    test_failed "multiple ACTION case statements" "found $action_case_count"
fi

# Summary
echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
echo "Total: $TESTS_RUN"
echo -e "${GREEN}Passed: $TESTS_PASSED${NC}"
if [[ $TESTS_FAILED -gt 0 ]]; then
    echo -e "${RED}Failed: $TESTS_FAILED${NC}"
else
    echo "Failed: 0"
fi
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}✗ Some tests failed${NC}"
    exit 1
fi
