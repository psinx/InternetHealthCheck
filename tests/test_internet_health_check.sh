#!/usr/bin/env bash

# test_internet_health_check.sh - Functional test suite
# Tests the script for correct behavior

set -euo pipefail

# Configuration
TEST_HOME="/tmp/healthcheck_test"
TEST_LOG_FILE="$TEST_HOME/InternetHealthCheck/logs/internet_health.log"

TESTS_PASSED=0
TESTS_FAILED=0

# Helpers
setup_test_env() {
    rm -rf "$TEST_HOME"
    mkdir -p "$TEST_HOME/InternetHealthCheck/logs"
}

cleanup_test_env() {
    rm -rf "$TEST_HOME"
}

log_contains() {
    [ -f "$TEST_LOG_FILE" ] && grep -q "$1" "$TEST_LOG_FILE"
}

count_log_lines() {
    [ -f "$TEST_LOG_FILE" ] && wc -l < "$TEST_LOG_FILE" || echo 0
}

assert_pass() {
    local msg="$1"
    echo "  ✓ $msg"
    ((TESTS_PASSED++)) || true
}

assert_fail() {
    local msg="$1"
    echo "  ✗ $msg"
    ((TESTS_FAILED++)) || true
    if [ -f "$TEST_LOG_FILE" ]; then
        echo "    Log contents:"
        sed 's/^/      /' "$TEST_LOG_FILE" 2>/dev/null || echo "      (can't read log)"
    fi
}

run_with_mocks() {
    local ping_result=$1 pihole_result=$2 dnscrypt_result=$3 cloudflare_result=$4
    local reset_env=${5:-true}  # Option to preserve environment
    
    # Create test environment with proper directory structure (only if requested)
    if [[ "$reset_env" == "true" ]]; then
        rm -rf "$TEST_HOME"
        mkdir -p "$TEST_HOME/InternetHealthCheck/logs"
    fi
    
    # Create mock wrapper
    cat > /tmp/run_test.sh << 'TESTEOF'
#!/bin/bash

# Force Linux code paths so ip/ping/dig mocks work on both Linux and macOS
OS_TYPE=linux
export OS_TYPE

HOME="$TEST_HOME"
export HOME

# Override ip
ip() {
    # Handle: ip -4 addr show up  (used by get_active_interfaces)
    if [[ "$*" =~ "-4" && "$*" =~ "addr show up" ]]; then
        echo "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
        echo "    inet 192.168.1.100/24 brd 192.168.1.255 scope global eth0"
        echo "3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
        echo "    inet 192.168.1.101/24 brd 192.168.1.255 scope global wlan0"
        return 0
    elif [[ "$*" =~ "addr show" ]]; then
        # Return mock IP address for interface
        if [[ "$*" =~ "eth0" ]]; then
            echo "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
            echo "    inet 192.168.1.100/24 brd 192.168.1.255 scope global eth0"
        elif [[ "$*" =~ "wlan0" ]]; then
            echo "3: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500"
            echo "    inet 192.168.1.101/24 brd 192.168.1.255 scope global wlan0"
        fi
        return 0
    elif [[ "$*" =~ "link show" ]]; then
        # For interface checks
        return 0
    fi
    return 1
}

# Override ping
ping() {
    (( PING_MOCK == 0 )) && return 0 || return 1
}

# Override dig
dig() {
    if [[ "$*" =~ @127\.0\.0\.1 ]]; then
        if [[ "$*" =~ 5053 ]]; then
            # dnscrypt check (port 5053)
            (( DNSCRYPT_MOCK == 0 )) && return 0 || return 1
        else
            # pihole check (port 53)
            (( PIHOLE_MOCK == 0 )) && return 0 || return 1
        fi
    elif [[ "$*" =~ @1\.1\.1\.1 ]]; then
        # cloudflare check
        (( CLOUDFLARE_MOCK == 0 )) && return 0 || return 1
    fi
    return 1
}

export -f ip ping dig

# Source and run the script with log file flag
source "$SCRIPT_PATH" --log-file "$TEST_HOME/InternetHealthCheck/logs/internet_health.log"
TESTEOF
    
    chmod +x /tmp/run_test.sh
    
    # Run with mocked values
    OS_TYPE=linux \
    PING_MOCK="$ping_result" \
    PIHOLE_MOCK="$pihole_result" \
    DNSCRYPT_MOCK="$dnscrypt_result" \
    CLOUDFLARE_MOCK="$cloudflare_result" \
    TEST_HOME="$TEST_HOME" \
    SCRIPT_PATH="$SCRIPT_PATH" \
    bash /tmp/run_test.sh 2>/dev/null || true
    
    # Update paths for log checking
    TEST_LOG_FILE="$TEST_HOME/InternetHealthCheck/logs/internet_health.log"
}

