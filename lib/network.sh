#!/usr/bin/env bash

# lib/network.sh - Network connectivity and DNS chain checks

# Buffer diagnostic lines per interface so --reduce-disk-wear flushes only on state change
net_log() {
    DIAG_LOG_LINES+=("$1")
}

# Resolve global IPv4 address assigned to a specific interface (excludes link-local APIPA)
get_interface_ip() {
    local interface=$1
    if [[ "$OSTYPE" == "darwin"* ]]; then
        ifconfig "$interface" 2>/dev/null | grep 'inet ' | grep -v '169\.254\.' | awk '{print $2}' | head -n1
    else
        if command -v ip >/dev/null 2>&1; then
            ip -4 addr show dev "$interface" scope global 2>/dev/null \
                | grep -w inet \
                | grep -v '169\.254\.' \
                | awk '{print $2}' \
                | cut -d/ -f1 \
                | head -n1
        fi
    fi
}

# Check whether an interface is administratively UP (1=admin up, 0=admin down)
get_interface_admin_up() {
    local interface=$1
    local sys_net="${NET_SYSFS_ROOT:-/sys/class/net}"

    if [[ "$OSTYPE" == "darwin"* ]]; then
        if ifconfig "$interface" 2>/dev/null | head -n1 | grep -qE '<[^>]*\bUP\b[^>]*>'; then
            echo 1
        else
            echo 0
        fi
        return 0
    fi

    if [[ -f "${sys_net}/${interface}/flags" ]]; then
        local flags_val
        flags_val=$(cat "${sys_net}/${interface}/flags" 2>/dev/null || echo 0)
        if (( (flags_val & 1) != 0 )); then
            echo 1
        else
            echo 0
        fi
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        local link_out
        link_out=$(ip link show "$interface" 2>/dev/null)
        local rc=$?
        if (( rc != 0 )); then
            echo 0
        elif [[ -z "$link_out" ]]; then
            # Minimal test mock that returns 0 without output
            echo 1
        elif echo "$link_out" | grep -qE '<[^>]*\bUP\b[^>]*>'; then
            echo 1
        else
            echo 0
        fi
        return 0
    fi

    echo 0
}

# Check physical link carrier status (1=connected, 0=no carrier/disconnected/admin-down)
get_interface_carrier() {
    local interface=$1
    local sys_net="${NET_SYSFS_ROOT:-/sys/class/net}"

    local admin_up
    admin_up=$(get_interface_admin_up "$interface")
    if [[ "$admin_up" == "0" ]]; then
        echo 0
        return 0
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        if ifconfig "$interface" 2>/dev/null | grep -q "status: active"; then
            echo 1
        else
            echo 0
        fi
        return 0
    fi

    if [[ -d "${sys_net}/${interface}" ]]; then
        if [[ -r "${sys_net}/${interface}/carrier" ]]; then
            local carrier_val
            if carrier_val=$(cat "${sys_net}/${interface}/carrier" 2>/dev/null) && [[ -n "$carrier_val" ]]; then
                echo "$carrier_val"
                return 0
            fi
        fi
        # Reading carrier fails with EINVAL when down/initializing; check operstate, never default to 1
        local oper
        oper=$(cat "${sys_net}/${interface}/operstate" 2>/dev/null || echo "down")
        if [[ "$oper" == "up" || "$oper" == "unknown" ]]; then
            echo 1
        else
            echo 0
        fi
        return 0
    fi

    if command -v ip >/dev/null 2>&1; then
        local link_out
        link_out=$(ip link show "$interface" 2>/dev/null)
        if echo "$link_out" | grep -q "NO-CARRIER"; then
            echo 0
        else
            echo 1
        fi
        return 0
    fi

    echo 0
}

