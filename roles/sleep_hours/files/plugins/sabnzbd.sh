#!/usr/bin/env bash
# SABnzbd busy check plugin with robust API integration
#
# Required environment variables:
#   SAB_URL       - SABnzbd base URL (e.g., http://127.0.0.1:8081)
#   SAB_API_KEY   - SABnzbd API key
#
# Optional environment variables:
#   SAB_TIMEOUT_S              - Curl timeout (default: 5)
#   SAB_RETRIES                - API retry count (default: 2)
#   SAB_RETRY_DELAY_S          - Initial retry delay (default: 1)
#   SAB_BUSY_THRESHOLD_KBPS    - Min download speed = busy (default: 10)
#   SAB_CHECK_POSTPROC         - Check post-processing (default: 1)
#   SAB_HEALTH_CHECK           - Validate connectivity (default: 1)
#   CURL_INSECURE              - Allow self-signed certs (default: 0)
#   CURL_TIMEOUT_S             - Inherited from common.sh if set
#
# Busy detection criteria:
#   - Queue status is "Downloading" or "Fetching"
#   - Download speed > threshold (default 10 KB/s)
#   - Jobs queued AND not paused AND data remaining
#   - Post-processing active (if SAB_CHECK_POSTPROC=1)
#
# Falls back to check_busy_generic if API unavailable

# Validate common.sh was sourced
if [[ "${COMMON_SH_LOADED:-0}" != "1" ]]; then
   echo "ERROR: common.sh must be sourced before this plugin" >&2
   exit 1
fi

# Configuration defaults
SAB_TIMEOUT_S="${SAB_TIMEOUT_S:-${CURL_TIMEOUT_S:-5}}"
SAB_RETRIES="${SAB_RETRIES:-2}"
SAB_RETRY_DELAY_S="${SAB_RETRY_DELAY_S:-1}"
SAB_BUSY_THRESHOLD_KBPS="${SAB_BUSY_THRESHOLD_KBPS:-10}"
SAB_CHECK_POSTPROC="${SAB_CHECK_POSTPROC:-1}"
SAB_HEALTH_CHECK="${SAB_HEALTH_CHECK:-1}"

# ============================================================================
# JSON Parsing Helpers (Pure Bash)
# ============================================================================

# Extract string field from JSON
# Usage: _sab_extract_field "$json" "queue.status"
_sab_extract_field() {
    local json="$1" field="$2"
    local key="${field##*.}"
    
    # Try Perl regex first (faster and more reliable)
    if grep -P '' /dev/null 2>/dev/null; then
        echo "$json" | grep -oP "\"${key}\"\s*:\s*\"[^\"]*\"" | grep -oP ':"[^"]*"' | sed 's/^:"\(.*\)"$/\1/'
    else
        # Fallback: basic grep
        echo "$json" | grep -o "\"${key}\":\"[^\"]*\"" | sed 's/.*:"\(.*\)".*/\1/'
    fi
}

# Extract numeric field (int or float)
# Usage: _sab_extract_number "$json" "queue.kbpersec"
_sab_extract_number() {
    local json="$1" field="$2"
    local key="${field##*.}"
    
    local num
    if grep -P '' /dev/null 2>/dev/null; then
        num=$(echo "$json" | grep -oP "\"${key}\"\s*:\s*\"?[0-9.]+\"?" | grep -oP '[0-9.]+' | head -1)
    else
        num=$(echo "$json" | grep -o "\"${key}\":\"*[0-9.]*\"*" | grep -o '[0-9.]*' | head -1)
    fi
    
    echo "${num:-0}"
}

# Extract boolean field
# Usage: _sab_extract_bool "$json" "queue.paused"
_sab_extract_bool() {
    local json="$1" field="$2"
    local key="${field##*.}"
    
    if echo "$json" | grep -q "\"${key}\":\s*true"; then
        echo "true"
    else
        echo "false"
    fi
}

