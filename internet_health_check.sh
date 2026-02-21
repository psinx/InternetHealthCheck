#!/usr/bin/env bash

# internet_health_check.sh
# Location: $HOME/InternetHealthCheck/internet_health_check.sh
# Logs:     $HOME/InternetHealthCheck/logs/
# Purpose:  Monitor internet connectivity and DNS chain health

# Configuration
readonly PING_TARGET="1.1.1.1"
readonly DNS_TEST_DOMAIN="cloudflare.com"
readonly PING_TIMEOUT=5
readonly PING_COUNT=4

readonly LOG_DIR="$HOME/InternetHealthCheck/logs"
readonly TAG="[INTERNET-HEALTH-CHECK]"

readonly PIHOLE_PORT="53"
readonly DNSCRYPT_PORT="5053"

readonly MAX_LOG_SIZE=$((2 * 1024 * 1024))   # 2 MB
readonly MAX_ROTATIONS=7

# Log settings (can be overridden via --log-file flag)
LOG_FILE=""
LOG_TO_FILE=false
REDUCE_DISK_WEAR=false

# Initialize log directory
mkdir -p "$LOG_DIR" 2>/dev/null

#=============================================================================
# Logging functions
#=============================================================================

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="$timestamp ${TAG} $1"
    
    if [[ "$LOG_TO_FILE" == "true" && -n "$LOG_FILE" ]]; then
        echo "$message" >> "$LOG_FILE"
    else
        echo "$message" >&2
    fi
}

should_log_ok() {
    local interface=$1
    
    # If disk wear reduction is disabled, always log
    [[ "$REDUCE_DISK_WEAR" != "true" ]] && return 0
    
    # If not logging to file, always log
    [[ "$LOG_TO_FILE" != "true" ]] && return 0
    
    # If log file doesn't exist, log it
    [[ ! -f "$LOG_FILE" ]] && return 0
    
    # Get log file's modification time
    local log_mod_time
    log_mod_time=$(stat -c %Y "$LOG_FILE" 2>/dev/null) || log_mod_time=0
    local current_time
    current_time=$(date +%s)
    local diff=$(( current_time - log_mod_time ))
    local hours_24=$(( 24 * 60 * 60 ))
    
    # If more than 24 hours since last write, always log
    (( diff >= hours_24 )) && return 0
    
    # Find the LAST entry (any status) for THIS interface to detect state changes
    local last_entry
    last_entry=$(grep "\[$interface\]" "$LOG_FILE" 2>/dev/null | tail -1)
    
    # If no previous entry exists, log it
    [[ -z "$last_entry" ]] && return 0
    
    # If the last entry is DOWN or contains error markers, state changed - log it
    if [[ "$last_entry" =~ DOWN ]] || [[ "$last_entry" =~ Issue ]] || [[ "$last_entry" =~ Test:\ Fail ]]; then
        return 0  # Log it - state changed from error to OK
    fi
    
    # Last entry must be OK to consider suppressing
    if [[ ! "$last_entry" =~ OK ]]; then
        return 0  # Log it - state changed
    fi
    
    # Extract timestamp (format: 2026-02-17 12:25:04)
    local last_time
    last_time=$(echo "$last_entry" | awk '{print $1 " " $2}')
    
    # Convert to Unix time
    local last_sec
    last_sec=$(date -d "$last_time" +%s 2>/dev/null) || last_sec=0
    
    # Check if within 60 seconds of log file's mod time
    local time_diff=$(( last_sec > log_mod_time ? last_sec - log_mod_time : log_mod_time - last_sec ))
    
    # If recent OK entry from last run, suppress logging (no write needed)
    if (( time_diff <= 60 )); then
        return 1  # Suppress
    fi
    
    # Otherwise log it
    return 0
}

