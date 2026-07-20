#!/usr/bin/env bash

# internet_health_check.sh
# Purpose:  Monitor internet connectivity and DNS chain health
# Supports: Dynamic interface discovery, zero-disk-wear RAM logging, syslog alerting,
#           and modern Pi-hole v6 style HTML dashboards.

# Configuration Defaults (can be customized)
readonly PING_TARGET="1.1.1.1"
readonly DNS_TEST_DOMAIN="cloudflare.com"
readonly PING_TIMEOUT=5
readonly PING_COUNT=4

readonly PIHOLE_PORT="53"
readonly DNSCRYPT_PORT="5053"

readonly MAX_LOG_SIZE=$((2 * 1024 * 1024))   # 2 MB log rotation size
readonly MAX_ROTATIONS=7

# Globals
LOG_FILE=""
LOG_TO_FILE=false
REDUCE_DISK_WEAR=false
HTML_FILE=""
INTERFACE_OVERRIDE=""
RUN_DIAGNOSTICS=false
TAG="[INTERNET-HEALTH-CHECK]"

# Resolve script directory and source libraries
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/network.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/diagnose.sh"

# Display CLI Help Usage
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Options:
  --log-file FILE       Write logs to FILE instead of stdout
  --reduce-disk-wear    Reduce log writes: store 30-day logs in RAM (/dev/shm/),
                        only write state changes/outages to disk log.
  --html-file FILE      Generate a beautiful Pi-hole v6 style HTML status dashboard at FILE.
  --interfaces IFACES   Comma-separated list of interfaces to monitor (e.g. eth0,wlan0).
                        Defaults to auto-detecting all active interfaces.
  --diagnose            Perform a real-time terminal diagnostics scan and exit.
  -h, --help            Show this help message

Examples:
  # Run a real-time check and output to stdout
  ./internet_health_check.sh

  # Run diagnostic check and exit
  ./internet_health_check.sh --diagnose

  # Run daemon in cron, writing to RAM and logging transition alerts to disk
  ./internet_health_check.sh --log-file logs/health.log --reduce-disk-wear --html-file /var/www/html/health/index.html
EOF
}

# Auto-discover active network interfaces
discover_interfaces() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # On macOS, search for active Ethernet (en) links
        ifconfig -l | tr ' ' '\n' | grep -E '^en|^eth' || echo "en0"
    else
        # On Linux, list physical interfaces excluding local loops, bridges, and docker
        ip -o link show | awk -F': ' '{print $2}' | grep -vE 'lo|docker|veth|br-' || echo "eth0"
    fi
}