# Validate JSON response
_sab_validate_json() {
    local json="$1"
    
    [[ -z "$json" ]] && return 1
    [[ ! "$json" =~ ^\{.*\}$ ]] && return 1
    
    # Check for API error messages
    if echo "$json" | grep -qi "API Key"; then
        [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: SABnzbd API key error: $json" >&2
        return 1
    fi
    
    if echo "$json" | grep -qi '"error"'; then
        [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: SABnzbd API error: $json" >&2
        return 1
    fi
    
    return 0
}

# ============================================================================
# API Communication
# ============================================================================

# Perform curl request with timeout and error handling
_sab_curl() {
    local url="$1"
    local timeout="${2:-${SAB_TIMEOUT_S}}"
    
    CURL_BIN="${CURL_BIN:-$(command -v curl)}"
    
    if [[ "${CURL_INSECURE:-0}" == "1" ]]; then
        "$CURL_BIN" -sS --max-time "$timeout" -k "$url" 2>/dev/null
    else
        "$CURL_BIN" -sS --max-time "$timeout" "$url" 2>/dev/null
    fi
}

# Make API call with retry logic and exponential backoff
# Returns: 0=success (prints response), 1=auth error, 2=network error
_sab_api_call() {
    local url="$1"
    local retries="${SAB_RETRIES}"
    local delay="${SAB_RETRY_DELAY_S}"
    
    for attempt in $(seq 1 $((retries + 1))); do
        local response
        response=$(_sab_curl "$url")
        
        # Check for valid response
        if [[ -n "$response" ]]; then
            # Validate JSON
            if _sab_validate_json "$response"; then
                echo "$response"
                return 0
            else
                # API key error or invalid response - don't retry
                return 1
            fi
        fi
        
        # Network error - retry with exponential backoff
        if [[ $attempt -lt $((retries + 1)) ]]; then
            [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: SABnzbd API call failed, retry $attempt/$retries" >&2
            sleep $((delay * attempt))
        fi
    done
    
    return 2  # All retries exhausted
}

# Health check using version endpoint (no auth required)
_sab_health_check() {
    [[ -z "${SAB_URL:-}" ]] && return 1
    
    local url="${SAB_URL%/}/api?mode=version"
    local response
    
    response=$(_sab_curl "$url" 2)
    [[ -n "$response" ]] && echo "$response" | grep -q "version"
}

# Get queue status (optimized with limit=0)
_sab_get_queue() {
    [[ -z "${SAB_URL:-}" || -z "${SAB_API_KEY:-}" ]] && return 2
    
    local url="${SAB_URL%/}/api?mode=queue&limit=0&output=json&apikey=${SAB_API_KEY}"
    _sab_api_call "$url"
}

# Get history status (check post-processing)
_sab_get_history() {
    [[ -z "${SAB_URL:-}" || -z "${SAB_API_KEY:-}" ]] && return 2
    
    local url="${SAB_URL%/}/api?mode=history&limit=1&output=json&apikey=${SAB_API_KEY}"
    _sab_api_call "$url"
}

# ============================================================================
# Environment Validation
# ============================================================================

_validate_sab_env() {
    # Check curl availability
    CURL_BIN="${CURL_BIN:-$(command -v curl)}"
    if [[ -z "$CURL_BIN" ]] || ! command -v "$CURL_BIN" >/dev/null 2>&1; then
        [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: curl not available" >&2
        return 2
    fi
    
    # Check required variables
    if [[ -z "${SAB_URL:-}" ]]; then
        [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: SAB_URL not set" >&2
        return 2
    fi
    
    if [[ -z "${SAB_API_KEY:-}" ]]; then
        [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: SAB_API_KEY not set" >&2
        return 2
    fi
    
    # Validate URL format
    if [[ ! "$SAB_URL" =~ ^https?:// ]]; then
        [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: SAB_URL invalid format: $SAB_URL" >&2
        return 2
    fi
    
    # Optional: Health check
    if [[ "${SAB_HEALTH_CHECK}" == "1" ]]; then
        if ! _sab_health_check; then
            [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: SABnzbd health check failed" >&2
            return 2
        fi
    fi
    
    return 0
}

# ============================================================================
# Busy Detection Logic
# ============================================================================

# Check if SABnzbd is busy based on queue and history
_sab_is_busy() {
    local queue_json="$1"
    local history_json="$2"
    
    # Extract queue fields
    local status paused kbpersec noofslots mbleft
    status=$(_sab_extract_field "$queue_json" "queue.status")
    paused=$(_sab_extract_bool "$queue_json" "queue.paused")
    kbpersec=$(_sab_extract_number "$queue_json" "queue.kbpersec")
    noofslots=$(_sab_extract_number "$queue_json" "queue.noofslots")
    mbleft=$(_sab_extract_number "$queue_json" "queue.mbleft")
    
    # Debug output
    if [[ "${QUIET_DEBUG:-0}" == "1" ]]; then
        echo "DEBUG: SABnzbd status=$status paused=$paused kbpersec=$kbpersec noofslots=$noofslots mbleft=$mbleft" >&2
    fi
    
    # Criterion 1: Actively downloading or fetching
    if [[ "$status" == "Downloading" || "$status" == "Fetching" ]]; then
        echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} threshold=${SAB_BUSY_THRESHOLD_KBPS}"
        return 0  # BUSY
    fi
    
    # Criterion 2: Download speed exceeds threshold
    local threshold="${SAB_BUSY_THRESHOLD_KBPS}"
    if command -v bc >/dev/null 2>&1; then
        if (( $(echo "$kbpersec >= $threshold" | bc -l 2>/dev/null || echo 0) )); then
            echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} threshold=${threshold}"
            return 0  # BUSY
        fi
    else
        # Fallback: integer comparison (convert to int)
        local kbps_int=${kbpersec%.*}
        kbps_int=${kbps_int:-0}
        if (( kbps_int >= threshold )); then
            echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} threshold=${threshold}"
            return 0  # BUSY
        fi
    fi
    
    # Criterion 3: Jobs in queue AND not paused AND data remaining
    if [[ "$paused" == "false" ]]; then
        if (( noofslots > 0 )); then
            # Check if there's actually data left to download
            if command -v bc >/dev/null 2>&1; then
                if (( $(echo "$mbleft > 0" | bc -l 2>/dev/null || echo 1) )); then
                    echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} threshold=${threshold}"
                    return 0  # BUSY
                fi
            else
                # Conservative: if we can't check mbleft, assume busy if slots > 0
                local mbleft_int=${mbleft%.*}
                mbleft_int=${mbleft_int:-0}
                if (( mbleft_int > 0 )); then
                    echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} threshold=${threshold}"
                    return 0  # BUSY
                fi
            fi
        fi
    fi
    
    # Criterion 4: Post-processing active (if enabled)
    local ppslots=0
    if [[ "${SAB_CHECK_POSTPROC}" == "1" && -n "$history_json" ]]; then
        ppslots=$(_sab_extract_number "$history_json" "history.ppslots")
        
        if (( ppslots > 0 )); then
            echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} ppslots=${ppslots} threshold=${threshold}"
            return 0  # BUSY (post-processing)
        fi
        
        # Check for specific post-processing states
        if echo "$history_json" | grep -Eq '"status":"(Repairing|Extracting|Moving|Running)"'; then
            echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} ppslots=${ppslots} post_processing=active threshold=${threshold}"
            return 0  # BUSY (post-processing)
        fi
    fi
    
    # IDLE
    echo "source=sabnzbd_api status=${status} paused=${paused} kbpersec=${kbpersec} noofslots=${noofslots} mbleft=${mbleft} ppslots=${ppslots} threshold=${threshold}"
    return 1
}

# Main API busy check
_sab_api_busy() {
    # Validate environment
    if ! _validate_sab_env; then
        return 2  # Trigger fallback
    fi
    
    # Get queue status
    local queue_json
    queue_json=$(_sab_get_queue)
    local queue_result=$?
    
    if [[ $queue_result -ne 0 ]]; then
        [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: Failed to get SABnzbd queue status (code: $queue_result)" >&2
        return 2  # Trigger fallback
    fi
    
    if [[ "${QUIET_DEBUG:-0}" == "1" ]]; then
        echo "DEBUG: SABnzbd queue JSON: ${queue_json:0:200}..." >&2
    fi
    
    # Get post-processing status (optional)
    local history_json=""
    if [[ "${SAB_CHECK_POSTPROC}" == "1" ]]; then
        if ! history_json=$(_sab_get_history); then
            # Don't fail if history fails, just skip PP check
            [[ "${QUIET_DEBUG:-0}" == "1" ]] && echo "DEBUG: Failed to get SABnzbd history, skipping post-processing check" >&2
            history_json=""
        elif [[ "${QUIET_DEBUG:-0}" == "1" ]]; then
            echo "DEBUG: SABnzbd history JSON: ${history_json:0:200}..." >&2
        fi
    fi
    
    # Check if busy
    _sab_is_busy "$queue_json" "$history_json"
}

# ============================================================================
# Public API
# ============================================================================

check_busy() {
    local container="$1"
    
    # Try API-based detection
    if _sab_api_busy; then
        return 0  # BUSY
    else
        local api_result=$?
        if [[ $api_result -eq 2 ]]; then
            # API unavailable/failed - fall back to generic
            check_busy_generic "$container"
            return $?
        else
            return 1  # IDLE
        fi
    fi
}
