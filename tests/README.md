# Sleep Hours Test Suite

Comprehensive end-to-end tests for the `sleep_hours` Ansible role.

## Overview

This test suite validates the sleep hours system that automatically pauses/stops Docker containers and disables TrueNAS
NFS/SMB shares during quiet hours.

### What's Tested

- **Sleep beginning**: Containers pause/stop, shares disable
- **Already sleeping**: Idempotency when already in sleep mode
- **Sleep ending**: Shares enable, containers unpause/start ✨ CRITICAL
- **Already awake**: Idempotency when already running
- **Regression**: Prevents the enable/unpause bug from returning
- **Edge cases**: API failures, busy containers, mixed states

## Architecture

### Components

```
tests/
├── run_tests.sh              # Main test runner
├── setup_test_env.bash       # Setup/teardown
├── docker_helpers.bash       # Docker utilities
├── assertions.bash           # Custom assertions
├── mocks/
│   ├── truenas_mock.py      # Mock TrueNAS API (port 8888)
│   └── kuma_mock.py         # Mock Uptime Kuma (port 3001)
├── fixtures/
│   └── configs/             # Test configuration files
└── integration/
    ├── 01_sleep_beginning.bats
    ├── 02_already_sleeping.bats
    ├── 03_sleep_ending.bats
    ├── 04_already_awake.bats
    └── regression_enable_bug.bats
```

### Mock Servers

**TrueNAS Mock API** (Python HTTP server)

- Implements TrueNAS SCALE REST API v2.0
- Tracks share state (enabled/disabled)
- Supports failure simulation

**Uptime Kuma Mock** (Python HTTP server)

- Simulates monitor pause/resume
- Validates authentication

### Test Flow

1. **Setup**: Start mock servers, create test containers
2. **Execute**: Run docker-sleep.sh with test config
3. **Assert**: Verify container states, share states, logs
4. **Teardown**: Clean up containers, stop mocks

## Requirements

- **bats** - Bash Automated Testing System
- **Docker** - Container runtime
- **jq** - JSON processor
- **Python 3** - For mock servers
- **curl** - API calls
- **nc** (netcat) - Port checking

### Install Dependencies

```bash
# macOS
brew install bats-core jq python3

# Debian/Ubuntu
sudo apt-get install bats jq python3 curl netcat-openbsd

# Install Docker if not already installed
# See: https://docs.docker.com/get-docker/
```

## Running Tests

### Run All Tests

```bash
cd tests
./run_tests.sh
```

### Run Specific Test File

```bash
bats tests/integration/regression_enable_bug.bats
```

### Run Single Test

```bash
bats -f "REGRESSION: truenas-shares.sh accepts 'enable' action" \
  tests/integration/regression_enable_bug.bats
```

### Debug Mode

```bash
# Enable verbose logging
QUIET_LOG_LEVEL=debug ./run_tests.sh

# Enable bash tracing
QUIET_DEBUG=1 bats tests/integration/03_sleep_ending.bats
```

## Test Scenarios

### Scenario 1: Sleep Beginning

Simulates the start of sleep hours.

**Setup**: Running containers, enabled shares **Action**: `docker-sleep.sh pause|stop` **Expected**: Containers
paused/stopped, shares disabled

**Key Tests**:

- Containers transition to paused/stopped state
- TrueNAS shares are disabled
- Phase execution order is correct
- Summary stats are accurate

### Scenario 2: Already Sleeping

Tests idempotency when already in sleep mode.

**Setup**: Paused/stopped containers, disabled shares **Action**: `docker-sleep.sh pause|stop` (run again) **Expected**:
No state changes, operation skipped

**Key Tests**:

- Containers remain paused/stopped
- No unnecessary API calls
- Summary shows `skipped=N, changed=0`

### Scenario 3: Sleep Ending ✨ CRITICAL

Simulates the end of sleep hours.

**Setup**: Paused/stopped containers, disabled shares **Action**: `docker-sleep.sh unpause|start` **Expected**:
Containers running, shares enabled

**Key Tests**:

- Containers transition to running state
- TrueNAS shares are enabled
- Phase execution order is correct
- Health checks performed

### Scenario 4: Already Awake

Tests idempotency when already running.

**Setup**: Running containers, enabled shares **Action**: `docker-sleep.sh unpause|start` (run again) **Expected**: No
state changes, operation skipped

**Key Tests**:

- Containers remain running
- Shares remain enabled
- Summary shows `skipped=N, changed=0`

### Regression Tests

Prevents the enable/unpause bug from returning.

**The Bug** (fixed 2025-11-22):

