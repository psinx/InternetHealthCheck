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
UPSTREAM_DNS=""
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
  --upstream-dns IP     Specify upstream DNS server IP to query (e.g. 1.1.1.3).
                        Defaults to auto-detecting server_names from /etc/dnscrypt-proxy/dnscrypt-proxy.toml.
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
                export LOG_FILE="$LOG_FILE"
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
            --upstream-dns)
                UPSTREAM_DNS="$2"
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
                echo "Unknown option: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Run diagnostics scan if requested
    if [[ "$RUN_DIAGNOSTICS" == "true" ]]; then
        diagnose_cli
        exit 0
    fi

    # Determine interfaces to check
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

    # Ensure log file rotation check if file logging enabled
    if [[ "$LOG_TO_FILE" == "true" ]]; then
        rotate_log
    fi

    # Detect upstream resolver IP (e.g. 1.1.1.3 for cloudflare-family)
    local detected_upstream
    detected_upstream=$(detect_upstream_dns "$UPSTREAM_DNS")

    # JSON accumulator structure for status generation
    local json_ifaces=""

    # Process each interface
    for iface in "${interfaces[@]}"; do
        local local_ip
        local_ip=$(get_interface_ip "$iface")

        if [[ -z "$local_ip" ]]; then
            # Interface inactive / disconnected
            CONNECTIVITY_RESULT="DOWN"
            CONNECTIVITY_LATENCY=-1
            CONNECTIVITY_LOSS=100
            PIHOLE_OK=false
            PIHOLE_LATENCY=-1
            DNSCRYPT_OK=false
            DNSCRYPT_LATENCY=-1
            CLOUDFLARE_OK=false
            CLOUDFLARE_LATENCY=-1
            DNS_OK_RESULT="false"
        else
            # 1. Connectivity ICMP Check
            check_connectivity "$iface"

            # 2. DNS Chain Resolution Check
            check_dns_chain "$iface" "$local_ip"
        fi

        # Check for state change to determine whether to write to persistent log
        if detect_state_change "$iface" "$CONNECTIVITY_RESULT" "$DNS_OK_RESULT"; then
            if [[ "$CONNECTIVITY_RESULT" == "OK" && "$DNS_OK_RESULT" == "true" ]]; then
                log "[$iface] OK"
            else
                log "[$iface] DOWN"
            fi
        fi

        # Update stateless RAM history buffer
        record_run "$iface" "$CONNECTIVITY_RESULT" "$DNS_OK_RESULT" "$PIHOLE_OK" "$DNSCRYPT_OK" "$CLOUDFLARE_OK" \
                   "$PIHOLE_LATENCY" "$DNSCRYPT_LATENCY" "$CLOUDFLARE_LATENCY" "$CONNECTIVITY_LOSS"

        # Build JSON block for interface
        local iface_exists="true"
        [[ -z "$local_ip" ]] && iface_exists="false"

        local block
        block=$(cat << EOF
    "$iface": {
      "exists": $iface_exists,
      "connectivity": "$CONNECTIVITY_RESULT",
      "dns_ok": $DNS_OK_RESULT,
      "pihole": $PIHOLE_OK,
      "dnscrypt": $DNSCRYPT_OK,
      "cloudflare": $CLOUDFLARE_OK,
      "upstream_ip": "$detected_upstream",
      "latency_pihole": $PIHOLE_LATENCY,
      "latency_dnscrypt": $DNSCRYPT_LATENCY,
      "latency_cloudflare": $CLOUDFLARE_LATENCY,
      "packet_loss": $CONNECTIVITY_LOSS
    }
EOF
)
        if [[ -n "$json_ifaces" ]]; then
            json_ifaces="$json_ifaces,$block"
        else
            json_ifaces="$block"
        fi
    done

    # Generate status.json & HTML dashboard if --html-file specified
    if [[ -n "$HTML_FILE" ]]; then
        generate_status_json "$json_ifaces" "$HTML_FILE"
    fi
}