main() {
    # Parse CLI Arguments
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
            --html-file)
                HTML_FILE="$2"
                shift 2
                ;;
            --interfaces)
                INTERFACE_OVERRIDE="$2"
                shift 2
                ;;
            --diagnose)
                RUN_DIAGNOSTICS=true
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

    # 1. Check if user wants real-time diagnostics
    if [[ "$RUN_DIAGNOSTICS" == "true" ]]; then
        if [[ -n "$INTERFACE_OVERRIDE" ]]; then
            IFS=',' read -r -a custom_ifaces <<< "$INTERFACE_OVERRIDE"
            diagnose_cli "${custom_ifaces[@]}"
        else
            diagnose_cli
        fi
        exit 0
    fi

    # 2. Get target interfaces
    local interfaces=()
    if [[ -n "$INTERFACE_OVERRIDE" ]]; then
        IFS=',' read -r -a interfaces <<< "$INTERFACE_OVERRIDE"
    else
        interfaces=($(discover_interfaces))
    fi

    WRITE_OCCURRED=false
    rotate_log

    # Reset globals
    STATUS_eth0_EXISTS=false
    STATUS_wlan0_EXISTS=false

    for interface in "${interfaces[@]}"; do
        # Verify interface exists
        local link_exists=false
        if [[ "$OSTYPE" == "darwin"* ]]; then
            ifconfig "$interface" >/dev/null 2>&1 && link_exists=true
        else
            if command -v ip >/dev/null 2>&1; then
                ip link show "$interface" >/dev/null 2>&1 && link_exists=true
            elif [[ -d "/sys/class/net/$interface" ]]; then
                link_exists=true
            fi
        fi

        [[ "$link_exists" != "true" ]] && continue
        
        # Mark interface as exists
        eval "STATUS_${interface}_EXISTS=true"

        # Resolve IP on interface
        local local_ip
        local_ip=$(get_interface_ip "$interface")

        # 3. Perform Ping Connectivity check
        check_connectivity "$interface"
        local connectivity="$CONNECTIVITY_RESULT"
        local conn_lat="$CONNECTIVITY_LATENCY"
        local conn_loss="$CONNECTIVITY_LOSS"
        
        eval "STATUS_${interface}_CONNECTIVITY=\"\$connectivity\""
        eval "STATUS_${interface}_LOSS=\"\$conn_loss\""

        # 4. Perform DNS chain queries if ping is operational
        local dns_ok="true"
        local p_ok=false p_lat=-1
        local d_ok=false d_lat=-1
        local c_ok=false c_lat=-1

        if [[ "$connectivity" == "OK" && -n "$local_ip" ]]; then
            check_dns_chain "$interface" "$local_ip"
            dns_ok="$DNS_OK_RESULT"
            
            p_ok="$PIHOLE_OK"
            p_lat="$PIHOLE_LATENCY"
            d_ok="$DNSCRYPT_OK"
            d_lat="$DNSCRYPT_LATENCY"
            c_ok="$CLOUDFLARE_OK"
            c_lat="$CLOUDFLARE_LATENCY"
        else
            # Outage / Link down
            dns_ok="false"
            log "[$interface] DOWN - CONNECTIVITY OUTAGE detected"
            syslog_alert "[$interface] DOWN - Connectivity Outage detected" "user.warn"
        fi

        eval "STATUS_${interface}_DNS=\"\$dns_ok\""
        eval "STATUS_${interface}_PIHOLE=\"\$p_ok\""
        eval "STATUS_${interface}_PIHOLE_LAT=\"\$p_lat\""
        eval "STATUS_${interface}_DNSCRYPT=\"\$d_ok\""
        eval "STATUS_${interface}_DNSCRYPT_LAT=\"\$d_lat\""
        eval "STATUS_${interface}_CLOUDFLARE=\"\$c_ok\""
        eval "STATUS_${interface}_CLOUDFLARE_LAT=\"\$c_lat\""

        # 5. RAM state database logging
        record_run "$interface" "$connectivity" "$dns_ok" "$p_ok" "$d_ok" "$c_ok" "$p_lat" "$d_lat" "$c_lat" "$conn_loss"

        # 6. Smart Disk Logging (Zero Disk Wear engine)
        local log_needed=true
        if [[ "$REDUCE_DISK_WEAR" == "true" ]]; then
            log_needed=false
            
            # Write to disk log if:
            # - We detect a state change (healthy ↔ outage / warning)
            # - Current state is DOWN (failures are always logged)
            # - 24 hours have passed since the log file was updated (daily heartbeat)
            if detect_state_change "$interface" "$connectivity" "$dns_ok"; then
                log_needed=true
                syslog_alert "[$interface] State changed: Connectivity=$connectivity DNS_OK=$dns_ok" "user.notice"
            elif [[ "$connectivity" == "DOWN" || "$dns_ok" == "false" ]]; then
                log_needed=true
            else
                # Check 24 hour threshold
                local last_write_time=0
                if [[ -f "$LOG_FILE" ]]; then
                    if [[ "$OSTYPE" == "darwin"* ]]; then
                        last_write_time=$(stat -f %m "$LOG_FILE" 2>/dev/null || echo 0)
                    else
                        last_write_time=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)
                    fi
                fi
                local current_time
                current_time=$(date +%s)
                if (( current_time - last_write_time >= 86400 )); then
                    log_needed=true # Log 24-hour heartbeat
                fi
            fi
        fi

        if [[ "$log_needed" == "true" ]]; then
            if [[ "$connectivity" == "OK" && "$dns_ok" == "true" ]]; then
                log "[$interface] OK"
            fi
        fi
    done

    # 7. Dashboard JSON & HTML Generation
    if [[ -n "$HTML_FILE" ]]; then
        local target_dir
        target_dir=$(dirname "$HTML_FILE")
        
        # Write status.json to the same folder as the HTML dashboard
        generate_status_json "${target_dir}/status.json"
        
        # Copy the dashboard.html template to the target location if it changed or doesn't exist
        if [[ ! -f "$HTML_FILE" ]] || ! cmp -s "${SCRIPT_DIR}/templates/dashboard.html" "$HTML_FILE"; then
            cp -f "${SCRIPT_DIR}/templates/dashboard.html" "$HTML_FILE" 2>/dev/null || sudo cp -f "${SCRIPT_DIR}/templates/dashboard.html" "$HTML_FILE" 2>/dev/null || true
        fi
    fi
}

# Sourcing guard: Only run main if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi