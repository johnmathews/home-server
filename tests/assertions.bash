#!/usr/bin/env bash
# Custom assertions for sleep_hours tests

assert_container_state() {
    local name=$1
    local expected=$2
    local actual=$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null)

    if [[ "$actual" != "$expected" ]]; then
        echo "ASSERTION FAILED: Container $name state" >&2
        echo "  Expected: $expected" >&2
        echo "  Actual: $actual" >&2
        return 1
    fi
    return 0
}

assert_container_paused() {
    local name=$1
    local running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    local paused=$(docker inspect -f '{{.State.Paused}}' "$name" 2>/dev/null)

    if [[ "$running" != "true" || "$paused" != "true" ]]; then
        echo "ASSERTION FAILED: Container $name not paused" >&2
        echo "  Running: $running, Paused: $paused" >&2
        return 1
    fi
    return 0
}

assert_container_running() {
    local name=$1
    local running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    local paused=$(docker inspect -f '{{.State.Paused}}' "$name" 2>/dev/null)

    if [[ "$running" != "true" || "$paused" == "true" ]]; then
        echo "ASSERTION FAILED: Container $name not running" >&2
        echo "  Running: $running, Paused: $paused" >&2
        return 1
    fi
    return 0
}

assert_container_stopped() {
    local name=$1
    local running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)

    if [[ "$running" != "false" ]]; then
        echo "ASSERTION FAILED: Container $name not stopped" >&2
        echo "  Running: $running" >&2
        return 1
    fi
    return 0
}

assert_share_enabled() {
    local share_id=$1
    local share_type=${2:-nfs}
    local url="http://localhost:${TRUENAS_MOCK_PORT:-8888}/api/v2.0/sharing/${share_type}/id/${share_id}"

    local enabled=$(curl -s "$url" 2>/dev/null | jq -r '.enabled // "unknown"')

    if [[ "$enabled" != "true" ]]; then
        echo "ASSERTION FAILED: Share $share_type/$share_id not enabled" >&2
        echo "  Enabled: $enabled" >&2
        return 1
    fi
    return 0
}

assert_share_disabled() {
    local share_id=$1
    local share_type=${2:-nfs}
    local url="http://localhost:${TRUENAS_MOCK_PORT:-8888}/api/v2.0/sharing/${share_type}/id/${share_id}"

    local enabled=$(curl -s "$url" 2>/dev/null | jq -r '.enabled // "unknown"')

    if [[ "$enabled" != "false" ]]; then
        echo "ASSERTION FAILED: Share $share_type/$share_id not disabled" >&2
        echo "  Enabled: $enabled" >&2
        return 1
    fi
    return 0
}

assert_log_contains() {
    local pattern=$1
    local output="$2"

    if ! echo "$output" | grep -q "$pattern"; then
        echo "ASSERTION FAILED: Log does not contain pattern" >&2
        echo "  Pattern: $pattern" >&2
        echo "  Output (first 500 chars):" >&2
        echo "$output" | head -c 500 >&2
        echo "" >&2
        return 1
    fi
    return 0
}

assert_log_not_contains() {
    local pattern=$1
    local output="$2"

    if echo "$output" | grep -q "$pattern"; then
        echo "ASSERTION FAILED: Log contains unwanted pattern" >&2
        echo "  Pattern: $pattern" >&2
        return 1
    fi
    return 0
}

assert_log_sequence() {
    local output="$1"
    shift
    local patterns=("$@")

    local last_pos=0
    for pattern in "${patterns[@]}"; do
        # Find position of pattern in output
        local full_output_to_search="${output:$last_pos}"
        local match_line=$(echo "$full_output_to_search" | grep -n "$pattern" | head -1 | cut -d: -f1)

        if [[ -z "$match_line" ]]; then
            echo "ASSERTION FAILED: Pattern not found in expected sequence" >&2
            echo "  Missing pattern: $pattern" >&2
            echo "  Expected after position: $last_pos" >&2
            return 1
        fi

        # Update last position
        last_pos=$((last_pos + match_line))
    done

    return 0
}

assert_summary_stats() {
    local output="$1"
    local expected_total=$2
    local expected_changed=$3
    local expected_skipped=$4
    local expected_failed=$5

    local summary=$(echo "$output" | grep "Summary: total=" | tail -1)

    if ! echo "$summary" | grep -q "total=$expected_total"; then
        echo "ASSERTION FAILED: Summary total mismatch" >&2
        echo "  Expected total: $expected_total" >&2
        echo "  Summary line: $summary" >&2
        return 1
    fi

    if ! echo "$summary" | grep -q "changed=$expected_changed"; then
        echo "ASSERTION FAILED: Summary changed mismatch" >&2
        echo "  Expected changed: $expected_changed" >&2
        echo "  Summary line: $summary" >&2
        return 1
    fi

    if ! echo "$summary" | grep -q "skipped=$expected_skipped"; then
        echo "ASSERTION FAILED: Summary skipped mismatch" >&2
        echo "  Expected skipped: $expected_skipped" >&2
        echo "  Summary line: $summary" >&2
        return 1
    fi

    if ! echo "$summary" | grep -q "failed=$expected_failed"; then
        echo "ASSERTION FAILED: Summary failed mismatch" >&2
        echo "  Expected failed: $expected_failed" >&2
        echo "  Summary line: $summary" >&2
        return 1
    fi

    return 0
}

assert_exit_success() {
    local exit_code=$1

    if [[ $exit_code -ne 0 ]]; then
        echo "ASSERTION FAILED: Expected success exit code" >&2
        echo "  Exit code: $exit_code" >&2
        return 1
    fi
    return 0
}

assert_exit_failure() {
    local exit_code=$1

    if [[ $exit_code -eq 0 ]]; then
        echo "ASSERTION FAILED: Expected failure exit code" >&2
        return 1
    fi
    return 0
}
