#!/usr/bin/env bash
# Main test runner for sleep_hours test suite

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$TEST_DIR/.." && pwd)"

# Load setup functions
source "$TEST_DIR/setup_test_env.bash"

echo -e "${BLUE}=========================================="
echo "Sleep Hours Test Suite"
echo -e "==========================================${NC}"
echo ""

# Check dependencies
echo "Checking dependencies..."
MISSING_DEPS=0
for cmd in bats docker jq python3 nc curl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo -e "${RED}✗ Missing dependency: $cmd${NC}"
        MISSING_DEPS=1
    else
        echo -e "${GREEN}✓ $cmd${NC}"
    fi
done

if [[ $MISSING_DEPS -eq 1 ]]; then
    echo -e "${RED}ERROR: Missing required dependencies${NC}"
    echo "Please install missing tools and try again"
    exit 1
fi
echo ""

# Global setup
global_setup

# Track test results
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

run_test_file() {
    local test_file=$1
    local test_name=$(basename "$test_file" .bats)

    echo -e "${BLUE}Running: $test_name${NC}"

    if bats "$test_file"; then
        echo -e "${GREEN}✓ $test_name passed${NC}"
        ((PASSED_TESTS += 1)) || true
    else
        echo -e "${RED}✗ $test_name failed${NC}"
        ((FAILED_TESTS += 1)) || true
    fi
    ((TOTAL_TESTS += 1)) || true
    echo ""
}

# Run integration tests
echo -e "${YELLOW}=========================================="
echo "Integration Tests"
echo -e "==========================================${NC}"
echo ""

for test_file in "$TEST_DIR/integration"/*.bats; do
    if [[ -f "$test_file" ]]; then
        run_test_file "$test_file"
    fi
done

# Global teardown
global_teardown

# Summary
echo ""
echo -e "${BLUE}=========================================="
echo "Test Summary"
echo -e "==========================================${NC}"
echo "Total test files: $TOTAL_TESTS"
echo -e "${GREEN}Passed: $PASSED_TESTS${NC}"
if [[ $FAILED_TESTS -gt 0 ]]; then
    echo -e "${RED}Failed: $FAILED_TESTS${NC}"
else
    echo -e "Failed: $FAILED_TESTS"
fi
echo ""

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo -e "${GREEN}=========================================="
    echo "✓ All tests passed!"
    echo -e "==========================================${NC}"
    exit 0
else
    echo -e "${RED}=========================================="
    echo "✗ Some tests failed"
    echo -e "==========================================${NC}"
    exit 1
fi