# Decode IP address from an sdns:// DNS stamp if python3 is available
decode_sdns_stamp_ip() {
    local stamp=$1
    [[ -z "$stamp" || "$stamp" != sdns://* ]] && return 1
    command -v python3 >/dev/null 2>&1 || return 1

    python3 -c '
import base64, sys
s = sys.argv[1]
if not s.startswith("sdns://"):
    sys.exit(1)
b64 = s[7:]
b64 += "=" * ((4 - len(b64) % 4) % 4)
try:
    raw = base64.urlsafe_b64decode(b64)
    # 1 byte proto + 8 bytes props + 1 byte addr len
    if len(raw) < 11:
        sys.exit(1)
    alen = raw[9]
    if len(raw) < 10 + alen:
        sys.exit(1)
    addr = raw[10:10 + alen].decode("utf-8", errors="ignore")
    # Strip optional :port or [ipv6]:port
    if addr.startswith("["):
        addr = addr[1:].split("]", 1)[0]
    elif ":" in addr:
        addr = addr.split(":", 1)[0]
    if addr:
        print(addr)
except Exception:
    sys.exit(1)
' "$stamp" 2>/dev/null
}

# Map a dnscrypt server name to its resolver IP using cache stamps or known defaults
resolve_dnscrypt_server_ip() {
    local name=$1 cache_file=$2
    if [[ -f "$cache_file" && -n "$name" ]]; then
        local stamp
        stamp=$(sed -n "/^## ${name}\$/,/^## /p" "$cache_file" 2>/dev/null | grep '^sdns://' | head -n1)
        if [[ -n "$stamp" ]]; then
            local ip_from_stamp
            ip_from_stamp=$(decode_sdns_stamp_ip "$stamp")
            if [[ -n "$ip_from_stamp" ]]; then
                echo "$ip_from_stamp"
                return 0
            fi
        fi
    fi

    case "$name" in
        *cloudflare-family*|*1.1.1.3*) echo "1.1.1.3" ;;
        *cloudflare-security*|*1.1.1.2*) echo "1.1.1.2" ;;
        *cloudflare*) echo "1.1.1.1" ;;
        *quad9*) echo "9.9.9.9" ;;
        *google*) echo "8.8.8.8" ;;
        *adguard*family*) echo "94.140.14.15" ;;
        *adguard*) echo "94.140.14.14" ;;
        *) echo "" ;;
    esac
}

# Detect primary & optional secondary upstream DNS resolver IPs from dnscrypt-proxy config
detect_upstream_dns() {
    local override_ip=${1:-""}
    local override_sec=${2:-"${UPSTREAM_SECONDARY_DNS:-}"}

    UPSTREAM_PRIMARY_IP=""
    UPSTREAM_SECONDARY_IP="$override_sec"

    if [[ -n "$override_ip" ]]; then
        UPSTREAM_PRIMARY_IP="$override_ip"
        echo "$UPSTREAM_PRIMARY_IP"
        return 0
    fi

    local config_file="${DNSCRYPT_CONFIG_FILE:-/etc/dnscrypt-proxy/dnscrypt-proxy.toml}"
    local cache_file="${DNSCRYPT_CACHE_FILE:-/var/cache/dnscrypt-proxy/public-resolvers.md}"

    if [[ -f "$config_file" ]]; then
        local raw_line
        raw_line=$(grep -iE '^[[:space:]]*server_names[[:space:]]*=' "$config_file" 2>/dev/null | head -n1 | sed 's/#.*//')
        if [[ -n "$raw_line" ]]; then
            local names_csv
            names_csv=$(echo "$raw_line" | cut -d'=' -f2- | tr -d "'\"[] ")
            IFS=',' read -ra server_list <<< "$names_csv"
            local idx=0
            for srv in "${server_list[@]}"; do
                [[ -z "$srv" ]] && continue
                local resolved_ip
                resolved_ip=$(resolve_dnscrypt_server_ip "$srv" "$cache_file")
                if [[ -n "$resolved_ip" ]]; then
                    if (( idx == 0 )) && [[ -z "$UPSTREAM_PRIMARY_IP" ]]; then
                        UPSTREAM_PRIMARY_IP="$resolved_ip"
                    elif [[ -z "$UPSTREAM_SECONDARY_IP" && "$resolved_ip" != "$UPSTREAM_PRIMARY_IP" ]]; then
                        UPSTREAM_SECONDARY_IP="$resolved_ip"
                    fi
                fi
                ((idx++)) || true
            done
        fi
    fi

    [[ -z "$UPSTREAM_PRIMARY_IP" ]] && UPSTREAM_PRIMARY_IP="1.1.1.1"
    echo "$UPSTREAM_PRIMARY_IP"
}

