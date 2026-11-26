#!/usr/bin/env bash

# internet_health_check.sh
# Purpose:  Monitor internet connectivity and DNS chain health
# Supports: Dynamic interface discovery, zero-disk-wear RAM logging, syslog/webhook alerting,
#           out-of-band canary push, and modern Pi-hole v6 style HTML dashboards.

readonly PING_TARGET="1.1.1.1"
readonly DNS_TEST_DOMAIN="cloudflare.com"
readonly PING_TIMEOUT=5
readonly PING_COUNT="${PING_COUNT:-10}"

readonly PIHOLE_PORT="53"
readonly DNSCRYPT_PORT="5053"
export PIHOLE_PORT DNSCRYPT_PORT
readonly DNS_TIMEOUT=3
readonly DNS_TRIES=2

readonly MAX_LOG_SIZE=$((2 * 1024 * 1024))   # 2 MB log rotation size
readonly MAX_ROTATIONS=7

# Globals
LOG_FILE=""
LOG_TO_FILE=false
REDUCE_DISK_WEAR=false
HTML_FILE=""
INTERFACE_OVERRIDE=""
UPSTREAM_DNS=""
UPSTREAM_SECONDARY_DNS="${UPSTREAM_SECONDARY_DNS:-}"
OUTPUT_FORMAT=""
PIHOLE_DNS="${PIHOLE_DNS:-}"
DNSCRYPT_HOST="${DNSCRYPT_HOST:-}"
SKIP_DNSCRYPT="${SKIP_DNSCRYPT:-false}"
BUST_DNS_CACHE="${BUST_DNS_CACHE:-false}"
ENABLE_SYSLOG=false
WEBHOOK_URL="${WEBHOOK_URL:-}"
CANARY_PUSH_TARGET="${CANARY_PUSH_TARGET:-}"
CANARY_SSH_KEY="${CANARY_SSH_KEY:-}"
TAG="[INTERNET-HEALTH-CHECK]"

if [[ -z "${DEFAULT_RAM_DIR:-}" ]]; then
    if [[ -d "/tmp" && "$(df -PT /tmp 2>/dev/null | awk 'NR==2{print $2}')" == "tmpfs" ]]; then
        DEFAULT_RAM_DIR="/tmp"
    elif [[ -d "/dev/shm" ]]; then
        DEFAULT_RAM_DIR="/dev/shm"
    else
        DEFAULT_RAM_DIR="/tmp"
    fi
fi
export RAM_STATE_FILE="${RAM_STATE_FILE:-${DEFAULT_RAM_DIR}/internet_health_history.txt}"

export SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/display.sh"

usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --log-file FILE             Write logs to FILE instead of stdout
  --reduce-disk-wear          Reduce log writes: store 30-day logs in RAM (${DEFAULT_RAM_DIR}/),
                              only write state changes/outages and hourly OK heartbeats to disk log.
  --format FORMAT             Output format: 'pretty' (visual checklist) or 'log' (syslog style).
                              Defaults to 'pretty' in interactive terminals, 'log' when piped/cron.
  --dashboard FILE            Deploy the Pi-hole v6 style web dashboard (index.html, app.js) at FILE
                              and write status.json alongside it.
  --interfaces IFACES         Comma-separated list of interfaces to monitor (e.g. eth0,wlan0).
                              Defaults to auto-detecting all physical interfaces.
  --pihole-dns HOST           Primary DNS resolver (Pi-hole, router, Unbound...) to test (defaults to
                              127.0.0.1 on server, or auto-discovered system nameserver on macOS clients).
  --dnscrypt-host HOST        dnscrypt-proxy host to test (defaults to 127.0.0.1).
  --skip-dnscrypt             Skip Hop 2 dnscrypt check (useful for client machines on LAN).
  --upstream-dns HOST         Specify upstream DNS server IP/hostname to query (e.g. 1.1.1.3).
  --upstream-secondary-dns H  Specify secondary upstream DNS IP to probe (e.g. 9.9.9.9).
  --bust-dns-cache            Probe an uncached nonce subdomain to bypass Pi-hole / dnscrypt caches.
  --syslog                    Emit state-transition alerts to local syslog.
  --webhook-url URL           POST JSON state-transition alerts to WEBHOOK_URL.
  --canary-push-target T      Stream generated status.json via SSH stdin to receiver USER@HOST.
  --canary-ssh-key PATH       SSH private key for --canary-push-target.
  -h, --help                  Show this help message