- Case statement had `unpause)` instead of `enable)`
- Result: enable action was silently ignored
- Impact: Shares never re-enabled after sleep hours

**Tests**:

- `truenas-shares.sh` accepts `enable` action
- `truenas-shares.sh` rejects `unpause` action
- `docker-sleep.sh unpause` actually enables shares
- Single case statement prevents validation/execution mismatch

## Mock Server Configuration

### TrueNAS Mock

```bash
# Default port
TRUENAS_MOCK_PORT=8888

# Failure modes
TRUENAS_MOCK_FAIL_MODE=timeout  # timeout, 404, 500
TRUENAS_MOCK_FAIL_RATE=0.3      # 30% of requests fail
```

### Uptime Kuma Mock

```bash
# Default port
KUMA_MOCK_PORT=3001

# Test credentials
UPTIME_KUMA_USER=test
UPTIME_KUMA_PASSWORD=test
```

## Writing New Tests

### Test File Structure

```bash
#!/usr/bin/env bats

load ../setup_test_env
load ../docker_helpers
load ../assertions

setup() {
    test_setup
}

teardown() {
    test_teardown
}

@test "My test description" {
    # Setup: Create test environment
    create_test_container "test-app" "running"

    # Execute: Run the operation
    run "$PROJECT_ROOT/roles/sleep_hours/files/docker-sleep.sh" pause

    # Assert: Verify results
    assert_exit_success $status
    assert_container_paused "test-app"
    assert_log_contains "test-app paused" "$output"
}
```

### Available Assertions

**Container States**:

- `assert_container_state <name> <expected>`
- `assert_container_paused <name>`
- `assert_container_running <name>`
- `assert_container_stopped <name>`

**Share States**:

- `assert_share_enabled <id> [type]`
- `assert_share_disabled <id> [type]`

**Log Validation**:

- `assert_log_contains <pattern> <output>`
- `assert_log_not_contains <pattern> <output>`
- `assert_log_sequence <output> <pattern1> <pattern2> ...`
- `assert_summary_stats <output> <total> <changed> <skipped> <failed>`

**Exit Codes**:

- `assert_exit_success <code>`
- `assert_exit_failure <code>`

### Docker Helpers

- `create_test_container <name> <state>`
- `get_container_state <name>`
- `is_container_paused <name>`
- `is_container_running <name>`
- `is_container_stopped <name>`
- `remove_test_container <name>`
- `remove_all_test_containers`

## Troubleshooting

### Tests Fail to Start

```bash
# Check dependencies
which bats docker jq python3 nc curl

# Check ports are available
nc -z localhost 8888  # Should fail (port not in use)
nc -z localhost 3001  # Should fail (port not in use)

# If ports are in use, kill processes
lsof -ti:8888 | xargs kill
lsof -ti:3001 | xargs kill
```

### Mock Servers Won't Start

```bash
# Test mock servers manually
cd tests/mocks
python3 truenas_mock.py  # Should start on port 8888
python3 kuma_mock.py     # Should start on port 3001

# Check Python version
python3 --version  # Should be 3.7+
```

### Container Cleanup

```bash
# Remove all test containers
docker ps -a --filter label=quiet-hours-test=true -q | xargs -r docker rm -f

# Remove test temp files
rm -rf /tmp/sleep-hours-test-*
```

### Verbose Output

```bash
# See all bats output
bats --tap tests/integration/03_sleep_ending.bats

# Enable debug logging
QUIET_LOG_LEVEL=debug bats tests/integration/03_sleep_ending.bats

# Enable bash tracing
QUIET_DEBUG=1 bats tests/integration/03_sleep_ending.bats
```

## CI/CD Integration

See `.github/workflows/test.yml` for GitHub Actions configuration.

### Running in CI

```yaml
jobs:
 test:
  runs-on: ubuntu-latest
  steps:
   - uses: actions/checkout@v3
   - name: Install dependencies
     run: sudo apt-get install -y bats jq python3
   - name: Run tests
     run: ./tests/run_tests.sh
```

## Future Enhancements

- [ ] Add unit tests for individual functions
- [ ] Test busy detection plugins
- [ ] Test concurrent execution and locking
- [ ] Test Uptime Kuma integration
- [ ] Performance benchmarks
- [ ] Test coverage reporting
- [ ] Parallel test execution

## References

- [Bats Documentation](https://bats-core.readthedocs.io/)
- [TrueNAS API Docs](https://www.truenas.com/docs/api/)
- [Sleep Hours Documentation](../documentation/quiet_hours.md)
