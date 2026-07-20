#!/usr/bin/env bash

# lib/network.sh - Network connectivity and DNS chain checks

# Resolve local IP assigned to a specific interface
get_interface_ip() {
    local interface=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ifconfig "$interface" 2>/dev/null | grep 'inet ' | awk '{print $2}' | head -n1
    else
        ip -4 addr show "$interface" 2>/dev/null | grep -w inet | awk '{print $2}' | cut -d/ -f1 | head -n1
    fi
}

# Perform ICMP ping connectivity check, parsing packet loss and average latency
check_connectivity() {
    local interface=$1
    
    # Run ping
    local ping_out
    ping_out=$(ping -I "$interface" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$PING_TARGET" 2>&1)
    local exit_status=$?
    
    if (( exit_status == 0 )); then
        CONNECTIVITY_RESULT="OK"
        # Parse average latency (format: rtt min/avg/max/mdev = 11.23/12.45/...)
        local latency
        latency=$(echo "$ping_out" | grep -oE 'rtt min/avg/max/mdev = [0-9.]*/[0-9.]*' | cut -d/ -f5)
        # Fallback if parsing fails
        [[ -z "$latency" ]] && latency=$(echo "$ping_out" | grep -oE 'round-trip min/avg/max/stddev = [0-9.]*/[0-9.]*' | cut -d/ -f5)
        CONNECTIVITY_LATENCY=${latency:-0}
        
        # Parse packet loss
        local loss
        loss=$(echo "$ping_out" | grep -oE '[0-9]+% packet loss' | cut -d% -f1)
        CONNECTIVITY_LOSS=${loss:-0}
    else
        CONNECTIVITY_RESULT="DOWN"
        CONNECTIVITY_LATENCY=-1
        CONNECTIVITY_LOSS=100
        log "[$interface] Test: Fail during Ping - $PING_TARGET did not respond"
    fi
}

# Perform a DNS query using dig, capturing execution success and latency
check_dns() {
    local interface=$1 server=$2 port=$3 local_ip=$4
    
    # Default outputs
    DNS_LATENCY=-1
    DNS_SUCCESS=false
    
    # Require local IP
    [[ -z "$local_ip" ]] && return 1
    
    local dig_out
    # Query with 2s timeout, 1 retry
    dig_out=$(dig +time=2 +tries=1 "$DNS_TEST_DOMAIN" "@$server" -p "$port" -b "$local_ip" 2>&1)
    local exit_status=$?
    
    if (( exit_status == 0 )) && echo "$dig_out" | grep -q 'Query time:'; then
        local query_time
        query_time=$(echo "$dig_out" | grep -oE 'Query time: [0-9]+' | awk '{print $3}')
        DNS_LATENCY=${query_time:-0}
        DNS_SUCCESS=true
    fi
}

# Perform DNS chain queries in order
check_dns_chain() {
    local interface=$1 local_ip=$2
    
    # Output variables (passed by global reference)
    PIHOLE_OK=false
    PIHOLE_LATENCY=-1
    DNSCRYPT_OK=false
    DNSCRYPT_LATENCY=-1
    CLOUDFLARE_OK=false
    CLOUDFLARE_LATENCY=-1
    
    # 1. Pi-hole Check (127.0.0.1 on port 53)
    if check_dns "$interface" "127.0.0.1" "$PIHOLE_PORT" "$local_ip"; then
        PIHOLE_OK="$DNS_SUCCESS"
        PIHOLE_LATENCY="$DNS_LATENCY"
    fi
    
    # 2. dnscrypt-proxy Check (127.0.0.1 on port 5053)
    if check_dns "$interface" "127.0.0.1" "$DNSCRYPT_PORT" "$local_ip"; then
        DNSCRYPT_OK="$DNS_SUCCESS"
        DNSCRYPT_LATENCY="$DNS_LATENCY"
    fi
    
    # 3. Cloudflare Check (1.1.1.1 on port 53)
    if check_dns "$interface" "1.1.1.1" "53" "$local_ip"; then
        CLOUDFLARE_OK="$DNS_SUCCESS"
        CLOUDFLARE_LATENCY="$DNS_LATENCY"
    fi
    
    # Aggregate DNS status
    if [[ "$PIHOLE_OK" == "true" && "$DNSCRYPT_OK" == "true" && "$CLOUDFLARE_OK" == "true" ]]; then
        DNS_OK_RESULT="true"
    else
        DNS_OK_RESULT="false"
        
        # Log error block
        log "[$interface] DOWN"
        log_dns_results "$interface" "$PIHOLE_OK" "$DNSCRYPT_OK" "$CLOUDFLARE_OK"
        
        local failure_point
        failure_point=$(determine_failure_point "$PIHOLE_OK" "$DNSCRYPT_OK" "$CLOUDFLARE_OK")
        log_dns_diagnostics "$interface" "$failure_point"
        
        log "[$interface] Issue: DNS issue detected. Connectivity still OK"
        log "[$interface] DOWN"
    fi
}

log_dns_results() {
    local interface=$1 pihole_ok=$2 dnscrypt_ok=$3 cloudflare_ok=$4
    [[ "$pihole_ok" == "false" ]] && log "[$interface] Test: Fail via Pi-hole (127.0.0.1:$PIHOLE_PORT)"
    [[ "$pihole_ok" == "true" ]]  && log "[$interface] Test: Pass via Pi-hole (127.0.0.1:$PIHOLE_PORT)"
    [[ "$dnscrypt_ok" == "false" ]] && log "[$interface] Test: Fail via dnscrypt-proxy (127.0.0.1:${DNSCRYPT_PORT})"
    [[ "$dnscrypt_ok" == "true" ]]  && log "[$interface] Test: Pass via dnscrypt-proxy (127.0.0.1:${DNSCRYPT_PORT})"
    [[ "$cloudflare_ok" == "false" ]] && log "[$interface] Test: Fail via Cloudflare public (1.1.1.1:53)"
    [[ "$cloudflare_ok" == "true" ]]  && log "[$interface] Test: Pass via Cloudflare public (1.1.1.1:53)"
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