#=============================================================================
# Test Cases
#=============================================================================

test_1_all_ok() {
    echo "TEST 1: All systems OK"
    setup_test_env
    run_with_mocks 0 0 0 0
    
    if log_contains "OK" && ! log_contains "ALERT"; then
        assert_pass "System reports OK"
    else
        assert_fail "System should report OK"
    fi
    cleanup_test_env
}

test_2_ping_fail() {
    echo "TEST 2: Connectivity DOWN"
    setup_test_env
    run_with_mocks 1 0 0 0
    
    if log_contains "Fail during Ping"; then
        assert_pass "Ping failure detected"
    else
        assert_fail "Ping failure not detected"
    fi
    
    if log_contains "Test: Fail"; then
        assert_pass "Alert logged for outage"
    else
        assert_fail "Alert should be logged for outage"
    fi
    cleanup_test_env
}

test_3_repeated_ok() {
    echo "TEST 3: Repeated OK state checks"
    setup_test_env
    run_with_mocks 0 0 0 0
    run_with_mocks 0 0 0 0 false
    
    local count=$(count_log_lines)
    if [ "$count" -eq 4 ]; then
        assert_pass "Multiple OK entries logged (2 per run for eth0+wlan0)"
    else
        assert_fail "Should have 4 log entries, got $count"
    fi
    cleanup_test_env
}

test_4_pihole_dns_fail() {
    echo "TEST 4: Pi-hole DNS fails"
    setup_test_env
    run_with_mocks 0 1 0 0
    
    if log_contains "Test: Fail via Pi-hole"; then
        assert_pass "Pi-hole failure detected"
    else
        assert_fail "Pi-hole failure not detected"
    fi
    
    if log_contains "Issue:" && log_contains "×"; then
        assert_pass "Diagnostic info logged"
    else
        assert_fail "Diagnostic info missing"
    fi
    cleanup_test_env
}

test_5_dnscrypt_dns_fail() {
    echo "TEST 5: dnscrypt-proxy DNS fails"
    setup_test_env
    run_with_mocks 0 0 1 0
    
    if log_contains "Test: Fail via dnscrypt-proxy"; then
        assert_pass "dnscrypt failure detected"
    else
        assert_fail "dnscrypt failure not detected"
    fi
    cleanup_test_env
}

test_6_cloudflare_dns_fail() {
    echo "TEST 6: Cloudflare DNS fails"
    setup_test_env
    run_with_mocks 0 0 0 1
    
    if log_contains "Test: Fail via Cloudflare"; then
        assert_pass "Cloudflare failure detected"
    else
        assert_fail "Cloudflare failure not detected"
    fi
    
    if log_contains "Issue:" && log_contains "×"; then
        assert_pass "Correct chain notation for Cloudflare failure"
    else
        assert_fail "Cloudflare chain notation incorrect"
    fi
    cleanup_test_env
}

test_7_all_dns_fail() {
    echo "TEST 7: All DNS services fail"
    setup_test_env
    run_with_mocks 0 1 1 1
    
    if log_contains "Test: Fail via Pi-hole" && \
       log_contains "Test: Fail via dnscrypt-proxy" && \
       log_contains "Test: Fail via Cloudflare"; then
        assert_pass "All DNS problems detected"
    else
        assert_fail "Not all DNS problems logged"
    fi
    cleanup_test_env
}

