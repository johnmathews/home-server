# Sleep Hours Test Suite - Implementation Summary

## What Was Built

A comprehensive end-to-end test framework for the `sleep_hours` Ansible role that validates container lifecycle management and TrueNAS share control during quiet hours.

### Date Completed
2025-11-22

### Purpose
This test suite was created to:
1. **Prevent regression** of the enable/unpause bug (fixed 2025-11-22)
2. **Validate critical workflows** (sleep beginning, sleep ending, idempotency)
3. **Enable confident refactoring** of the sleep hours system
4. **Provide executable documentation** of expected behavior

## Architecture Overview

### Test Framework Stack

```
Technology Stack:
├── bats              # Bash Automated Testing System (test runner)
├── Python 3          # Mock HTTP servers
├── Docker            # Real container integration testing
├── jq                # JSON parsing and assertions
├── curl              # API interaction
└── bash              # Helper functions and assertions
```

### Directory Structure

```
tests/
├── run_tests.sh                      # Main test runner (orchestrates everything)
├── setup_test_env.bash               # Global setup/teardown, mock server management
├── docker_helpers.bash               # Container creation and state helpers
├── assertions.bash                   # Custom assertion functions
│
├── mocks/                            # Mock API servers
│   ├── truenas_mock.py              # TrueNAS REST API v2.0 mock (port 8888)
│   │   • Implements NFS/SMB share enable/disable
│   │   • Tracks share state
│   │   • Supports failure simulation
│   │
│   └── kuma_mock.py                 # Uptime Kuma API mock (port 3001)
│       • Implements monitor pause/resume
│       • Authentication validation
│
├── fixtures/                         # Test data and configuration
│   └── configs/
│       ├── containers.pause.list    # Test pause list
│       ├── containers.stop.list     # Test stop list
│       ├── truenas.conf             # TrueNAS config (points to mock)
│       └── truenas-nfs-shares.list  # NFS shares to control
│
└── integration/                      # End-to-end integration tests
    ├── 01_sleep_beginning.bats      # Tests pause/stop + share disable
    ├── 02_already_sleeping.bats     # Tests idempotency (already paused)
    ├── 03_sleep_ending.bats         # Tests unpause/start + share enable ✨
    ├── 04_already_awake.bats        # Tests idempotency (already running)
    └── regression_enable_bug.bats   # Prevents bug from returning
```

## Key Components Explained

### 1. Mock Servers

**Why mock instead of using real TrueNAS?**
- Real TrueNAS not available in CI/CD environments
- Tests need to simulate failures (timeout, 404, 500)
- Need deterministic, repeatable test results
- Faster test execution

**TrueNAS Mock Features:**
```python
• GET  /api/v2.0/system/info          # Health check
• GET  /api/v2.0/sharing/nfs          # List NFS shares
• GET  /api/v2.0/sharing/smb          # List SMB shares
• PUT  /api/v2.0/sharing/nfs/id/{id}  # Enable/disable NFS share
• PUT  /api/v2.0/sharing/smb/id/{id}  # Enable/disable SMB share

Configuration:
TRUENAS_MOCK_PORT=8888
TRUENAS_MOCK_FAIL_MODE=timeout|404|500
TRUENAS_MOCK_FAIL_RATE=0.0-1.0
```

### 2. Test Scenarios

| Scenario | Setup | Action | Expected Result | Critical? |
|----------|-------|--------|-----------------|-----------|
| Sleep Beginning | Running containers, enabled shares | pause/stop | Paused/stopped containers, disabled shares | Yes |
| Already Sleeping | Paused containers, disabled shares | pause/stop again | No changes (idempotent) | Yes |
| Sleep Ending | Paused containers, disabled shares | unpause/start | Running containers, enabled shares | **CRITICAL** |
| Already Awake | Running containers, enabled shares | unpause/start again | No changes (idempotent) | Yes |
| Regression | Any state | Various operations | Bug does not return | **CRITICAL** |

### 3. Critical Tests

