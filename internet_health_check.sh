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
readonly LOG_FILE="$LOG_DIR/internet_health.log"
readonly STATE_FILE="$LOG_DIR/last_status"
readonly TAG="[HEALTH-CHECK]"

readonly PIHOLE_PORT="53"
readonly DNSCRYPT_PORT="5053"

readonly MAX_LOG_SIZE=$((2 * 1024 * 1024))   # 2 MB
readonly MAX_ROTATIONS=7

# Initialize log directory
mkdir -p "$LOG_DIR" 2>/dev/null

#=============================================================================
# Logging functions
#=============================================================================

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') ${TAG} $1" >> "$LOG_FILE"
}

rotate_log() {
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
    if ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" >/dev/null 2>&1; then
        echo "OK"
    else
        log "ALERT - PING FAIL: $PING_TARGET did not respond (connectivity outage)"
        echo "DOWN"
    fi
}

#=============================================================================
# DNS chain checks
#=============================================================================

check_pihole_dns() {
    dig +short "$DNS_TEST_DOMAIN" @127.0.0.1 >/dev/null 2>&1
}

check_dnscrypt_dns() {
    dig +short "$DNS_TEST_DOMAIN" @127.0.0.1 -p "$DNSCRYPT_PORT" >/dev/null 2>&1
}

check_cloudflare_dns() {
    dig +short "$DNS_TEST_DOMAIN" @1.1.1.1 >/dev/null 2>&1
}

log_dns_results() {
    local pihole_ok=$1 dnscrypt_ok=$2 cloudflare_ok=$3
    
    # Only log detailed results if there's a problem
    if [[ "$pihole_ok" == "false" || "$dnscrypt_ok" == "false" || "$cloudflare_ok" == "false" ]]; then
        [[ "$pihole_ok" == "false" ]] && log "Test: Fail via Pi-hole (127.0.0.1:53)"
        [[ "$pihole_ok" == "true" ]] && log "Test: Pass via Pi-hole (127.0.0.1:53)"
        [[ "$dnscrypt_ok" == "false" ]] && log "Test: Fail via dnscrypt-proxy (127.0.0.1:${DNSCRYPT_PORT})"
        [[ "$dnscrypt_ok" == "true" ]] && log "Test: Pass via dnscrypt-proxy (127.0.0.1:${DNSCRYPT_PORT})"
        [[ "$cloudflare_ok" == "false" ]] && log "Test: Fail via Cloudflare public (1.1.1.1:53)"
        [[ "$cloudflare_ok" == "true" ]] && log "Test: Pass via Cloudflare public (1.1.1.1:53)"
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
    local failure_point=$1
    
    [[ -z "$failure_point" ]] && return
    
    case "$failure_point" in
        "Pi-hole")
            log "Issue: Pi-hole × dnscrypt-proxy → Cloudflare"
            log "Issue: Pi-hole forwarding"
            ;;
        "dnscrypt-proxy")
            log "Issue: Pi-hole → dnscrypt-proxy × Cloudflare"
            log "Issue: dnscrypt-proxy DoH to Cloudflare"
            ;;
        "Cloudflare")
            log "Issue: Pi-hole → dnscrypt-proxy × Cloudflare"
            log "Issue: upstream / Cloudflare connectivity"
            ;;
    esac
}

check_dns_chain() {
    local pihole_ok dnscrypt_ok cloudflare_ok dns_ok failure_point
    
    pihole_ok=false; dnscrypt_ok=false; cloudflare_ok=false
    
    # Test each DNS endpoint
    check_pihole_dns && pihole_ok=true || log "DOWN"
    check_dnscrypt_dns && dnscrypt_ok=true || log "DOWN"
    check_cloudflare_dns && cloudflare_ok=true || log "DOWN"
    
    # Determine overall DNS status
    [[ "$pihole_ok" == "true" && "$dnscrypt_ok" == "true" && "$cloudflare_ok" == "true" ]] && dns_ok=true || dns_ok=false
    
    # Log pass results if any failure occurred
    log_dns_results "$pihole_ok" "$dnscrypt_ok" "$cloudflare_ok"
    
    # Identify and log break point
    failure_point=$(determine_failure_point "$pihole_ok" "$dnscrypt_ok" "$cloudflare_ok")
    log_dns_diagnostics "$failure_point"
    
    echo "$dns_ok"
}

#=============================================================================
# State management
#=============================================================================

get_previous_status() {
    cat "$STATE_FILE" 2>/dev/null || echo "OK"
}

save_status() {
    echo "$1" > "$STATE_FILE"
}

determine_current_status() {
    local connectivity=$1 dns_ok=$2 previous_status=$3
    
    if [[ "$connectivity" == "DOWN" ]]; then
        if [[ "$previous_status" != "CONNECTIVITY_DOWN" ]]; then
            log "ALERT - CONNECTIVITY OUTAGE detected"
        fi
        echo "CONNECTIVITY_DOWN"
    elif [[ "$previous_status" == "CONNECTIVITY_DOWN" ]]; then
        log "RECOVERED - Connectivity restored"
        echo "OK"
    else
        if [[ "$dns_ok" == "true" ]]; then
            log "OK"
            echo "OK"
        else
            log "Issue: DNS issue detected. Connectivity still OK"
            log "DOWN"
            echo "DNS_ISSUE"
        fi
    fi
}

#=============================================================================
# Main execution
#=============================================================================

main() {
    rotate_log
    
    # Check connectivity first
    connectivity=$(check_connectivity)
    
    # Check DNS chain only if connectivity is OK
    local dns_ok="true"
    if [[ "$connectivity" == "OK" ]]; then
        dns_ok=$(check_dns_chain)
    fi
    
    # Determine status and save state
    previous_status=$(get_previous_status)
    current_status=$(determine_current_status "$connectivity" "$dns_ok" "$previous_status")
    save_status "$current_status"
}

main "$@"