test_8_dns_issue_with_connectivity() {
    echo "TEST 8: DNS issue with OK connectivity"
    setup_test_env
    run_with_mocks 0 1 1 1
    
    if log_contains "Issue: DNS issue detected"; then
        assert_pass "DNS issue logged"
    else
        assert_fail "DNS issue not logged"
    fi
    cleanup_test_env
}

test_9_pihole_and_dnscrypt_fail() {
    echo "TEST 9: Pi-hole and dnscrypt fail, Cloudflare OK"
    setup_test_env
    run_with_mocks 0 1 1 0
    
    if log_contains "Test: Fail via Pi-hole" && \
       log_contains "Test: Fail via dnscrypt-proxy" && \
       log_contains "Test: Pass via Cloudflare"; then
        assert_pass "Partial DNS chain failure detected correctly"
    else
        assert_fail "Partial DNS chain failure not detected"
    fi
    cleanup_test_env
}

test_10_should_log_ok_scenarios() {
    echo "TEST 10: should_log_ok() function - multiple scenarios"
    setup_test_env
    
    # Test 1: Disabled reduction should always return true
    cat > /tmp/test_scenarios.sh << 'TESTEOF'
#!/bin/bash
OS_TYPE=linux
export OS_TYPE
source "$SCRIPT_PATH"

# Scenario 1: Disk wear reduction disabled
REDUCE_DISK_WEAR=false
LOG_TO_FILE=true
LOG_FILE="$TEST_LOG_FILE"
if should_log_ok eth0; then
    echo "scenario1=pass"
else
    echo "scenario1=fail"
fi

# Scenario 2: Not logging to file
REDUCE_DISK_WEAR=true
LOG_TO_FILE=false
if should_log_ok eth0; then
    echo "scenario2=pass"
else
    echo "scenario2=fail"
fi

# Scenario 3: Log file doesn't exist
REDUCE_DISK_WEAR=true
LOG_TO_FILE=true
LOG_FILE="/nonexistent/file.log"
if should_log_ok eth0; then
    echo "scenario3=pass"
else
    echo "scenario3=fail"
fi

# Scenario 4: Old log file (>24h)
REDUCE_DISK_WEAR=true
LOG_TO_FILE=true
LOG_FILE="$TEST_LOG_FILE"
mkdir -p "$(dirname "$TEST_LOG_FILE")"
echo "2026-01-01 10:00:00 [INTERNET-HEALTH-CHECK] [eth0] OK" > "$TEST_LOG_FILE"
if should_log_ok eth0; then
    echo "scenario4=pass"
else
    echo "scenario4=fail"
fi
TESTEOF
    chmod +x /tmp/test_scenarios.sh
    
    local results=$(SCRIPT_PATH="$SCRIPT_PATH" TEST_LOG_FILE="$TEST_LOG_FILE" bash /tmp/test_scenarios.sh 2>/dev/null)
    
    if echo "$results" | grep -q "scenario1=pass" && \
       echo "$results" | grep -q "scenario2=pass" && \
       echo "$results" | grep -q "scenario3=pass" && \
       echo "$results" | grep -q "scenario4=pass"; then
        assert_pass "should_log_ok handles all scenarios correctly"
    else
        assert_fail "should_log_ok scenario test failed"
    fi
    cleanup_test_env
}

test_11_should_log_ok_recent_suppression() {
    echo "TEST 11: should_log_ok() suppresses recent OK entries"
    setup_test_env
    
    mkdir -p "$(dirname "$TEST_LOG_FILE")"
    local recent_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$recent_time [INTERNET-HEALTH-CHECK] [eth0] OK" > "$TEST_LOG_FILE"
    
    cat > /tmp/test_recent.sh << 'TESTEOF'
#!/bin/bash
OS_TYPE=linux
export OS_TYPE
source "$SCRIPT_PATH"
REDUCE_DISK_WEAR=true
LOG_TO_FILE=true
LOG_FILE="$TEST_LOG_FILE"
sleep 1
if should_log_ok eth0; then
    echo "suppress=false"
else
    echo "suppress=true"
fi
TESTEOF
    chmod +x /tmp/test_recent.sh
    
    local result=$(SCRIPT_PATH="$SCRIPT_PATH" TEST_LOG_FILE="$TEST_LOG_FILE" bash /tmp/test_recent.sh 2>/dev/null)
    if [[ "$result" == "suppress=true" ]]; then
        assert_pass "should_log_ok suppresses recent OK entries"
    else
        assert_fail "should_log_ok should suppress recent OK, got: $result"
    fi
    cleanup_test_env
}