generate_status_json() {
    local ifaces_json=$1 output_target=$2
    local target_dir
    target_dir=$(dirname "$output_target")
    mkdir -p "$target_dir" 2>/dev/null

    local json_target="$target_dir/status.json"

    # Calculate overall system health based on current live interface connectivity
    local system_status="Healthy"
    if echo "$ifaces_json" | grep -q '"connectivity": "DOWN"' || echo "$ifaces_json" | grep -q '"dns_ok": false'; then
        system_status="Degraded"
    fi

    # Build 72h historical SLA grid combining RAM buffer and persistent disk log
    local history_json
    history_json=$(build_72h_history_json)

    # Calculate 72h SLA percentage
    local sla_pct
    sla_pct=$(calculate_sla_percentage)

    # Extract recent incidents combining disk log and RAM history (strictly last 72 hours)
    local incidents_json
    incidents_json=$(extract_incidents_json)

    cat << EOF > "$json_target"
{
  "timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "status": "$system_status",
  "sla_percentage": $sla_pct,
  "interfaces": {
$ifaces_json
  },
  "history": $history_json,
  "incidents": $incidents_json
}
EOF

    # If output_target is an HTML file, copy index.html & app.js templates alongside status.json
    if [[ "$output_target" == *.html ]]; then
        if [[ -f "${SCRIPT_DIR}/templates/dashboard.html" ]]; then
            cp -f "${SCRIPT_DIR}/templates/dashboard.html" "$output_target" 2>/dev/null || true
        fi
        if [[ -f "${SCRIPT_DIR}/templates/app.js" ]]; then
            cp -f "${SCRIPT_DIR}/templates/app.js" "${target_dir}/app.js" 2>/dev/null || true
        fi
    fi
}

build_72h_history_json() {
    # Combine RAM history file and persistent disk log for exact local clock hour mapping and root-cause node health
    python3 -c '
import os, json, time
from datetime import datetime

ram_file = os.environ.get("RAM_STATE_FILE", "/dev/shm/internet_health_history.txt")
log_file = os.environ.get("LOG_FILE", "")

hours_status = {"Today": ["OK"]*24, "Yesterday": ["OK"]*24, "2 Days Ago": ["OK"]*24}
hours_earliest = {"Today": [""]*24, "Yesterday": [""]*24, "2 Days Ago": [""]*24}
hours_ifaces = {"Today": [set() for _ in range(24)],
                "Yesterday": [set() for _ in range(24)],
                "2 Days Ago": [set() for _ in range(24)]}
hours_nodes = {"Today": [{"pi": True, "dns": True, "cf": True} for _ in range(24)],
               "Yesterday": [{"pi": True, "dns": True, "cf": True} for _ in range(24)],
               "2 Days Ago": [{"pi": True, "dns": True, "cf": True} for _ in range(24)]}

now_dt = datetime.now()
today_date = now_dt.date()
current_hour = now_dt.hour

# Mark future hours today as INACTIVE (gray)
for h in range(current_hour + 1, 24):
    hours_status["Today"][h] = "INACTIVE"

# 1. Read RAM history file (stores exact per-component check booleans)
if os.path.exists(ram_file):
    with open(ram_file, "r") as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) >= 4:
                try:
                    ts = float(parts[0])
                    dt = datetime.fromtimestamp(ts)
                    iface = parts[1]
                    conn = parts[2]
                    dns = parts[3]
                    pihole_ok = (parts[5] == "true") if len(parts) > 5 else True
                    dnscrypt_ok = (parts[6] == "true") if len(parts) > 6 else True
                    cloudflare_ok = (parts[7] == "true") if len(parts) > 7 else (conn == "OK" and dns == "true")

                    days_diff = (today_date - dt.date()).days
                    if 0 <= days_diff < 3:
                        day_label = ["Today", "Yesterday", "2 Days Ago"][days_diff]
                        hour_idx = dt.hour
                        hours_nodes[day_label][hour_idx] = {"pi": pihole_ok, "dns": dnscrypt_ok, "cf": cloudflare_ok}
                        if conn == "DOWN" or dns == "false":
                            hours_status[day_label][hour_idx] = "DANGER"
                            if iface: hours_ifaces[day_label][hour_idx].add(iface)
                            if not hours_earliest[day_label][hour_idx]:
                                hours_earliest[day_label][hour_idx] = dt.strftime("%Y-%m-%d %H:%M:%S")
                except Exception:
                    pass