rotate_log() {
    [[ "$LOG_TO_FILE" != "true" || -z "$LOG_FILE" ]] && return
    
    local size
    size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
    
    if (( size > MAX_LOG_SIZE )); then
        # Rotate existing numbered files
        for ((i=MAX_ROTATIONS; i>=1; i--)); do
            local old="$LOG_FILE.$i"
            local new="$LOG_FILE.$((i+1))"
            [ -f "$old" ] && mv -f "$old" "$new" 2>/dev/null
        done
        
        # Compress and move current log
        gzip -f -c "$LOG_FILE" > "$LOG_FILE.1.gz" 2>/dev/null
        : > "$LOG_FILE"
        log "LOG ROTATED"
    fi
}

#=============================================================================
# Connectivity check
#=============================================================================

check_connectivity() {
    local interface=$1
    if ping -I "$interface" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1; then
        echo "OK"
    else
        log "[$interface] Test: Fail during Ping - $PING_TARGET did not respond (connectivity outage)"
        echo "DOWN"
    fi
}

#=============================================================================
# DNS chain checks
#=============================================================================

check_pihole_dns() {
    local interface=$1
    local local_ip
    local_ip=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [[ -z "$local_ip" ]] && return 1
    dig +short "$DNS_TEST_DOMAIN" @127.0.0.1 -b "$local_ip" >/dev/null 2>&1
}

check_dnscrypt_dns() {
    local interface=$1
    local local_ip
    local_ip=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [[ -z "$local_ip" ]] && return 1
    dig +short "$DNS_TEST_DOMAIN" @127.0.0.1 -p "$DNSCRYPT_PORT" -b "$local_ip" >/dev/null 2>&1
}

check_cloudflare_dns() {
    local interface=$1
    local local_ip
    local_ip=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [[ -z "$local_ip" ]] && return 1
    dig +short "$DNS_TEST_DOMAIN" @1.1.1.1 -b "$local_ip" >/dev/null 2>&1
}

log_dns_results() {
    local interface=$1 pihole_ok=$2 dnscrypt_ok=$3 cloudflare_ok=$4
    
    # Only log detailed results if there's a problem
    if [[ "$pihole_ok" == "false" || "$dnscrypt_ok" == "false" || "$cloudflare_ok" == "false" ]]; then
        [[ "$pihole_ok" == "false" ]] && log "[$interface] Test: Fail via Pi-hole (127.0.0.1:53)"
        [[ "$pihole_ok" == "true" ]] && log "[$interface] Test: Pass via Pi-hole (127.0.0.1:53)"
        [[ "$dnscrypt_ok" == "false" ]] && log "[$interface] Test: Fail via dnscrypt-proxy (127.0.0.1:${DNSCRYPT_PORT})"
        [[ "$dnscrypt_ok" == "true" ]] && log "[$interface] Test: Pass via dnscrypt-proxy (127.0.0.1:${DNSCRYPT_PORT})"
        [[ "$cloudflare_ok" == "false" ]] && log "[$interface] Test: Fail via Cloudflare public (1.1.1.1:53)"
        [[ "$cloudflare_ok" == "true" ]] && log "[$interface] Test: Pass via Cloudflare public (1.1.1.1:53)"
    fi
}

determine_failure_point() {
    local pihole_ok=$1 dnscrypt_ok=$2 cloudflare_ok=$3
    
    if [[ "$pihole_ok" == "false" && "$dnscrypt_ok" == "true" ]]; then
        echo "Pi-hole"
    elif [[ "$dnscrypt_ok" == "false" && "$cloudflare_ok" == "true" ]]; then
        echo "dnscrypt-proxy"
    elif [[ "$cloudflare_ok" == "false" ]]; then
        echo "Cloudflare"
    else
        echo ""
    fi
}