test_12_should_log_ok_error_state_change() {
    echo "TEST 12: should_log_ok() logs on error-to-OK state change"
    setup_test_env
    
    mkdir -p "$(dirname "$TEST_LOG_FILE")"
    local recent_time=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$recent_time [INTERNET-HEALTH-CHECK] [eth0] DOWN" > "$TEST_LOG_FILE"
    
    cat > /tmp/test_error.sh << 'TESTEOF'
#!/bin/bash
OS_TYPE=linux
export OS_TYPE
source "$SCRIPT_PATH"
REDUCE_DISK_WEAR=true
LOG_TO_FILE=true
LOG_FILE="$TEST_LOG_FILE"
if should_log_ok eth0; then
    echo "suppress=false"
else
    echo "suppress=true"
fi
TESTEOF
    chmod +x /tmp/test_error.sh
    
    local result=$(SCRIPT_PATH="$SCRIPT_PATH" TEST_LOG_FILE="$TEST_LOG_FILE" bash /tmp/test_error.sh 2>/dev/null)
    if [[ "$result" == "suppress=false" ]]; then
        assert_pass "should_log_ok logs when state changed from error"
    else
        assert_fail "should_log_ok should log after error, got: $result"
    fi
    cleanup_test_env
}

test_13_rotate_log_no_rotation() {
    echo "TEST 13: rotate_log() doesn't rotate small files"
    setup_test_env
    
    mkdir -p "$(dirname "$TEST_LOG_FILE")"
    echo "Small log file" > "$TEST_LOG_FILE"
    
    cat > /tmp/test_rotate.sh << 'TESTEOF'
#!/bin/bash
OS_TYPE=linux
export OS_TYPE
source "$SCRIPT_PATH"
LOG_TO_FILE=true
LOG_FILE="$TEST_LOG_FILE"
rotate_log
# Check if rotated file exists
if [ -f "$TEST_LOG_FILE.1.gz" ]; then
    echo "rotated=true"
else
    echo "rotated=false"
fi
TESTEOF
    chmod +x /tmp/test_rotate.sh
    
    local result=$(SCRIPT_PATH="$SCRIPT_PATH" TEST_LOG_FILE="$TEST_LOG_FILE" bash /tmp/test_rotate.sh 2>/dev/null)
    if [[ "$result" == "rotated=false" ]]; then
        assert_pass "rotate_log doesn't rotate small files"
    else
        assert_fail "Small files should not rotate, got: $result"
    fi
    cleanup_test_env
}

test_14_rotate_log_large_file() {
    echo "TEST 14: rotate_log() rotates files exceeding 2MB"
    setup_test_env
    
    mkdir -p "$(dirname "$TEST_LOG_FILE")"
    
    # Create a file larger than 2MB with content
    # Each line is ~52 bytes, so 42000 lines gives us ~2.1MB
    {
        for ((i=0; i<42000; i++)); do
            echo "2026-02-20 15:55:08 [INTERNET-HEALTH-CHECK] [eth0] OK"
        done
    } > "$TEST_LOG_FILE" &
    wait
    
    # Verify file size before rotation
    local filesize=$(stat -c%s "$TEST_LOG_FILE" 2>/dev/null || echo 0)
    
    cat > /tmp/test_rotate2.sh << 'TESTEOF'
#!/bin/bash
OS_TYPE=linux
export OS_TYPE
source "$SCRIPT_PATH"
LOG_TO_FILE=true
LOG_FILE="$TEST_LOG_FILE"
rotate_log
# Check if rotated files exist
if [ -f "$TEST_LOG_FILE.1.gz" ] || [ -f "$TEST_LOG_FILE.1" ]; then
    echo "rotated=true"
else
    echo "rotated=false"
fi
# Also check file size after rotation
if [ -s "$TEST_LOG_FILE" ]; then
    echo "new_file_exists=true"
else
    echo "new_file_exists=false"
fi
TESTEOF
    chmod +x /tmp/test_rotate2.sh
    
    local result=$(SCRIPT_PATH="$SCRIPT_PATH" TEST_LOG_FILE="$TEST_LOG_FILE" bash /tmp/test_rotate2.sh 2>/dev/null)
    if echo "$result" | grep -q "rotated=true"; then
        assert_pass "rotate_log rotates files exceeding 2MB"
    else
        assert_fail "Large files should be rotated (file was $filesize bytes), got: $result"
    fi
    cleanup_test_env
}