# 2. Read Persistent Disk Log (pinpoints exact root-cause failing components)
if log_file and os.path.exists(log_file):
    try:
        with open(log_file, "r") as f:
            for line in f:
                if "[INTERNET-HEALTH-CHECK]" in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        time_str = parts[0] + " " + parts[1]
                        try:
                            dt = datetime.strptime(time_str, "%Y-%m-%d %H:%M:%S")
                            days_diff = (today_date - dt.date()).days
                            if 0 <= days_diff < 3:
                                day_label = ["Today", "Yesterday", "2 Days Ago"][days_diff]
                                hour_idx = dt.hour
                                
                                # Track affected failing interfaces
                                if "DOWN" in line or "Fail" in line:
                                    if "[eth0]" in line: hours_ifaces[day_label][hour_idx].add("eth0")
                                    if "[wlan0]" in line: hours_ifaces[day_label][hour_idx].add("wlan0")

                                # Only trigger DANGER status for primary eth0 failure or system-wide WAN outage
                                if "CONNECTIVITY OUTAGE" in line or "Fail during Ping" in line:
                                    hours_status[day_label][hour_idx] = "DANGER"
                                    if not hours_earliest[day_label][hour_idx]:
                                        hours_earliest[day_label][hour_idx] = time_str
                                elif ("DOWN" in line or "Fail" in line) and hours_status[day_label][hour_idx] != "DANGER":
                                    hours_status[day_label][hour_idx] = "WARNING"
                                    if not hours_earliest[day_label][hour_idx]:
                                        hours_earliest[day_label][hour_idx] = time_str
                                    
                                # Mark specific component failures across the chain
                                if "Fail via Pi-hole" in line:
                                    hours_nodes[day_label][hour_idx]["pi"] = False
                                elif "Fail via dnscrypt" in line:
                                    hours_nodes[day_label][hour_idx]["dns"] = False
                                elif "Fail via Cloudflare" in line or "CONNECTIVITY OUTAGE" in line or "Fail during Ping" in line:
                                    hours_nodes[day_label][hour_idx]["cf"] = False
                        except Exception:
                            pass
    except Exception:
        pass

result = []
for label in ["2 Days Ago", "Yesterday", "Today"]:
    day_cells = []
    for h in range(24):
        st = hours_status[label][h]
        earliest = hours_earliest[label][h] if st != "OK" else ""
        nodes = hours_nodes[label][h] if st != "OK" else {"pi": True, "dns": True, "cf": True}
        iface_list = sorted(list(hours_ifaces[label][h])) if st != "OK" else []
        iface_str = ", ".join(iface_list)
        day_cells.append({
            "hour": h,
            "status": st,
            "uptime": 100 if st == "OK" else 0,
            "earliest_issue": earliest,
            "iface": iface_str,
            "pihole": nodes["pi"],
            "dnscrypt": nodes["dns"],
            "cloudflare": nodes["cf"]
        })
    result.append({"label": label, "hours": day_cells})

print(json.dumps(result))
' 2>/dev/null || echo '[{"label":"2 Days Ago","hours":[]},{"label":"Yesterday","hours":[]},{"label":"Today","hours":[]}]'
}

calculate_sla_percentage() {
    python3 -c '
import os, json, time
from datetime import datetime

ram_file = os.environ.get("RAM_STATE_FILE", "/dev/shm/internet_health_history.txt")
log_file = os.environ.get("LOG_FILE", "")

hours_status = {"Today": ["OK"]*24, "Yesterday": ["OK"]*24, "2 Days Ago": ["OK"]*24}

now_dt = datetime.now()
today_date = now_dt.date()
current_hour = now_dt.hour

for h in range(current_hour + 1, 24):
    hours_status["Today"][h] = "INACTIVE"

if ram_file and os.path.exists(ram_file):
    try:
        with open(ram_file, "r") as f:
            for line in f:
                parts = line.strip().split(",")
                if len(parts) >= 4:
                    try:
                        ts = float(parts[0])
                        dt = datetime.fromtimestamp(ts)
                        conn = parts[2]
                        dns = parts[3]
                        days_diff = (today_date - dt.date()).days
                        if 0 <= days_diff < 3:
                            day_label = ["Today", "Yesterday", "2 Days Ago"][days_diff]
                            hour_idx = dt.hour
                            if conn == "DOWN" or dns == "false":
                                hours_status[day_label][hour_idx] = "DANGER"
                    except Exception:
                        pass
    except Exception:
        pass

if log_file and os.path.exists(log_file):
    try:
        with open(log_file, "r") as f:
            for line in f:
                if "[INTERNET-HEALTH-CHECK]" in line:
                    parts = line.strip().split()
                    if len(parts) >= 2:
                        try:
                            dt = datetime.strptime(parts[0] + " " + parts[1], "%Y-%m-%d %H:%M:%S")
                            days_diff = (today_date - dt.date()).days
                            if 0 <= days_diff < 3:
                                day_label = ["Today", "Yesterday", "2 Days Ago"][days_diff]
                                hour_idx = dt.hour
                                if "DOWN" in line or "Fail" in line:
                                    if "[wlan0]" not in line or "CONNECTIVITY OUTAGE" in line:
                                        hours_status[day_label][hour_idx] = "DANGER"
                        except Exception:
                            pass
    except Exception:
        pass

active_hours = 0
healthy_hours = 0
for label in ["2 Days Ago", "Yesterday", "Today"]:
    for h in range(24):
        st = hours_status[label][h]
        if st != "INACTIVE":
            active_hours += 1
            if st == "OK":
                healthy_hours += 1

pct = (healthy_hours / active_hours * 100.0) if active_hours > 0 else 100.0
print(f"{pct:.2f}")
' 2>/dev/null || echo "100.00"
}