# Run ping command safely across Linux, macOS, and test sandboxes
run_ping_cmd() {
    local interface=$1 target=$2 local_ip=$3
    local count="${PING_COUNT:-10}"
    local timeout="${PING_TIMEOUT:-5}"
    local interval="${PING_INTERVAL:-0.2}"

    local out rc
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local timeout_ms=$(( timeout * 1000 ))
        if [[ -n "$local_ip" ]]; then
            out=$(ping -S "$local_ip" -c "$count" -i "$interval" -W "$timeout_ms" "$target" 2>&1)
        else
            out=$(ping -c "$count" -i "$interval" -W "$timeout_ms" "$target" 2>&1)
        fi
        rc=$?
    else
        out=$(ping -I "$interface" -c "$count" -i "$interval" -W "$timeout" "$target" 2>&1)
        rc=$?
        # Fallback if ping -i <0.2s or SO_BINDTODEVICE interval rejected by unprivileged sandbox
        if (( rc != 0 )) && echo "$out" | grep -qiE 'bad timing|cannot flood|invalid|permission|operation not permitted'; then
            out=$(ping -I "$interface" -c 4 -W "$timeout" "$target" 2>&1)
            rc=$?
        fi
    fi
    PING_RAW_OUT="$out"
    return $rc
}

# Perform ICMP ping connectivity check with fallback WAN target and float loss parsing
check_connectivity() {
    local interface=$1
    local local_ip=${2:-$(get_interface_ip "$interface")}

    CONNECTIVITY_DEGRADED=false
    CONNECTIVITY_DEGRADED_REASON=""

    local target_used="$PING_TARGET"
    run_ping_cmd "$interface" "$PING_TARGET" "$local_ip"
    local exit_status=$?

    local fallback_target="${PING_FALLBACK_TARGET-9.9.9.9}"
    if (( exit_status != 0 )) && [[ -n "$fallback_target" && "$fallback_target" != "$PING_TARGET" ]]; then
        local primary_out="$PING_RAW_OUT"
        if run_ping_cmd "$interface" "$fallback_target" "$local_ip"; then
            exit_status=0
            target_used="$fallback_target"
            net_log "[$interface] Warning: Primary ping $PING_TARGET unreachable; secondary $fallback_target succeeded"
        else
            PING_RAW_OUT="$primary_out"
        fi
    fi

    if (( exit_status == 0 )); then
        CONNECTIVITY_RESULT="OK"
        local latency
        latency=$(echo "$PING_RAW_OUT" | grep -oE 'rtt min/avg/max/mdev = [0-9.]*/[0-9.]*' | cut -d/ -f5)
        [[ -z "$latency" ]] && latency=$(echo "$PING_RAW_OUT" | grep -oE 'round-trip min/avg/max/stddev = [0-9.]*/[0-9.]*' | cut -d/ -f5)
        CONNECTIVITY_LATENCY=${latency:-0}

        # Parse float or integer packet loss cleanly (Linux: "0% packet loss", macOS: "25.0% packet loss")
        local loss
        loss=$(echo "$PING_RAW_OUT" | grep -oE '[0-9]+(\.[0-9]+)?% packet loss' | head -n1 | sed 's/%.*//')
        CONNECTIVITY_LOSS=${loss:-0}

        local loss_warn="${PACKET_LOSS_WARN_PCT:-5}"
        local is_loss_warn=0
        is_loss_warn=$(awk -v l="$CONNECTIVITY_LOSS" -v w="$loss_warn" 'BEGIN { print (l >= w) ? 1 : 0 }' 2>/dev/null || echo 0)
        if (( is_loss_warn == 1 )); then
            CONNECTIVITY_DEGRADED=true
            CONNECTIVITY_DEGRADED_REASON="Packet loss (${CONNECTIVITY_LOSS}% >= ${loss_warn}%)"
            net_log "[$interface] Warning: Connectivity degraded - ${CONNECTIVITY_DEGRADED_REASON}"
        elif [[ "$target_used" != "$PING_TARGET" ]]; then
            CONNECTIVITY_DEGRADED=true
            CONNECTIVITY_DEGRADED_REASON="Primary ping ($PING_TARGET) unreachable; fallback ($target_used) OK"
        fi
    else
        CONNECTIVITY_RESULT="DOWN"
        CONNECTIVITY_LATENCY=-1
        CONNECTIVITY_LOSS=100
        CONNECTIVITY_DEGRADED=false
        CONNECTIVITY_DEGRADED_REASON="Total outage"
        net_log "[$interface] Test: Fail during Ping - $PING_TARGET did not respond"
    fi
}