test_15_usage_output() {
    echo "TEST 15: usage() displays help message"
    
    cat > /tmp/test_usage.sh << 'TESTEOF'
#!/bin/bash
OS_TYPE=linux
export OS_TYPE
source "$SCRIPT_PATH"
usage 2>&1 | grep -q "Usage:" && echo "has_usage=true" || echo "has_usage=false"
usage 2>&1 | grep -q "\--log-file" && echo "has_log_file=true" || echo "has_log_file=false"
TESTEOF
    chmod +x /tmp/test_usage.sh
    
    local usage_result=$(SCRIPT_PATH="$SCRIPT_PATH" bash /tmp/test_usage.sh 2>/dev/null | grep "has_usage")
    local logfile_result=$(SCRIPT_PATH="$SCRIPT_PATH" bash /tmp/test_usage.sh 2>/dev/null | grep "has_log_file")
    
    if [[ "$usage_result" == "has_usage=true" && "$logfile_result" == "has_log_file=true" ]]; then
        assert_pass "usage() outputs correct help message"
    else
        assert_fail "usage() missing help content"
    fi
}

#=============================================================================
# Main
#=============================================================================

main() {
    local script_arg="${1:-internet_health_check.sh}"
    
    # Find the script relative to this test script's directory
    local test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local parent_dir="$(dirname "$test_dir")"
    
    if [ -d "$script_arg" ]; then
        export SCRIPT_PATH="$script_arg/internet_health_check.sh"
    elif [ -f "$script_arg" ]; then
        export SCRIPT_PATH="$script_arg"
    elif [ -f "$parent_dir/$script_arg" ]; then
        export SCRIPT_PATH="$parent_dir/$script_arg"
    else
        export SCRIPT_PATH="$script_arg"
    fi
    
    if [ ! -f "$SCRIPT_PATH" ]; then
        echo "Error: Script not found at $SCRIPT_PATH"
        exit 1
    fi
    
    echo "=========================================="
    echo "Internet Health Check - Stateless Monitoring Test Suite"
    echo "Script: $SCRIPT_PATH"
    echo "=========================================="
    echo ""
    
    test_1_all_ok
    echo ""
    test_2_ping_fail
    echo ""
    test_3_repeated_ok
    echo ""
    test_4_pihole_dns_fail
    echo ""
    test_5_dnscrypt_dns_fail
    echo ""
    test_6_cloudflare_dns_fail
    echo ""
    test_7_all_dns_fail
    echo ""
    test_8_dns_issue_with_connectivity
    echo ""
    test_9_pihole_and_dnscrypt_fail
    echo ""
    test_10_should_log_ok_scenarios
    echo ""
    test_11_should_log_ok_recent_suppression
    echo ""
    test_12_should_log_ok_error_state_change
    echo ""
    test_13_rotate_log_no_rotation
    echo ""
    test_14_rotate_log_large_file
    echo ""
    test_15_usage_output
    
    echo ""
    echo "=========================================="
    echo "Results: $TESTS_PASSED passed, $TESTS_FAILED failed"
    echo "=========================================="
    
    if [ $TESTS_FAILED -eq 0 ]; then
        echo "✓ All tests passed!"
        exit 0
    else
        echo "✗ Some tests failed"
        exit 1
    fi
}

main "$@"