extract_incidents_json() {
    python3 -c '
import os, json, time
from datetime import datetime

ram_file = os.environ.get("RAM_STATE_FILE", "/dev/shm/internet_health_history.txt")
log_file = os.environ.get("LOG_FILE", "")
incidents = []
seen_events = set()
now = time.time()
max_age_seconds = 72 * 3600 # Strictly last 72 hours (259,200 seconds)

# Parse persistent disk log first for reboot survival (strictly last 72 hours)
if log_file and os.path.exists(log_file):
    try:
        with open(log_file, "r") as f:
            lines = f.readlines()
        for line in reversed(lines):
            if "[INTERNET-HEALTH-CHECK]" in line and "DOWN" in line:
                parts = line.strip().split()
                if len(parts) >= 2:
                    time_str = parts[0] + " " + parts[1]
                    try:
                        dt = datetime.strptime(time_str, "%Y-%m-%d %H:%M:%S")
                        ts = dt.timestamp()
                        if (now - ts) <= max_age_seconds:
                            iface = "eth0" if "[eth0]" in line else ("wlan0" if "[wlan0]" in line else "eth0")
                            key = f"{time_str}_{iface}"
                            if key not in seen_events:
                                seen_events.add(key)
                                is_total_outage = (iface == "eth0" or "CONNECTIVITY OUTAGE" in line)
                                incidents.append({
                                    "type": "outage" if is_total_outage else "warning",
                                    "badge": "Outage" if is_total_outage else "Warning",
                                    "timestamp": f"{time_str} ({iface})",
                                    "description": "DOWN - CONNECTIVITY OUTAGE detected" if is_total_outage else f"Interface link down ({iface})",
                                    "duration": ""
                                })
                                if len(incidents) >= 10:
                                    break
                    except Exception:
                        pass
    except Exception:
        pass

# Supplement from RAM file if available (strictly last 72 hours)
if len(incidents) < 10 and os.path.exists(ram_file):
    try:
        with open(ram_file, "r") as f:
            lines = f.readlines()
        for line in reversed(lines):
            parts = line.strip().split(",")
            if len(parts) >= 4 and (parts[2] == "DOWN" or parts[3] == "false"):
                try:
                    ts = float(parts[0])
                    if (now - ts) <= max_age_seconds:
                        dt = datetime.fromtimestamp(ts)
                        ts_str = dt.strftime("%Y-%m-%d %H:%M:%S")
                        iface = parts[1] if len(parts) > 1 else "wlan0"
                        key = f"{ts_str}_{iface}"
                        if key not in seen_events:
                            seen_events.add(key)
                            is_total_outage = (iface == "eth0" or parts[2] == "DOWN")
                            incidents.append({
                                "type": "outage" if is_total_outage else "warning",
                                "badge": "Outage" if is_total_outage else "Warning",
                                "timestamp": f"{ts_str} ({iface})",
                                "description": "DOWN - CONNECTIVITY OUTAGE detected" if is_total_outage else f"Interface link down ({iface})",
                                "duration": ""
                            })
                            if len(incidents) >= 10:
                                break
                except Exception:
                    pass
    except Exception:
        pass

print(json.dumps(incidents))
' 2>/dev/null || echo '[]'
}

main "$@"