Examples:
  ./internet_health_check.sh
  ./internet_health_check.sh --format log
  ./internet_health_check.sh --pihole-dns 192.168.1.2 --skip-dnscrypt --bust-dns-cache
  ./internet_health_check.sh --reduce-disk-wear --log-file logs/health.log --dashboard /var/www/html/index.html
EOF
}

discover_interfaces() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        local active_ifaces=()
        for iface in $(ifconfig -l 2>/dev/null | tr ' ' '\n' | grep -E '^en[0-9]+$'); do
            if [[ "$iface" == "en0" ]] || ifconfig "$iface" 2>/dev/null | grep -qE 'status: active|inet '; then
                active_ifaces+=("$iface")
            fi
        done
        if (( ${#active_ifaces[@]} > 0 )); then
            printf '%s\n' "${active_ifaces[@]}"
        else
            echo "en0"
        fi
    elif command -v ip >/dev/null 2>&1; then
        ip -o link show 2>/dev/null \
            | awk -F': ' '{print $2}' \
            | cut -d'@' -f1 \
            | grep -vE '^(lo|docker|veth|br-|virbr|lxcbr|cni|podman|flannel|tailscale|tun|tap|wg|zt|sit|gre|p2p-)' \
            || echo "eth0"
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig -s 2>/dev/null \
            | awk '{print $1}' \
            | cut -d'@' -f1 \
            | grep -vE '^(Iface|lo|docker|veth|br-|virbr|lxcbr|cni|podman|flannel|tailscale|tun|tap|wg|zt|sit|gre|p2p-)' \
            || echo "eth0"
    else
        echo "eth0"
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --log-file)
                LOG_FILE="$2"
                LOG_TO_FILE=true
                export LOG_FILE="$LOG_FILE"
                mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
                shift 2
                ;;
            --reduce-disk-wear)
                REDUCE_DISK_WEAR=true
                shift
                ;;
            --format)
                OUTPUT_FORMAT="$2"
                shift 2
                ;;
            --dashboard)
                HTML_FILE="$2"
                shift 2
                ;;
            --interfaces)
                INTERFACE_OVERRIDE="$2"
                shift 2
                ;;
            --pihole-dns)
                PIHOLE_DNS="$2"
                shift 2
                ;;
            --dnscrypt-host)
                DNSCRYPT_HOST="$2"
                DNSCRYPT_HOST_SPECIFIED=true
                shift 2
                ;;
            --skip-dnscrypt)
                SKIP_DNSCRYPT=true
                shift
                ;;
            --upstream-dns)
                UPSTREAM_DNS="$2"
                shift 2
                ;;
            --upstream-secondary-dns)
                UPSTREAM_SECONDARY_DNS="$2"
                shift 2
                ;;
            --bust-dns-cache)
                BUST_DNS_CACHE=true
                shift
                ;;
            --syslog)
                ENABLE_SYSLOG=true
                shift
                ;;
            --webhook-url)
                WEBHOOK_URL="$2"
                shift 2
                ;;
            --canary-push-target)
                CANARY_PUSH_TARGET="$2"
                shift 2
                ;;
            --canary-ssh-key)
                CANARY_SSH_KEY="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Acquire exclusive non-blocking lock (flock on Linux; mkdir+PID lock on macOS/BSD)
    local lock_file="${DEFAULT_RAM_DIR}/internet_health_check.lock"
    local lock_fd=200
    local locked_flock=false
    local locked_mkdir=false
    if command -v flock >/dev/null 2>&1; then
        exec 200>"${lock_file}"
        if ! flock -n ${lock_fd}; then
            echo "$TAG Another instance is already running. Exiting." >&2
            return 0
        fi
        locked_flock=true
    else
        local lock_dir="${lock_file}.d"
        if ! mkdir "$lock_dir" 2>/dev/null; then
            local existing_pid
            existing_pid=$(cat "$lock_dir/pid" 2>/dev/null || echo "")
            if [[ -n "$existing_pid" ]] && kill -0 "$existing_pid" 2>/dev/null; then
                echo "$TAG Another instance is already running. Exiting." >&2
                return 0
            fi
            rm -rf "$lock_dir" 2>/dev/null
            mkdir "$lock_dir" 2>/dev/null || return 0
        fi
        echo "$$" > "$lock_dir/pid" 2>/dev/null || true
        locked_mkdir=true
    fi

    # Resolve target DNS hosts
    if [[ -z "$PIHOLE_DNS" ]]; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if command -v nc >/dev/null 2>&1 && nc -z -w1 127.0.0.1 53 >/dev/null 2>&1; then
                PIHOLE_DNS="127.0.0.1"
            else
                local sys_dns=""
                if command -v scutil >/dev/null 2>&1; then
                    sys_dns=$(scutil --dns 2>/dev/null | grep 'nameserver\[0\]' | head -n1 | awk '{print $3}')
                fi
                [[ -z "$sys_dns" && -f "/etc/resolv.conf" ]] && sys_dns=$(grep -E '^nameserver' /etc/resolv.conf 2>/dev/null | head -n1 | awk '{print $2}')
                PIHOLE_DNS="${sys_dns:-127.0.0.1}"
            fi
        else
            PIHOLE_DNS="127.0.0.1"
        fi
    fi
    export PIHOLE_DNS

    DNSCRYPT_HOST="${DNSCRYPT_HOST:-127.0.0.1}"
    export DNSCRYPT_HOST

    if [[ "$OSTYPE" == "darwin"* && "$PIHOLE_DNS" != "127.0.0.1" && "${DNSCRYPT_HOST_SPECIFIED:-false}" != "true" ]]; then
        SKIP_DNSCRYPT=true
    fi
    export SKIP_DNSCRYPT
    export BUST_DNS_CACHE
    export UPSTREAM_SECONDARY_DNS

    if [[ -z "$OUTPUT_FORMAT" ]]; then
        if [[ -t 1 ]]; then
            OUTPUT_FORMAT="pretty"
        else
            OUTPUT_FORMAT="log"
        fi
    fi
    export OUTPUT_FORMAT="$OUTPUT_FORMAT"

    local interfaces=()
    if [[ -n "$INTERFACE_OVERRIDE" ]]; then
        IFS=',' read -ra interfaces <<< "$INTERFACE_OVERRIDE"
    else
        while IFS= read -r iface; do
            [[ -n "$iface" ]] && interfaces+=("$iface")
        done < <(discover_interfaces)
    fi

    if [[ ${#interfaces[@]} -eq 0 ]]; then
        log "Error: No valid network interfaces discovered."
        exit 1
    fi

    if [[ "$LOG_TO_FILE" == "true" ]]; then
        rotate_log
    fi

    local detected_upstream
    detect_upstream_dns "$UPSTREAM_DNS" "$UPSTREAM_SECONDARY_DNS" >/dev/null
    detected_upstream="$UPSTREAM_PRIMARY_IP"
    local detected_secondary="${UPSTREAM_SECONDARY_IP:-}"

    if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
        print_pretty_header
    fi

    # Tab-delimited interface records safely passed to Python telemetry builder
    local tsv_ifaces=""

    for iface in "${interfaces[@]}"; do
        # Reset all per-interface globals so nothing leaks from previous interface
        DIAG_LOG_LINES=()
        CONNECTIVITY_RESULT="DOWN"
        CONNECTIVITY_LATENCY=-1
        CONNECTIVITY_LOSS=100
        CONNECTIVITY_DEGRADED=false
        CONNECTIVITY_DEGRADED_REASON=""
        PIHOLE_OK=false
        PIHOLE_LATENCY=-1
        DNSCRYPT_OK=false
        DNSCRYPT_LATENCY=-1
        CLOUDFLARE_OK=false
        CLOUDFLARE_LATENCY=-1
        UPSTREAM_SECONDARY_OK=true
        UPSTREAM_SECONDARY_LATENCY=-1
        DNS_OK_RESULT="false"
        DNS_DEGRADED=false
        DNS_DEGRADED_REASON=""

        local iface_exists="false"
        if [[ "$OSTYPE" == "darwin"* ]]; then
            ifconfig "$iface" >/dev/null 2>&1 && iface_exists="true"
        elif [[ -d "${NET_SYSFS_ROOT:-/sys/class/net}/$iface" ]]; then
            iface_exists="true"
        elif command -v ip >/dev/null 2>&1 && ip link show "$iface" >/dev/null 2>&1; then
            iface_exists="true"
        fi

        local admin_up
        admin_up=$(get_interface_admin_up "$iface")
        local carrier
        carrier=$(get_interface_carrier "$iface")
        local local_ip
        local_ip=$(get_interface_ip "$iface")
        local has_ip="false"
        [[ -n "$local_ip" ]] && has_ip="true"

        local client_ok="true"
        local iface_state="online"
        local is_iface_degraded="false"
        local iface_deg_reason=""

        if (( admin_up == 0 )); then
            # Administratively down / unused NIC (e.g. disabled wlan0 on wired host)
            iface_state="unused"
            CONNECTIVITY_RESULT="UNUSED"
            CONNECTIVITY_LOSS=0
            DNS_OK_RESULT="true"
            PIHOLE_OK="null"
            DNSCRYPT_OK="null"
            CLOUDFLARE_OK="null"
            UPSTREAM_SECONDARY_OK="null"
        elif [[ -z "$local_ip" || "$carrier" -eq 0 ]]; then
            iface_state="down"
            CONNECTIVITY_RESULT="DOWN"
            CONNECTIVITY_LATENCY=-1
            CONNECTIVITY_LOSS=100
            client_ok="false"
            DNS_OK_RESULT="false"
            PIHOLE_OK="null"
            DNSCRYPT_OK="null"
            CLOUDFLARE_OK="null"
            UPSTREAM_SECONDARY_OK="null"
            if (( carrier == 0 )); then
                net_log "[$iface] Test: Fail - Physical Link DISCONNECTED / NO CARRIER"
            else
                net_log "[$iface] Test: Fail - No IP address assigned (DHCP missing)"
            fi
        else
            check_connectivity "$iface" "$local_ip"
            check_dns_chain "$iface" "$local_ip"

            if [[ "$DNS_DEGRADED" == "true" ]]; then
                is_iface_degraded="true"
                iface_deg_reason="$DNS_DEGRADED_REASON"
            elif [[ "$CONNECTIVITY_DEGRADED" == "true" ]]; then
                is_iface_degraded="true"
                iface_deg_reason="$CONNECTIVITY_DEGRADED_REASON"
            fi

            if [[ "$CONNECTIVITY_RESULT" != "OK" || "$DNS_OK_RESULT" != "true" ]]; then
                iface_state="down"
            elif [[ "$is_iface_degraded" == "true" ]]; then
                iface_state="degraded"
            else
                iface_state="online"
            fi
        fi

        # Disk logging & alerting MUST evaluate detect_state_change BEFORE record_run()
        if [[ "$iface_state" != "unused" ]]; then
            local status_word="DOWN"
            if [[ "$CONNECTIVITY_RESULT" == "OK" && "$DNS_OK_RESULT" == "true" ]]; then
                if [[ "$is_iface_degraded" == "true" ]]; then
                    status_word="DEGRADED"
                else
                    status_word="OK"
                fi
            fi

            local changed=1
            if detect_state_change "$iface" "$CONNECTIVITY_RESULT" "$DNS_OK_RESULT" "$is_iface_degraded"; then
                changed=0
            fi

            if [[ "$REDUCE_DISK_WEAR" != "true" ]] || (( changed == 0 )); then
                if (( ${#DIAG_LOG_LINES[@]} > 0 )); then
                    for dline in "${DIAG_LOG_LINES[@]}"; do
                        log "$dline"
                    done
                fi
                if [[ "$status_word" == "DEGRADED" && -n "$iface_deg_reason" ]]; then
                    log "[$iface] DEGRADED - $iface_deg_reason"
                else
                    log "[$iface] $status_word"
                fi
            elif [[ "$status_word" == "OK" ]] && should_log_hourly_heartbeat "$iface"; then
                log "[$iface] OK"
            fi

            if (( changed == 0 )); then
                local alert_msg="[$iface] State transition -> $status_word${iface_deg_reason:+ ($iface_deg_reason)}"
                [[ "$ENABLE_SYSLOG" == "true" ]] && syslog_alert "$alert_msg" "user.warning"
                [[ -n "${WEBHOOK_URL:-}" ]] && send_webhook_alert "$iface" "$status_word" "$alert_msg"
            fi

            record_run "$iface" "$CONNECTIVITY_RESULT" "$DNS_OK_RESULT" "$PIHOLE_OK" "$DNSCRYPT_OK" "$CLOUDFLARE_OK" \
                       "$PIHOLE_LATENCY" "$DNSCRYPT_LATENCY" "$CLOUDFLARE_LATENCY" "$CONNECTIVITY_LOSS" \
                       "$client_ok" "$iface_state" "$CONNECTIVITY_LATENCY"
        fi

        if [[ "$OUTPUT_FORMAT" == "pretty" ]]; then
            print_pretty_interface "$iface" "$local_ip" "$carrier" \
                "$CONNECTIVITY_RESULT" "$CONNECTIVITY_LATENCY" "$CONNECTIVITY_LOSS" \
                "$PIHOLE_OK" "$PIHOLE_LATENCY" "$DNSCRYPT_OK" "$DNSCRYPT_LATENCY" \
                "$CLOUDFLARE_OK" "$CLOUDFLARE_LATENCY" "$detected_upstream" "$DNS_OK_RESULT" \
                "$admin_up" "$iface_deg_reason" "$detected_secondary" "$UPSTREAM_SECONDARY_OK" "$UPSTREAM_SECONDARY_LATENCY"
        fi

        # Sanitize reason string for TSV transport
        local safe_reason="${iface_deg_reason//$'\t'/ }"
        safe_reason="${safe_reason//$'\n'/ }"
        local row
        row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
            "$iface" "$iface_exists" "$admin_up" "$carrier" "$has_ip" "$local_ip" "$iface_state" \
            "$CONNECTIVITY_RESULT" "$DNS_OK_RESULT" "$is_iface_degraded" "$safe_reason" "$client_ok" \
            "$PIHOLE_OK" "$DNSCRYPT_OK" "$CLOUDFLARE_OK" "$UPSTREAM_SECONDARY_OK" \
            "$detected_upstream" "$detected_secondary" \
            "$CONNECTIVITY_LATENCY" "$PIHOLE_LATENCY" "$DNSCRYPT_LATENCY" "$CLOUDFLARE_LATENCY" \
            "$UPSTREAM_SECONDARY_LATENCY" )
        row="${row}"$'\t'"${CONNECTIVITY_LOSS}"
        if [[ -n "$tsv_ifaces" ]]; then
            tsv_ifaces="${tsv_ifaces}"$'\n'"${row}"
        else
            tsv_ifaces="${row}"
        fi
    done

    if [[ -n "$HTML_FILE" ]]; then
        generate_status_json "$tsv_ifaces" "$HTML_FILE" "$detected_upstream" "$detected_secondary"
    fi

    if [[ "$locked_flock" == "true" ]]; then
        flock -u ${lock_fd} 2>/dev/null || true
        exec 200>&- 2>/dev/null || true
    elif [[ "$locked_mkdir" == "true" ]]; then
        rm -rf "${lock_file}.d" 2>/dev/null || true
    fi
}

generate_status_json() {
    local tsv_ifaces=$1 output_target=$2 upstream_ip=${3:-"1.1.1.1"} secondary_ip=${4:-""}
    local target_dir
    target_dir=$(dirname "$output_target")
    mkdir -p "$target_dir" 2>/dev/null

    local json_target="$target_dir/status.json"
    local dest_file
    local tmp_dir

    if [[ "$REDUCE_DISK_WEAR" == "true" && -d "$DEFAULT_RAM_DIR" ]]; then
        dest_file="${DEFAULT_RAM_DIR}/status.json"
        tmp_dir="${DEFAULT_RAM_DIR}"
    else
        dest_file=$(realpath "$json_target" 2>/dev/null || echo "$json_target")
        tmp_dir=$(dirname "$dest_file")
    fi

    local json_tmp="${tmp_dir}/.status.json.tmp.$$.${RANDOM}"

    local host_name
    host_name=$(hostname 2>/dev/null || echo "unknown")

    local telemetry_args=(--out "$json_tmp" --ram-file "$RAM_STATE_FILE")
    [[ "$LOG_TO_FILE" == "true" && -n "$LOG_FILE" ]] && telemetry_args+=(--log-file "$LOG_FILE")

    # Build JSON safely via Python (zero raw bash JSON string interpolation) and pipe to telemetry.py
    local py_err
    if ! printf '%s\n' "$tsv_ifaces" | python3 -c '
import json, os, sys

def b(s):
    v = s.strip().lower()
    if v in ("true", "1", "yes"): return True
    if v in ("false", "0", "no"): return False
    return None

def n(s, default=-1):
    try: return int(float(s))
    except Exception: return default

def f(s, default=0.0):
    try: return float(s)
    except Exception: return default

ifaces = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    cols = line.split("\t")
    if len(cols) < 24:
        continue
    name = cols[0]
    ifaces[name] = {
        "exists": b(cols[1]) is True,
        "admin_up": (cols[2] == "1"),
        "carrier": n(cols[3], 0),
        "has_ip": b(cols[4]) is True,
        "ip": cols[5],
        "state": cols[6],
        "connectivity": cols[7],
        "dns_ok": b(cols[8]) is True,
        "degraded": b(cols[9]) is True,
        "degradation_reason": cols[10],
        "client_ok": b(cols[11]) is True,
        "pihole": b(cols[12]),
        "dnscrypt": b(cols[13]),
        "cloudflare": b(cols[14]),
        "upstream_secondary_ok": b(cols[15]),
        "upstream_ip": cols[16],
        "upstream_secondary_ip": cols[17],
        "latency_ping": f(cols[18], -1.0),
        "latency_pihole": n(cols[19], -1),
        "latency_dnscrypt": n(cols[20], -1),
        "latency_cloudflare": n(cols[21], -1),
        "latency_upstream_secondary": n(cols[22], -1),
        "packet_loss": f(cols[23], 0.0),
    }

pi_host = os.environ.get("PIHOLE_DNS", "127.0.0.1")
dc_host = os.environ.get("DNSCRYPT_HOST", "127.0.0.1")
pi_port = os.environ.get("PIHOLE_PORT", "53")
dc_port = os.environ.get("DNSCRYPT_PORT", "5053")
payload = {
    "metadata": {
        "host": sys.argv[1],
        "pihole_target": pi_host + ":" + pi_port,
        "dnscrypt_target": dc_host + ":" + dc_port,
        "skip_dnscrypt": os.environ.get("SKIP_DNSCRYPT", "false") == "true",
        "upstream_ip": sys.argv[2],
        "upstream_secondary_ip": sys.argv[3],
        "upstream_protocol": "UDP/53",
        "cache_busted": os.environ.get("BUST_DNS_CACHE", "false") == "true",
        "thresholds": {
            "pihole_ms": n(os.environ.get("PIHOLE_LATENCY_WARN_MS", "150"), 150),
            "dnscrypt_ms": n(os.environ.get("DNSCRYPT_LATENCY_WARN_MS", "200"), 200),
            "upstream_ms": n(os.environ.get("UPSTREAM_LATENCY_WARN_MS", "200"), 200),
            "loss_pct": f(os.environ.get("PACKET_LOSS_WARN_PCT", "5"), 5.0),
        },
    },
    "interfaces": ifaces,
}
print(json.dumps(payload))
' "$host_name" "$upstream_ip" "$secondary_ip" | python3 "${SCRIPT_DIR}/lib/telemetry.py" "${telemetry_args[@]}"; then
        echo "$TAG Telemetry aggregator failed for $dest_file" >&2
        rm -f "$json_tmp" 2>/dev/null || true
        return 1
    fi

    # Atomic same-filesystem move + clean 644 permissions
    chmod 644 "$json_tmp" 2>/dev/null || true
    mv -f "$json_tmp" "$dest_file" 2>/dev/null || { rm -f "$json_tmp" 2>/dev/null || true; return 1; }

    if [[ "$REDUCE_DISK_WEAR" == "true" && -d "$DEFAULT_RAM_DIR" ]]; then
        if [[ ! -L "$json_target" || "$(readlink "$json_target" 2>/dev/null)" != "$dest_file" ]]; then
            ln -sf "$dest_file" "$json_target" 2>/dev/null || true
        fi
    fi

    # Copy static web assets only when changed (prevents disk wear)
    if [[ "$output_target" == *.html ]]; then
        if [[ -f "${SCRIPT_DIR}/templates/index.html" ]]; then
            if [[ ! -f "$output_target" ]] || ! cmp -s "${SCRIPT_DIR}/templates/index.html" "$output_target"; then
                cp -f "${SCRIPT_DIR}/templates/index.html" "$output_target" 2>/dev/null || true
            fi
        fi
        if [[ -f "${SCRIPT_DIR}/templates/app.js" ]]; then
            local target_js="${target_dir}/app.js"
            if [[ ! -f "$target_js" ]] || ! cmp -s "${SCRIPT_DIR}/templates/app.js" "$target_js"; then
                cp -f "${SCRIPT_DIR}/templates/app.js" "$target_js" 2>/dev/null || true
            fi
        fi
    fi

    # Push canary telemetry to central dashboard host if configured
    if [[ -n "${CANARY_PUSH_TARGET:-}" && -s "$dest_file" ]]; then
        local ssh_opts=(-o BatchMode=yes -o ConnectTimeout=5)
        [[ -n "${CANARY_SSH_KEY:-}" ]] && ssh_opts+=(-i "$CANARY_SSH_KEY")
        ssh "${ssh_opts[@]}" "$CANARY_PUSH_TARGET" < "$dest_file" >/dev/null 2>&1 || true
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