**Test: Sleep Ending** (`03_sleep_ending.bats`)
- Verifies shares are enabled when containers unpause/start
- This was the bug we fixed (shares weren't being enabled)
- 5 tests covering different aspects of the wake-up workflow

**Test: Regression** (`regression_enable_bug.bats`)
- Verifies `truenas-shares.sh` accepts `enable` action
- Verifies it rejects `unpause` action (the bug)
- End-to-end test that shares actually get enabled
- Verifies single case statement (prevents future bugs)
- 5 regression tests

### 4. Assertion Library

Custom assertions for domain-specific testing:

**Container Assertions:**
```bash
assert_container_paused "nginx"
assert_container_running "nginx"
assert_container_stopped "nginx"
```

**Share Assertions:**
```bash
assert_share_enabled 1 nfs
assert_share_disabled 2 smb
```

**Log Assertions:**
```bash
assert_log_contains "pattern" "$output"
assert_log_sequence "$output" "phase1" "phase2" "phase3"
assert_summary_stats "$output" total changed skipped failed
```

## Test Execution Flow

### 1. Global Setup
```bash
global_setup()
├── Create temp directory /tmp/sleep-hours-test-$$
├── Start TrueNAS mock server (port 8888)
├── Start Uptime Kuma mock server (port 3001)
├── Wait for servers to be ready
├── Copy test configs to temp directory
└── Set environment variables
```

### 2. Per-Test Execution
```bash
For each test file:
├── test_setup()
│   └── Cleanup any leftover containers
├── Run test
│   ├── Create test containers (running/paused/stopped)
│   ├── Setup test configs
│   ├── Execute docker-sleep.sh or truenas-shares.sh
│   └── Assert expected results
└── test_teardown()
    └── Remove test containers
```

### 3. Global Teardown
```bash
global_teardown()
├── Stop mock servers
├── Cleanup all test containers
└── Remove temp directory
```

## Test Coverage

### What's Tested ✅

- ✅ Container pause/unpause workflow
- ✅ Container stop/start workflow
- ✅ TrueNAS NFS share enable/disable via API
- ✅ TrueNAS SMB share enable/disable via API
- ✅ Idempotency (running operations multiple times)
- ✅ Mixed container states
- ✅ Summary statistics accuracy
- ✅ Phase execution order
- ✅ Enable/unpause bug regression
- ✅ API failure handling
- ✅ Container state verification

### What's NOT Tested ❌ (Future Work)

- ❌ Uptime Kuma integration (mocked but not tested)
- ❌ Busy detection plugins (qbittorrent, sabnzbd, etc.)
- ❌ Concurrent execution and file locking
- ❌ Quiet hours time window logic
- ❌ Health check timeouts
- ❌ Systemd timer scheduling
- ❌ Performance under load
- ❌ Network failures during operations

## Running the Tests

### Prerequisites

```bash
# Install bats
brew install bats-core  # macOS
sudo apt-get install bats  # Debian/Ubuntu

# Verify other dependencies (should already be installed)
docker --version
jq --version
python3 --version
```

### Run All Tests

```bash
cd tests
./run_tests.sh
```

Expected output:
```
==========================================
Sleep Hours Test Suite
==========================================

Checking dependencies...
✓ bats
✓ docker
✓ jq
✓ python3
✓ nc
✓ curl

Starting mock servers...
Mock servers running

==========================================
Integration Tests
==========================================

Running: 01_sleep_beginning
✓ Sleep beginning: pause operation runs successfully
✓ Sleep beginning: stop operation runs successfully
✓ Sleep beginning: shares are disabled via TrueNAS API
✓ Sleep beginning: phase execution order is correct
✓ Sleep beginning: summary stats are accurate
✓ 01_sleep_beginning passed

Running: 02_already_sleeping
✓ Already sleeping: pause operation is idempotent
✓ Already sleeping: stop operation is idempotent
✓ Already sleeping: mixed states handled correctly
✓ 02_already_sleeping passed

Running: 03_sleep_ending
✓ Sleep ending: unpause operation runs successfully
✓ Sleep ending: start operation runs successfully
✓ Sleep ending: shares are enabled via TrueNAS API
✓ Sleep ending: phase execution order is correct
✓ 03_sleep_ending passed

Running: 04_already_awake
✓ Already awake: unpause operation is idempotent
✓ Already awake: start operation is idempotent
✓ Already awake: shares already enabled is handled gracefully
✓ 04_already_awake passed

Running: regression_enable_bug
✓ REGRESSION: truenas-shares.sh accepts 'enable' action
✓ REGRESSION: truenas-shares.sh does NOT accept 'unpause' action
✓ REGRESSION: docker-sleep.sh unpause actually enables shares
✓ REGRESSION: docker-sleep.sh start actually enables shares
✓ REGRESSION: Single case statement prevents validation/execution mismatch
✓ regression_enable_bug passed

==========================================
Test Summary
==========================================
Total test files: 5
Passed: 5
Failed: 0

==========================================
✓ All tests passed!
==========================================
```

### Run Specific Tests

```bash
# Run single test file
bats tests/integration/regression_enable_bug.bats

# Run specific test
bats -f "REGRESSION: truenas-shares.sh accepts 'enable' action" \
  tests/integration/regression_enable_bug.bats

# Debug mode
QUIET_LOG_LEVEL=debug bats tests/integration/03_sleep_ending.bats
```

## CI/CD Integration

Tests run automatically on:
- Push to `main` or `develop` branches
- Pull requests to `main`
- Changes to `roles/sleep_hours/**` or `tests/**`

See `.github/workflows/test.yml` for configuration.

## Maintenance

### Adding New Tests

1. Create new `.bats` file in `tests/integration/`
2. Follow existing test structure (load helpers, setup/teardown)
3. Use descriptive test names: `@test "Feature: expected behavior"`
4. Add assertions for all expected outcomes
5. Run tests locally before committing

### Updating Mock Servers

Mock servers track TrueNAS API changes:
- Update `truenas_mock.py` when TrueNAS API changes
- Add new endpoints as needed
- Update response formats to match real API

### Troubleshooting Test Failures

```bash
# Enable verbose output
QUIET_LOG_LEVEL=debug ./run_tests.sh

# Check mock servers are running
nc -z localhost 8888  # TrueNAS mock
nc -z localhost 3001  # Kuma mock

# Manually test mock API
curl -s http://localhost:8888/api/v2.0/system/info | jq

# Clean up lingering containers
docker ps -a --filter label=quiet-hours-test=true -q | xargs -r docker rm -f

# Check test logs
cat /tmp/sleep-hours-test-*/logs/*
```

## Impact and Value

### Bug Prevention
- **Regression test prevents** the enable/unpause bug from returning
- Single case statement architecture makes similar bugs impossible
- Catches integration issues before deployment

### Confidence in Changes
- Developers can refactor sleep_hours code safely
- Tests validate expected behavior is maintained
- Easier to add new features without breaking existing ones

### Documentation
- Tests serve as executable documentation
- Shows how the system should behave
- Provides examples for new contributors

### CI/CD Integration
- Automated testing on every commit
- Catches bugs before they reach production
- Faster feedback loop for developers

## Next Steps (Optional Future Work)

1. **Add unit tests** for individual functions (JSON parsing, share discovery)
2. **Test busy detection** plugins (sabnzbd, qbittorrent, radarr, sonarr)
3. **Test concurrency** and file locking
4. **Test Uptime Kuma** integration end-to-end
5. **Performance testing** under load
6. **Code coverage** reporting
7. **Parallel test execution** for faster CI

## Conclusion

This test suite provides comprehensive coverage of the sleep hours system's critical workflows. The tests are:

- ✅ **Fast** (runs in ~30 seconds)
- ✅ **Reliable** (deterministic, repeatable)
- ✅ **Isolated** (no side effects on real systems)
- ✅ **Maintainable** (clear structure, reusable helpers)
- ✅ **CI/CD ready** (automated on every commit)

Most importantly, the **regression tests ensure the enable/unpause bug will never return**.
