#!/usr/bin/env bash

# lib/display.sh - Terminal formatting and visual status output

print_pretty_header() {
    echo -e "\e[1m==========================================\e[0m"
    echo -e "\e[1;36mINTERNET HEALTH - REAL-TIME STATUS\e[0m"
    echo -e "\e[1m==========================================\e[0m"
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

    echo -e "\e[1mInterface: \e[33m$iface\e[0m"

    # 1. Carrier check
    if (( carrier == 1 )); then
        echo -e "  \e[32m✓\e[0m 1. Physical Link: \e[32mCONNECTED\e[0m"
    else
        echo -e "  \e[31m✗\e[0m 1. Physical Link: \e[31mDISCONNECTED / NO CARRIER\e[0m"
        echo -e "     \e[90m└─ Outage root cause: Check ethernet cable or Wi-Fi connection.\e[0m"
        echo ""
        return
    fi

    # 2. Local IP
    if [[ -n "$local_ip" ]]; then
        echo -e "  \e[32m✓\e[0m 2. Local IP Assigned: \e[32m$local_ip\e[0m"
    else
        echo -e "  \e[31m✗\e[0m 2. Local IP Assigned: \e[31mFAIL (No IP address)\e[0m"
        echo -e "     \e[90m└─ Outage root cause: DHCP client has not leased an IP address.\e[0m"
        echo ""
        return
    fi

    # 3. Internet Connectivity Ping
    if [[ "$conn_result" == "OK" ]]; then
        echo -e "  \e[32m✓\e[0m 3. Internet Ping ($PING_TARGET): \e[32mPASS\e[0m (${conn_latency}ms, ${conn_loss}% loss)"
    else
        echo -e "  \e[31m✗\e[0m 3. Internet Ping ($PING_TARGET): \e[31mFAIL\e[0m (${conn_loss}% loss)"
    fi

    # 4. DNS Chain Resolution
    echo -e "  \e[1m4. DNS Chain Resolution:\e[0m"
    local pi_host="${PIHOLE_HOST:-127.0.0.1}"
    local dc_host="${DNSCRYPT_HOST:-127.0.0.1}"

    if [[ "$pi_ok" == "true" ]]; then
        echo -e "     \e[32m✓\e[0m Hop 1 (Pi-hole @$pi_host:$PIHOLE_PORT): \e[32mPASS\e[0m (${pi_lat}ms)"
    else
        echo -e "     \e[31m✗\e[0m Hop 1 (Pi-hole @$pi_host:$PIHOLE_PORT): \e[31mFAIL\e[0m"
    fi

    if [[ "${SKIP_DNSCRYPT:-false}" == "true" ]]; then
        echo -e "     \e[90m- Hop 2 (dnscrypt-proxy): SKIPPED (Client Mode)\e[0m"
    elif [[ "$dc_ok" == "true" ]]; then
        echo -e "     \e[32m✓\e[0m Hop 2 (dnscrypt-proxy @$dc_host:$DNSCRYPT_PORT): \e[32mPASS\e[0m (${dc_lat}ms)"
    else
        echo -e "     \e[31m✗\e[0m Hop 2 (dnscrypt-proxy @$dc_host:$DNSCRYPT_PORT): \e[31mFAIL\e[0m"
    fi

    local upstream_name="Upstream"
    [[ "$upstream_ip" =~ 1\.1\.1\. || "$upstream_ip" =~ 1\.0\.0\. ]] && upstream_name="Cloudflare"
    if [[ "$cf_ok" == "true" ]]; then
        echo -e "     \e[32m✓\e[0m Hop 3 ($upstream_name @$upstream_ip:53): \e[32mPASS\e[0m (${cf_lat}ms)"
    else
        echo -e "     \e[31m✗\e[0m Hop 3 ($upstream_name @$upstream_ip:53): \e[31mFAIL\e[0m"
    fi

    # Status & Diagnostics breakdown
    if [[ "$conn_result" == "OK" && "$dns_ok" == "true" ]]; then
        echo -e "  \e[1;32mSTATUS: Interface online and fully operational.\e[0m"
    else
        echo ""
        echo -e "  \e[1;31mFAILURE DIAGNOSIS:\e[0m"
        if [[ "$conn_result" != "OK" ]]; then
            echo -e "     \e[1;33m[!] Internet Connectivity Loss\e[0m"
            echo -e "     \e[90m└─ Root cause: Gateway or WAN connection unreachable (100% packet loss to $PING_TARGET).\e[0m"
        fi
        if [[ "$pi_ok" == "false" && "$dc_ok" == "true" ]]; then
            echo -e "     \e[1;33m[!] Pi-hole Server Failure\e[0m"
            echo -e "     \e[90m└─ Root cause: Pi-hole is not reachable at $pi_host:$PIHOLE_PORT.\e[0m"
        elif [[ "${SKIP_DNSCRYPT:-false}" != "true" && "$dc_ok" == "false" && "$cf_ok" == "true" ]]; then
            echo -e "     \e[1;33m[!] dnscrypt-proxy Upstream Resolver Failure\e[0m"
            echo -e "     \e[90m└─ Root cause: dnscrypt-proxy daemon crashed or port $DNSCRYPT_PORT is down.\e[0m"
        elif [[ "$cf_ok" == "false" ]]; then
            echo -e "     \e[1;33m[!] External Upstream DNS Outage\e[0m"
            echo -e "     \e[90m└─ Root cause: Upstream DNS ($upstream_ip) unreachable or dropping queries.\e[0m"
        fi
    fi
    echo ""
}