# Perform a strict DNS query validating RCODE and response section (supports cache-busting nonce)
check_dns() {
    local interface=$1 server=$2 port=$3 local_ip=$4 cache_bust_mode=${5:-"false"}

    DNS_LATENCY=-1
    DNS_SUCCESS=false

    [[ -z "$local_ip" ]] && return 1

    local timeout="${DNS_TIMEOUT:-3}"
    local tries="${DNS_TRIES:-2}"
    local query_domain="$DNS_TEST_DOMAIN"
    if [[ "$cache_bust_mode" == "true" ]]; then
        query_domain="hc-$(date +%s)-$RANDOM.${DNS_TEST_DOMAIN}"
    fi

    # Never bind a LAN IP when probing loopback addresses (bypasses interface & fails on BSD/macOS)
    local bind_ip="$local_ip"
    if [[ "$server" == "127.0.0.1" || "$server" == "::1" ]]; then
        bind_ip=""
    fi

    if command -v dig >/dev/null 2>&1; then
        local dig_args=(+time="$timeout" +tries="$tries" "$query_domain" "@$server" -p "$port")
        [[ -n "$bind_ip" ]] && dig_args+=(-b "$bind_ip")

        local dig_out
        dig_out=$(dig "${dig_args[@]}" 2>&1)
        local exit_status=$?

        if (( exit_status == 0 )) && echo "$dig_out" | grep -q 'Query time:'; then
            local valid=false
            if [[ "$cache_bust_mode" == "true" ]]; then
                if echo "$dig_out" | grep -qE 'status: (NOERROR|NXDOMAIN)' \
                   && echo "$dig_out" | grep -qE 'flags:.* ra([ ;]|$)' \
                   && echo "$dig_out" | grep -qE '(ANSWER|AUTHORITY): [1-9]'; then
                    valid=true
                fi
            else
                if echo "$dig_out" | grep -q 'status: NOERROR' \
                   && echo "$dig_out" | grep -qE 'ANSWER: [1-9]'; then
                    valid=true
                fi
            fi

            if [[ "$valid" == "true" ]]; then
                local query_time
                query_time=$(echo "$dig_out" | grep -oE 'Query time: [0-9]+' | awk '{print $3}')
                DNS_LATENCY=${query_time:-0}
                DNS_SUCCESS=true
            fi
        fi
    elif command -v python3 >/dev/null 2>&1; then
        # RFC 1035 compliant pure-Python UDP probe for hosts without bind9-dnsutils/dig
        local py_lat
        py_lat=$(python3 -c '
import os, socket, struct, sys, time

server = sys.argv[1]
port = int(sys.argv[2])
bind_ip = sys.argv[3]
domain = sys.argv[4]
timeout = float(sys.argv[5])
tries = max(1, int(sys.argv[6]))
cache_bust = (sys.argv[7] == "true")

labels = b"".join(bytes([len(p)]) + p.encode("ascii") for p in domain.strip(".").split(".") if p) + b"\x00"
family = socket.AF_INET6 if ":" in server else socket.AF_INET

for _ in range(tries):
    txid = os.urandom(2)
    header = txid + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
    packet = header + labels + b"\x00\x01\x00\x01"
    s = socket.socket(family, socket.SOCK_DGRAM)
    s.settimeout(timeout)
    try:
        if bind_ip and (":" in bind_ip) == (family == socket.AF_INET6):
            s.bind((bind_ip, 0))
        t0 = time.perf_counter()
        s.sendto(packet, (server, port))
        data, addr = s.recvfrom(1024)
        lat = int((time.perf_counter() - t0) * 1000)
        if addr[0] != server or len(data) < 12 or data[:2] != txid:
            continue
        flags1, flags2 = data[2], data[3]
        qr = (flags1 & 0x80) != 0
        ra = (flags2 & 0x80) != 0
        rcode = flags2 & 0x0F
        ancount = struct.unpack("!H", data[6:8])[0]
        nscount = struct.unpack("!H", data[8:10])[0]
        if not qr:
            continue
        if cache_bust:
            if ra and rcode in (0, 3) and (ancount >= 1 or nscount >= 1):
                print(lat)
                sys.exit(0)
        else:
            if rcode == 0 and ancount >= 1:
                print(lat)
                sys.exit(0)
    except Exception:
        pass
    finally:
        s.close()
sys.exit(1)
' "$server" "$port" "$bind_ip" "$query_domain" "$timeout" "$tries" "$cache_bust_mode" 2>/dev/null)
        if [[ $? -eq 0 && -n "$py_lat" ]]; then
            DNS_LATENCY="$py_lat"
            DNS_SUCCESS=true
        fi
    fi
}

# Perform DNS chain queries in order across all hops (plus optional secondary upstream)
check_dns_chain() {
    local interface=$1 local_ip=$2

    PIHOLE_OK=false
    PIHOLE_LATENCY=-1
    DNSCRYPT_OK=false
    DNSCRYPT_LATENCY=-1
    CLOUDFLARE_OK=false
    CLOUDFLARE_LATENCY=-1
    UPSTREAM_SECONDARY_OK=true
    UPSTREAM_SECONDARY_LATENCY=-1

    local pi_host="${PIHOLE_DNS:-127.0.0.1}"
    local dc_host="${DNSCRYPT_HOST:-127.0.0.1}"
    local skip_dc="${SKIP_DNSCRYPT:-false}"
    local bust_cache="${BUST_DNS_CACHE:-false}"

    local upstream_ip
    upstream_ip=$(detect_upstream_dns "${UPSTREAM_DNS:-}" "${UPSTREAM_SECONDARY_DNS:-}")
    local secondary_ip="${UPSTREAM_SECONDARY_IP:-}"

    # 1. Pi-hole Check
    if check_dns "$interface" "$pi_host" "$PIHOLE_PORT" "$local_ip" "$bust_cache"; then
        PIHOLE_OK="$DNS_SUCCESS"
        PIHOLE_LATENCY="$DNS_LATENCY"
    fi

    # 2. dnscrypt-proxy Check (skipped in client mode)
    if [[ "$skip_dc" == "true" ]]; then
        DNSCRYPT_OK="true"
        DNSCRYPT_LATENCY=0
    elif check_dns "$interface" "$dc_host" "$DNSCRYPT_PORT" "$local_ip" "$bust_cache"; then
        DNSCRYPT_OK="$DNS_SUCCESS"
        DNSCRYPT_LATENCY="$DNS_LATENCY"
    fi

    # 3. Primary Configured Upstream Check (UDP/53)
    if check_dns "$interface" "$upstream_ip" "53" "$local_ip" "$bust_cache"; then
        CLOUDFLARE_OK="$DNS_SUCCESS"
        CLOUDFLARE_LATENCY="$DNS_LATENCY"
    fi

    # 4. Optional Secondary Upstream Check (when Quad9 or fallback configured)
    if [[ -n "$secondary_ip" && "$secondary_ip" != "$upstream_ip" ]]; then
        UPSTREAM_SECONDARY_OK=false
        if check_dns "$interface" "$secondary_ip" "53" "$local_ip" "$bust_cache"; then
            UPSTREAM_SECONDARY_OK="$DNS_SUCCESS"
            UPSTREAM_SECONDARY_LATENCY="$DNS_LATENCY"
        fi
    fi

    # Aggregate DNS status
    DNS_DEGRADED=false
    DNS_DEGRADED_REASON=""
    local pi_warn="${PIHOLE_LATENCY_WARN_MS:-150}"
    local dc_warn="${DNSCRYPT_LATENCY_WARN_MS:-200}"
    local up_warn="${UPSTREAM_LATENCY_WARN_MS:-200}"

    local upstream_healthy="false"
    if [[ "$CLOUDFLARE_OK" == "true" ]]; then
        upstream_healthy="true"
    elif [[ -n "$secondary_ip" && "$UPSTREAM_SECONDARY_OK" == "true" ]]; then
        upstream_healthy="true"
    fi

    if [[ "$PIHOLE_OK" == "true" && "$upstream_healthy" == "true" ]] && [[ "$skip_dc" == "true" || "$DNSCRYPT_OK" == "true" ]]; then
        DNS_OK_RESULT="true"

        # Attribute primary->secondary failover before latency warnings
        if [[ "$CLOUDFLARE_OK" != "true" && -n "$secondary_ip" && "$UPSTREAM_SECONDARY_OK" == "true" ]]; then
            DNS_DEGRADED=true
            DNS_DEGRADED_REASON="Primary upstream ($upstream_ip) failed; failover ($secondary_ip) OK"
            net_log "[$interface] Warning: DNS degraded - ${DNS_DEGRADED_REASON}"
        elif [[ -n "$secondary_ip" && "$UPSTREAM_SECONDARY_OK" != "true" ]]; then
            DNS_DEGRADED=true
            DNS_DEGRADED_REASON="Secondary upstream ($secondary_ip) unreachable"
            net_log "[$interface] Warning: DNS degraded - ${DNS_DEGRADED_REASON}"
        elif (( CLOUDFLARE_LATENCY >= up_warn )); then
            # Check downstream hops before blaming Pi-hole on uncached queries
            DNS_DEGRADED=true
            DNS_DEGRADED_REASON="High Upstream latency (${CLOUDFLARE_LATENCY}ms >= ${up_warn}ms)"
            net_log "[$interface] Warning: DNS degraded - ${DNS_DEGRADED_REASON}"
        elif [[ "$skip_dc" != "true" ]] && (( DNSCRYPT_LATENCY >= dc_warn )); then
            DNS_DEGRADED=true
            DNS_DEGRADED_REASON="High dnscrypt latency (${DNSCRYPT_LATENCY}ms >= ${dc_warn}ms)"
            net_log "[$interface] Warning: DNS degraded - ${DNS_DEGRADED_REASON}"
        elif (( PIHOLE_LATENCY >= pi_warn )); then
            DNS_DEGRADED=true
            DNS_DEGRADED_REASON="High Pi-hole latency (${PIHOLE_LATENCY}ms >= ${pi_warn}ms)"
            net_log "[$interface] Warning: DNS degraded - ${DNS_DEGRADED_REASON}"
        fi
    else
        DNS_OK_RESULT="false"
        log_dns_results "$interface" "$PIHOLE_OK" "$DNSCRYPT_OK" "$CLOUDFLARE_OK" "$upstream_ip"
        local failure_point
        failure_point=$(determine_failure_point "$PIHOLE_OK" "$DNSCRYPT_OK" "$CLOUDFLARE_OK")
        log_dns_diagnostics "$interface" "$failure_point"
        net_log "[$interface] Issue: DNS issue detected. Connectivity still OK"
    fi
}

log_dns_results() {
    local interface=$1 pihole_ok=$2 dnscrypt_ok=$3 cloudflare_ok=$4 upstream_ip=${5:-"1.1.1.1"}
    local upstream_name="Cloudflare"
    [[ "$upstream_ip" != 1.1.1.* && "$upstream_ip" != 1.0.0.* ]] && upstream_name="Upstream"
    local pi_host="${PIHOLE_DNS:-127.0.0.1}"
    local dc_host="${DNSCRYPT_HOST:-127.0.0.1}"

    [[ "$pihole_ok" == "false" ]] && net_log "[$interface] Test: Fail via Pi-hole ($pi_host:$PIHOLE_PORT)"
    [[ "$pihole_ok" == "true" ]]  && net_log "[$interface] Test: Pass via Pi-hole ($pi_host:$PIHOLE_PORT)"
    if [[ "${SKIP_DNSCRYPT:-false}" != "true" ]]; then
        [[ "$dnscrypt_ok" == "false" ]] && net_log "[$interface] Test: Fail via dnscrypt-proxy ($dc_host:${DNSCRYPT_PORT})"
        [[ "$dnscrypt_ok" == "true" ]]  && net_log "[$interface] Test: Pass via dnscrypt-proxy ($dc_host:${DNSCRYPT_PORT})"
    fi
    [[ "$cloudflare_ok" == "false" ]] && net_log "[$interface] Test: Fail via $upstream_name ($upstream_ip:53)"
    [[ "$cloudflare_ok" == "true" ]]  && net_log "[$interface] Test: Pass via $upstream_name ($upstream_ip:53)"
}

determine_failure_point() {
    local pihole_ok=$1 dnscrypt_ok=$2 cloudflare_ok=$3
    if [[ "${SKIP_DNSCRYPT:-false}" == "true" ]]; then
        if [[ "$pihole_ok" == "false" && "$cloudflare_ok" == "true" ]]; then
            echo "Pi-hole"
        elif [[ "$cloudflare_ok" == "false" ]]; then
            echo "Cloudflare"
        else
            echo ""
        fi
        return 0
    fi

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
            net_log "[$interface] Issue: Pi-hole × dnscrypt-proxy → Cloudflare"
            net_log "[$interface] Issue: Pi-hole forwarding"
            ;;
        "dnscrypt-proxy")
            net_log "[$interface] Issue: Pi-hole → dnscrypt-proxy × Cloudflare"
            net_log "[$interface] Issue: dnscrypt-proxy DoH to Cloudflare"
            ;;
        "Cloudflare")
            net_log "[$interface] Issue: Pi-hole → dnscrypt-proxy × Cloudflare"
            net_log "[$interface] Issue: upstream / Cloudflare connectivity"
            ;;
    esac
}