log_dns_diagnostics() {
    local interface=$1 failure_point=$2
    
    [[ -z "$failure_point" ]] && return
    
    case "$failure_point" in
        "Pi-hole")
            log "[$interface] Issue: Pi-hole × dnscrypt-proxy → Cloudflare"
            log "[$interface] Issue: Pi-hole forwarding"
            ;;
        "dnscrypt-proxy")
            log "[$interface] Issue: Pi-hole → dnscrypt-proxy × Cloudflare"
            log "[$interface] Issue: dnscrypt-proxy DoH to Cloudflare"
            ;;
        "Cloudflare")
            log "[$interface] Issue: Pi-hole → dnscrypt-proxy × Cloudflare"
            log "[$interface] Issue: upstream / Cloudflare connectivity"
            ;;
    esac
}

check_dns_chain() {
    local interface=$1
    local pihole_ok dnscrypt_ok cloudflare_ok dns_ok failure_point
    
    pihole_ok=false; dnscrypt_ok=false; cloudflare_ok=false
    
    # Test each DNS endpoint
    check_pihole_dns "$interface" && pihole_ok=true
    check_dnscrypt_dns "$interface" && dnscrypt_ok=true
    check_cloudflare_dns "$interface" && cloudflare_ok=true
    
    # Determine overall DNS status
    [[ "$pihole_ok" == "true" && "$dnscrypt_ok" == "true" && "$cloudflare_ok" == "true" ]] && dns_ok=true || dns_ok=false
    
    # If there's an error, log DOWN at start of block
    if [[ "$dns_ok" == "false" ]]; then
        log "[$interface] DOWN"
    fi
    
    # Log pass results if any failure occurred
    log_dns_results "$interface" "$pihole_ok" "$dnscrypt_ok" "$cloudflare_ok"
    
    # Identify and log break point
    failure_point=$(determine_failure_point "$pihole_ok" "$dnscrypt_ok" "$cloudflare_ok")
    log_dns_diagnostics "$interface" "$failure_point"
    
    # If there's an error, log DOWN at end of block
    if [[ "$dns_ok" == "false" ]]; then
        log "[$interface] Issue: DNS issue detected. Connectivity still OK"
        log "[$interface] DOWN"
    fi
    
    echo "$dns_ok"
}

#=============================================================================
# Status reporting
#=============================================================================

determine_current_status() {
    local interface=$1 connectivity=$2 dns_ok=$3
    
    if [[ "$connectivity" == "DOWN" ]]; then
        log "[$interface] DOWN - CONNECTIVITY OUTAGE detected"
    else
        if [[ "$dns_ok" == "true" ]]; then
            # Only log OK if disk wear reduction allows it
            if should_log_ok "$interface"; then
                log "[$interface] OK"
            fi
        fi
    fi
}

#=============================================================================
# Usage and argument parsing
#=============================================================================

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --log-file FILE       Write logs to FILE instead of stdout
  --reduce-disk-wear    Reduce log writes: skip OK logs if < 24h since last entry
                        (failures are always logged immediately)
  -h, --help            Show this help message

Examples:
  # Print to stdout (default)
  ./internet_health_check.sh
  
  # Write to log file
  ./internet_health_check.sh --log-file logs/internet_health.log
  
  # Reduce disk wear on RPi (with file logging)
  ./internet_health_check.sh --log-file logs/internet_health.log --reduce-disk-wear
EOF
}

#=============================================================================
# Main execution
#=============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --log-file)
                LOG_FILE="$2"
                LOG_TO_FILE=true
                mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
                shift 2
                ;;
            --reduce-disk-wear)
                REDUCE_DISK_WEAR=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done
    
    rotate_log
    
    # Define interfaces: wired first, then wireless
    local interfaces=("eth0" "wlan0")
    
    for interface in "${interfaces[@]}"; do
        # Check if interface exists
        if ! ip link show "$interface" >/dev/null 2>&1; then
            continue
        fi
        
        # Check connectivity first
        connectivity=$(check_connectivity "$interface")
        
        # Check DNS chain only if connectivity is OK
        local dns_ok="true"
        if [[ "$connectivity" == "OK" ]]; then
            dns_ok=$(check_dns_chain "$interface")
        fi
        
        # Report current status
        determine_current_status "$interface" "$connectivity" "$dns_ok" >/dev/null
    done
}

main "$@"