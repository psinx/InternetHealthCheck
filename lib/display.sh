#!/usr/bin/env bash

# lib/display.sh - Terminal formatting and visual status output

print_pretty_header() {
    echo -e "\033[1m==========================================\033[0m"
    echo -e "\033[1;36mINTERNET HEALTH - REAL-TIME STATUS\033[0m"
    echo -e "\033[1m==========================================\033[0m"
    echo ""
}

print_pretty_interface() {
    local iface=$1
    local local_ip=$2
    local carrier=$3
    local conn_result=$4
    local conn_latency=$5
    local conn_loss=$6
    local pi_ok=$7
    local pi_lat=$8
    local dc_ok=$9
    local dc_lat=${10}
    local cf_ok=${11}
    local cf_lat=${12}
    local upstream_ip=${13:-"1.1.1.3"}
    local dns_ok=${14:-"true"}

    echo -e "\033[1mInterface: \033[33m$iface\033[0m"

    # 1. Carrier check
    if (( carrier == 1 )); then
        echo -e "  \033[32m✓\033[0m 1. Physical Link: \033[32mCONNECTED\033[0m"
    else
        echo -e "  \033[31m✗\033[0m 1. Physical Link: \033[31mDISCONNECTED / NO CARRIER\033[0m"
        echo -e "     \033[90m└─ Outage root cause: Check ethernet cable or Wi-Fi connection.\033[0m"
        echo ""
        return
    fi

    # 2. Local IP
    if [[ -n "$local_ip" ]]; then
        echo -e "  \033[32m✓\033[0m 2. Local IP Assigned: \033[32m$local_ip\033[0m"
    else
        echo -e "  \033[31m✗\033[0m 2. Local IP Assigned: \033[31mFAIL (No IP address)\033[0m"
        echo -e "     \033[90m└─ Outage root cause: DHCP client has not leased an IP address.\033[0m"
        echo ""
        return
    fi

    # 3. Internet Connectivity Ping
    if [[ "$conn_result" == "OK" ]]; then
        echo -e "  \033[32m✓\033[0m 3. Internet Ping ($PING_TARGET): \033[32mPASS\033[0m (${conn_latency}ms, ${conn_loss}% loss)"
    else
        echo -e "  \033[31m✗\033[0m 3. Internet Ping ($PING_TARGET): \033[31mFAIL\033[0m (${conn_loss}% loss)"
    fi

    # 4. DNS Chain Resolution
    echo -e "  \033[1m4. DNS Chain Resolution:\033[0m"
    local pi_host="${PIHOLE_HOST:-127.0.0.1}"
    local dc_host="${DNSCRYPT_HOST:-127.0.0.1}"

    if [[ "$pi_ok" == "true" ]]; then
        echo -e "     \033[32m✓\033[0m Hop 1 (Pi-hole @$pi_host:$PIHOLE_PORT): \033[32mPASS\033[0m (${pi_lat}ms)"
    else
        echo -e "     \033[31m✗\033[0m Hop 1 (Pi-hole @$pi_host:$PIHOLE_PORT): \033[31mFAIL\033[0m"
    fi

    if [[ "${SKIP_DNSCRYPT:-false}" == "true" ]]; then
        echo -e "     \033[90m- Hop 2 (dnscrypt-proxy): SKIPPED (Client Mode)\033[0m"
    elif [[ "$dc_ok" == "true" ]]; then
        echo -e "     \033[32m✓\033[0m Hop 2 (dnscrypt-proxy @$dc_host:$DNSCRYPT_PORT): \033[32mPASS\033[0m (${dc_lat}ms)"
    else
        echo -e "     \033[31m✗\033[0m Hop 2 (dnscrypt-proxy @$dc_host:$DNSCRYPT_PORT): \033[31mFAIL\033[0m"
    fi

    local upstream_name="Upstream"
    [[ "$upstream_ip" =~ 1\.1\.1\. || "$upstream_ip" =~ 1\.0\.0\. ]] && upstream_name="Cloudflare"
    if [[ "$cf_ok" == "true" ]]; then
        echo -e "     \033[32m✓\033[0m Hop 3 ($upstream_name @$upstream_ip:53): \033[32mPASS\033[0m (${cf_lat}ms)"
    else
        echo -e "     \033[31m✗\033[0m Hop 3 ($upstream_name @$upstream_ip:53): \033[31mFAIL\033[0m"
    fi

    # Status & Diagnostics breakdown
    if [[ "$conn_result" == "OK" && "$dns_ok" == "true" ]]; then
        echo -e "  \033[1;32mSTATUS: Interface online and fully operational.\033[0m"
    else
        echo ""
        echo -e "  \033[1;31mFAILURE DIAGNOSIS:\033[0m"
        if [[ "$conn_result" != "OK" ]]; then
            echo -e "     \033[1;33m[!] Internet Connectivity Loss\033[0m"
            echo -e "     \033[90m└─ Root cause: Gateway or WAN connection unreachable (100% packet loss to $PING_TARGET).\033[0m"
        fi
        if [[ "$pi_ok" == "false" && "$dc_ok" == "true" ]]; then
            echo -e "     \033[1;33m[!] Pi-hole Server Failure\033[0m"
            echo -e "     \033[90m└─ Root cause: Pi-hole is not reachable at $pi_host:$PIHOLE_PORT.\033[0m"
        elif [[ "${SKIP_DNSCRYPT:-false}" != "true" && "$dc_ok" == "false" && "$cf_ok" == "true" ]]; then
            echo -e "     \033[1;33m[!] dnscrypt-proxy Upstream Resolver Failure\033[0m"
            echo -e "     \033[90m└─ Root cause: dnscrypt-proxy daemon crashed or port $DNSCRYPT_PORT is down.\033[0m"
        elif [[ "$cf_ok" == "false" ]]; then
            echo -e "     \033[1;33m[!] External Upstream DNS Outage\033[0m"
            echo -e "     \033[90m└─ Root cause: Upstream DNS ($upstream_ip) unreachable or dropping queries.\033[0m"
        fi
    fi
    echo ""
}
