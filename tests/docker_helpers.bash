#!/usr/bin/env bash
# Docker helper functions for testing

create_test_container() {
    local name=$1
    local state=${2:-running}

    echo "Creating test container: $name (state: $state)"

    # Create and start container
    docker run -d \
        --name "$name" \
        --label quiet-hours-test=true \
        --label quiet-hours=true \
        nginx:alpine >/dev/null 2>&1

    # Set desired state
    case "$state" in
        paused)
            docker pause "$name" >/dev/null 2>&1
            ;;
        stopped|exited)
            docker stop "$name" >/dev/null 2>&1
            ;;
        running)
            # Already running, do nothing
            ;;
        *)
            echo "ERROR: Unknown state: $state" >&2
            return 1
            ;;
    esac

    # Verify container was created
    if ! docker inspect "$name" >/dev/null 2>&1; then
        echo "ERROR: Failed to create container $name" >&2
        return 1
    fi

    return 0
}

get_container_state() {
    local name=$1
    docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || echo "not-found"
}

is_container_paused() {
    local name=$1
    local paused=$(docker inspect -f '{{.State.Paused}}' "$name" 2>/dev/null)
    [[ "$paused" == "true" ]]
}

is_container_running() {
    local name=$1
    local running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    local paused=$(docker inspect -f '{{.State.Paused}}' "$name" 2>/dev/null)
    [[ "$running" == "true" && "$paused" != "true" ]]
}

is_container_stopped() {
    local name=$1
    local running=$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)
    [[ "$running" == "false" ]]
}

remove_test_container() {
    local name=$1
    docker rm -f "$name" >/dev/null 2>&1 || true
}

remove_all_test_containers() {
    docker ps -a --filter label=quiet-hours-test=true -q 2>/dev/null | \
        xargs -r docker rm -f >/dev/null 2>&1 || true
}

# Create a busy container (high CPU usage)
create_busy_container() {
    local name=$1

    docker run -d \
        --name "$name" \
        --label quiet-hours-test=true \
        --label quiet-hours=true \
        alpine:latest \
        sh -c 'while true; do :; done' >/dev/null 2>&1
}
