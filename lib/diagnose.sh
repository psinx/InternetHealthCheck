#!/usr/bin/env bash

# lib/diagnose.sh - Terminal-based interactive diagnostics

# Perform real-time visual troubleshoot diagnostics
diagnose_cli() {
    local target_interfaces=("$@")
    
    # If no interfaces specified, discover active ones
    if [[ ${#target_interfaces[@]} -eq 0 ]]; then
        # Dynamically discover
        if [[ "$OSTYPE" == "darwin"* ]]; then
            target_interfaces=($(ifconfig -l | tr ' ' '\n' | grep -E '^en|^eth' || echo "en0"))
        else
            target_interfaces=($(ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-' || echo "eth0"))
        fi
    fi

    echo -e "\e[1m==========================================\e[0m"
    echo -e "\e[1;36mINTERNET HEALTH - REAL-TIME DIAGNOSTICS\e[0m"
    echo -e "\e[1m==========================================\e[0m"
    echo ""

    for iface in "${target_interfaces[@]}"; do
        echo -e "\e[1mChecking Interface: \e[33m$iface\e[0m"
        
        # 1. Check physical carrier link
        local carrier=0
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if ifconfig "$iface" 2>/dev/null | grep -q "status: active"; then
                carrier=1
            fi
        else
            if [[ -f "/sys/class/net/$iface/carrier" ]]; then
                carrier=$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || echo 0)
            else
                if ip link show "$iface" 2>/dev/null | grep -q "lower_up"; then
                    carrier=1
                fi
            fi
        fi

        if (( carrier == 1 )); then
            echo -e "  \e[32m✓\e[0m 1. Physical Link: \e[32mCONNECTED\e[0m"
        else
            echo -e "  \e[31m✗\e[0m 1. Physical Link: \e[31mDISCONNECTED / NO CARRIER\e[0m"
            echo -e "     \e[90m└─ Outage root cause: Check your ethernet cable or Wi-Fi connection.\e[0m"
            echo ""
            continue
        fi

        # 2. Check local IP assignment
        local ip_addr
        ip_addr=$(get_interface_ip "$iface")
        if [[ -n "$ip_addr" ]]; then
            echo -e "  \e[32m✓\e[0m 2. Local IP Assigned: \e[32m$ip_addr\e[0m"
        else
            echo -e "  \e[31m✗\e[0m 2. Local IP Assigned: \e[31mFAIL (No IP address)\e[0m"
            echo -e "     \e[90m└─ Outage root cause: DHCP client failed to lease an IP address from router.\e[0m"
            echo ""
            continue
        fi

        # 3. Check Gateway Connectivity
        local gateway
        if [[ "$OSTYPE" == "darwin"* ]]; then
            gateway=$(netstat -rn | grep default | awk '{print $2}' | head -n1)
        else
            gateway=$(ip route show dev "$iface" 2>/dev/null | grep default | awk '{print $3}' | head -n1)
            # Fallback if no default route on this specific interface
            [[ -z "$gateway" ]] && gateway=$(ip route show 2>/dev/null | grep default | awk '{print $3}' | head -n1)
        fi

        if [[ -n "$gateway" ]]; then
            # Ping gateway 3 times with 2s timeout
            if ping -I "$iface" -c 3 -W 2 "$gateway" >/dev/null 2>&1; then
                echo -e "  \e[32m✓\e[0m 3. Gateway Ping ($gateway): \e[32mRESPONDING\e[0m"
            else
                echo -e "  \e[31m✗\e[0m 3. Gateway Ping ($gateway): \e[31mUNRESPONSIVE\e[0m"
                echo -e "     \e[90m└─ Outage root cause: Gateway router is down or blocking ICMP.\e[0m"
                echo ""
                continue
            fi
        else
            echo -e "  \e[33m! Warning:\e[0m 3. Gateway Ping: \e[33mSKIPPED (No default route found)\e[0m"
        fi

        # 4. Check DNS Chain Hops
        echo -e "  \e[1m4. DNS Chain Resolution:\e[0m"
        
        # Hop A: Pi-hole
        check_dns "$iface" "127.0.0.1" "$PIHOLE_PORT" "$ip_addr"
        local pi_ok="$DNS_SUCCESS"
        local pi_lat="$DNS_LATENCY"
        
        if [[ "$pi_ok" == "true" ]]; then
            echo -e "     \e[32m✓\e[0m Hop 1 (Pi-hole @127.0.0.1:$PIHOLE_PORT): \e[32mPASS\e[0m (${pi_lat}ms)"
        else
            echo -e "     \e[31m✗\e[0m Hop 1 (Pi-hole @127.0.0.1:$PIHOLE_PORT): \e[31mFAIL\e[0m"
        fi

        # Hop B: dnscrypt-proxy
        check_dns "$iface" "127.0.0.1" "$DNSCRYPT_PORT" "$ip_addr"
        local dc_ok="$DNS_SUCCESS"
        local dc_lat="$DNS_LATENCY"
        
        if [[ "$dc_ok" == "true" ]]; then
            echo -e "     \e[32m✓\e[0m Hop 2 (dnscrypt-proxy @127.0.0.1:$DNSCRYPT_PORT): \e[32mPASS\e[0m (${dc_lat}ms)"
        else
            echo -e "     \e[31m✗\e[0m Hop 2 (dnscrypt-proxy @127.0.0.1:$DNSCRYPT_PORT): \e[31mFAIL\e[0m"
        fi

        # Hop C: Cloudflare upstream
        check_dns "$iface" "1.1.1.1" "53" "$ip_addr"
        local cf_ok="$DNS_SUCCESS"
        local cf_lat="$DNS_LATENCY"
        
        if [[ "$cf_ok" == "true" ]]; then
            echo -e "     \e[32m✓\e[0m Hop 3 (Cloudflare public @1.1.1.1:53): \e[32mPASS\e[0m (${cf_lat}ms)"
        else
            echo -e "     \e[31m✗\e[0m Hop 3 (Cloudflare public @1.1.1.1:53): \e[31mFAIL\e[0m"
        fi

        # Analyze DNS Break point
        if [[ "$pi_ok" == "true" && "$dc_ok" == "true" && "$cf_ok" == "true" ]]; then
            echo -e "  \e[1;32mSTATUS: Interface online and fully operational.\e[0m"
        else
            echo ""
            echo -e "  \e[1;31mDNS FAILURE DIAGNOSIS:\e[0m"
            if [[ "$pi_ok" == "false" && "$dc_ok" == "true" ]]; then
                echo -e "     \e[1;33m[!] Pi-hole Local Server Failure\e[0m"
                echo -e "     \e[90m└─ Root cause: Pi-hole is not running or port 53 is blocked.\e[0m"
                echo -e "     \e[90m└─ Diagnostic query path: Client × Pi-hole ── dnscrypt-proxy ── Cloudflare\e[0m"
            elif [[ "$dc_ok" == "false" && "$cf_ok" == "true" ]]; then
                echo -e "     \e[1;33m[!] dnscrypt-proxy Upstream Resolver Failure\e[0m"
                echo -e "     \e[90m└─ Root cause: dnscrypt-proxy daemon crashed or port 5053 is down.\e[0m"
                echo -e "     \e[90m└─ Diagnostic query path: Client ── Pi-hole × dnscrypt-proxy ── Cloudflare\e[0m"
            elif [[ "$cf_ok" == "false" ]]; then
                echo -e "     \e[1;33m[!] External Upstream Connectivity Outage\e[0m"
                echo -e "     \e[90m└─ Root cause: Upstream Cloudflare DNS server unreachable (likely ISP routing error).\e[0m"
                echo -e "     \e[90m└─ Diagnostic query path: Client ── Pi-hole ── dnscrypt-proxy × Cloudflare\e[0m"
            fi
        fi
        echo ""
    done
}
