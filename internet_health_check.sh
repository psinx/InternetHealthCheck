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
    
    # Get log file's modification time and current time
    local log_mod_time
    log_mod_time=$(stat -c %Y "$LOG_FILE" 2>/dev/null) || log_mod_time=0
    local current_time
    current_time=$(date +%s)
    local hours_24=$(( 24 * 60 * 60 ))

    # If more than 24 hours since last write, always log
    if (( current_time - log_mod_time >= hours_24 )); then
        return 0
    fi

    # Find the LAST entry (any status) for THIS interface to detect state changes
    local last_entry
    last_entry=$(grep -a -F "[$interface]" "$LOG_FILE" 2>/dev/null | tail -1)
    
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

    # If conversion failed, be conservative and log
    if [[ "$last_sec" -le 0 ]]; then
        return 0
    fi

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
            [[ -f "$old" ]] && mv -f "$old" "$new" 2>/dev/null
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
        log "[$interface] Test: Fail during Ping - $PING_TARGET did not respond"
        echo "DOWN"
    fi
}

#=============================================================================
# DNS chain checks
#=============================================================================

check_dns() {
    local interface=$1 server=$2 port=$3
    local local_ip
    local_ip=$(ip -4 addr show "$interface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    [[ -z "$local_ip" ]] && return 1
    dig +short "$DNS_TEST_DOMAIN" "@$server" -p "$port" -b "$local_ip" >/dev/null 2>&1
}

log_dns_results() {
    local interface=$1 pihole_ok=$2 dnscrypt_ok=$3 cloudflare_ok=$4
    
    # Only log detailed results if there's a problem
    if [[ "$pihole_ok" == "false" || "$dnscrypt_ok" == "false" || "$cloudflare_ok" == "false" ]]; then
        [[ "$pihole_ok" == "false" ]] && log "[$interface] Test: Fail via Pi-hole (127.0.0.1:$PIHOLE_PORT)"
        [[ "$pihole_ok" == "true" ]] && log "[$interface] Test: Pass via Pi-hole (127.0.0.1:$PIHOLE_PORT)"
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
    check_dns "$interface" "127.0.0.1" "$PIHOLE_PORT"   && pihole_ok=true
    check_dns "$interface" "127.0.0.1" "$DNSCRYPT_PORT" && dnscrypt_ok=true
    check_dns "$interface" "1.1.1.1"   "53"             && cloudflare_ok=true
    
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
    
    # Save results to global variables for HTML dashboard
    eval "STATUS_${interface}_PIHOLE=\"\$pihole_ok\""
    eval "STATUS_${interface}_DNSCRYPT=\"\$dnscrypt_ok\""
    eval "STATUS_${interface}_CLOUDFLARE=\"\$cloudflare_ok\""
    
    DNS_OK_RESULT="$dns_ok"
}

#=============================================================================
# HTML Dashboard Generation
#=============================================================================

generate_html_page() {
    local temp_html="/tmp/$(basename "$HTML_FILE").tmp"
    
    # Check overall status
    local overall_status="Healthy"
    local overall_class="status-healthy"
    local overall_desc="All interfaces are online and DNS services are fully operational."
    
    local eth0_down=false
    local wlan0_down=false
    if [[ "$STATUS_eth0_EXISTS" == "true" && "$STATUS_eth0_CONNECTIVITY" == "DOWN" ]]; then
        eth0_down=true
    fi
    if [[ "$STATUS_wlan0_EXISTS" == "true" && "$STATUS_wlan0_CONNECTIVITY" == "DOWN" ]]; then
        wlan0_down=true
    fi
    
    local eth0_dns_fail=false
    local wlan0_dns_fail=false
    if [[ "$STATUS_eth0_EXISTS" == "true" && "$STATUS_eth0_CONNECTIVITY" == "OK" && "$STATUS_eth0_DNS" == "false" ]]; then
        eth0_dns_fail=true
    fi
    if [[ "$STATUS_wlan0_EXISTS" == "true" && "$STATUS_wlan0_CONNECTIVITY" == "OK" && "$STATUS_wlan0_DNS" == "false" ]]; then
        wlan0_dns_fail=true
    fi
    
    if [[ "$eth0_down" == "true" && "$wlan0_down" == "true" ]]; then
        overall_status="Outage"
        overall_class="status-outage"
        overall_desc="Total connectivity loss detected on all interfaces."
    elif [[ "$eth0_down" == "true" || "$wlan0_down" == "true" ]]; then
        overall_status="Partial Outage"
        overall_class="status-partial"
        overall_desc="One of the active network interfaces is offline."
    elif [[ "$eth0_dns_fail" == "true" || "$wlan0_dns_fail" == "true" ]]; then
        overall_status="DNS Issues"
        overall_class="status-dns"
        overall_desc="DNS resolution is failing through some endpoints of the chain."
    fi
    
    # Generate logs JSON
    local logs_json="["
    if [[ -f "$LOG_FILE" ]]; then
        local first=true
        while read -r line; do
            line=$(echo "$line" | tr -d '\0')
            [[ -z "$line" ]] && continue
            local ts=$(echo "$line" | cut -d' ' -f1-2)
            local rest=$(echo "$line" | cut -d' ' -f3-)
            local iface=$(echo "$rest" | grep -oE '\[[a-z0-9]+\]' | tail -1 | tr -d '[]')
            local msg=$(echo "$rest" | sed -E 's/.*\[[a-z0-9]+\] //')
            
            # Escape quotes in msg
            msg=$(echo "$msg" | sed 's/"/\\"/g')
            
            if [[ "$first" == "true" ]]; then
                first=false
            else
                logs_json+=","
            fi
            logs_json+="{\"timestamp\":\"$ts\",\"interface\":\"$iface\",\"message\":\"$msg\"}"
        done < <(grep -a "INTERNET-HEALTH-CHECK" "$LOG_FILE" | tail -n 50)
    fi
    logs_json+="]"

    local last_updated
    last_updated=$(date '+%Y-%m-%d %H:%M:%S')

    cat << EOF > "$temp_html"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Internet Health Dashboard</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;400;500;600;700&display=swap" rel="stylesheet">
    <style>
        :root {
            --bg-color: #0b0f19;
            --card-bg: rgba(17, 24, 39, 0.7);
            --card-border: rgba(255, 255, 255, 0.08);
            --primary: #4f46e5;
            --success: #10b981;
            --success-glow: rgba(16, 185, 129, 0.15);
            --warning: #f59e0b;
            --warning-glow: rgba(245, 158, 11, 0.15);
            --danger: #ef4444;
            --danger-glow: rgba(239, 68, 68, 0.15);
            --text-main: #f3f4f6;
            --text-muted: #9ca3af;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: 'Outfit', sans-serif;
            background-color: var(--bg-color);
            color: var(--text-main);
            min-height: 100vh;
            display: flex;
            flex-direction: column;
            justify-content: space-between;
            padding: 2rem 1rem;
            background-image: 
                radial-gradient(circle at 10% 20%, rgba(79, 70, 229, 0.1) 0%, transparent 40%),
                radial-gradient(circle at 90% 80%, rgba(16, 185, 129, 0.05) 0%, transparent 40%);
            background-attachment: fixed;
        }

        .container {
            max-width: 1000px;
            width: 100%;
            margin: 0 auto;
            flex-grow: 1;
        }

        header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 2rem;
            flex-wrap: wrap;
            gap: 1rem;
        }

        .title-area h1 {
            font-size: 2rem;
            font-weight: 700;
            letter-spacing: -0.025em;
            background: linear-gradient(to right, #f3f4f6, #9ca3af);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
            display: flex;
            align-items: center;
            gap: 0.75rem;
        }

        .title-area h1 svg {
            color: var(--primary);
        }

        .last-update {
            font-size: 0.875rem;
            color: var(--text-muted);
            background: rgba(255, 255, 255, 0.03);
            padding: 0.5rem 1rem;
            border-radius: 9999px;
            border: 1px solid var(--card-border);
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .pulse-dot {
            width: 8px;
            height: 8px;
            background-color: var(--success);
            border-radius: 50%;
            box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
            animation: pulse 2s infinite;
        }

        @keyframes pulse {
            0% {
                transform: scale(0.95);
                box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
            }
            70% {
                transform: scale(1);
                box-shadow: 0 0 0 10px rgba(16, 185, 129, 0);
            }
            100% {
                transform: scale(0.95);
                box-shadow: 0 0 0 0 rgba(16, 185, 129, 0);
            }
        }

        /* Overall Status Card */
        .status-hero {
            border-radius: 24px;
            padding: 2.5rem 2rem;
            margin-bottom: 2rem;
            border: 1px solid var(--card-border);
            position: relative;
            overflow: hidden;
            display: flex;
            flex-direction: column;
            gap: 0.75rem;
            box-shadow: 0 20px 25px -5px rgba(0, 0, 0, 0.3), 0 10px 10px -5px rgba(0, 0, 0, 0.3);
        }

        .status-hero::before {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            z-index: 0;
            opacity: 0.15;
        }

        .status-healthy {
            background: linear-gradient(135deg, rgba(16, 185, 129, 0.15), rgba(4, 120, 87, 0.05));
            border-color: rgba(16, 185, 129, 0.3);
        }
        .status-healthy::before {
            background-image: radial-gradient(circle at 90% 10%, var(--success) 0%, transparent 60%);
        }

        .status-partial {
            background: linear-gradient(135deg, rgba(245, 158, 11, 0.15), rgba(180, 83, 9, 0.05));
            border-color: rgba(245, 158, 11, 0.3);
        }
        .status-partial::before {
            background-image: radial-gradient(circle at 90% 10%, var(--warning) 0%, transparent 60%);
        }

        .status-dns {
            background: linear-gradient(135deg, rgba(245, 158, 11, 0.15), rgba(79, 70, 229, 0.1));
            border-color: rgba(245, 158, 11, 0.3);
        }
        .status-dns::before {
            background-image: radial-gradient(circle at 90% 10%, var(--warning) 0%, transparent 60%);
        }

        .status-outage {
            background: linear-gradient(135deg, rgba(239, 68, 68, 0.15), rgba(185, 28, 28, 0.05));
            border-color: rgba(239, 68, 68, 0.3);
        }
        .status-outage::before {
            background-image: radial-gradient(circle at 90% 10%, var(--danger) 0%, transparent 60%);
        }

        .status-badge {
            font-size: 0.875rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            padding: 0.25rem 0.75rem;
            border-radius: 9999px;
            width: fit-content;
            z-index: 1;
        }

        .status-healthy .status-badge { background-color: var(--success); color: #064e3b; }
        .status-partial .status-badge { background-color: var(--warning); color: #78350f; }
        .status-dns .status-badge { background-color: var(--warning); color: #78350f; }
        .status-outage .status-badge { background-color: var(--danger); color: #7f1d1d; }

        .status-title {
            font-size: 2.25rem;
            font-weight: 800;
            z-index: 1;
            letter-spacing: -0.03em;
        }

        .status-desc {
            font-size: 1.1rem;
            color: var(--text-muted);
            max-width: 600px;
            z-index: 1;
        }

        /* Interface Cards Grid */
        .interfaces-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(320px, 1fr));
            gap: 1.5rem;
            margin-bottom: 2rem;
        }

        .card {
            background-color: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 20px;
            padding: 1.5rem;
            backdrop-filter: blur(12px);
            display: flex;
            flex-direction: column;
            gap: 1.25rem;
        }

        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .card-title {
            font-size: 1.25rem;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .state-indicator {
            display: flex;
            align-items: center;
            gap: 0.375rem;
            font-size: 0.875rem;
            font-weight: 600;
            padding: 0.25rem 0.625rem;
            border-radius: 8px;
        }

        .state-ok { background-color: var(--success-glow); color: var(--success); }
        .state-down { background-color: var(--danger-glow); color: var(--danger); }
        .state-inactive { background: rgba(255, 255, 255, 0.05); color: var(--text-muted); }

        .dns-chain-visual {
            display: flex;
            flex-direction: column;
            gap: 0.75rem;
            background: rgba(255, 255, 255, 0.02);
            padding: 1rem;
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.03);
        }

        .dns-chain-title {
            font-size: 0.75rem;
            font-weight: 600;
            text-transform: uppercase;
            letter-spacing: 0.05em;
            color: var(--text-muted);
        }

        .chain-nodes {
            display: flex;
            align-items: center;
            justify-content: space-between;
            position: relative;
        }

        .node {
            display: flex;
            flex-direction: column;
            align-items: center;
            gap: 0.375rem;
            width: 80px;
            z-index: 1;
        }

        .node-circle {
            width: 32px;
            height: 32px;
            border-radius: 50%;
            display: flex;
            align-items: center;
            justify-content: center;
            background-color: #1f2937;
            border: 2px solid var(--card-border);
            font-size: 0.75rem;
            font-weight: 700;
            transition: all 0.3s ease;
        }

        .node-name {
            font-size: 0.7rem;
            color: var(--text-muted);
            text-align: center;
            font-weight: 500;
        }

        .node-pass .node-circle {
            background-color: var(--success-glow);
            border-color: var(--success);
            color: var(--success);
            box-shadow: 0 0 10px var(--success-glow);
        }

        .node-fail .node-circle {
            background-color: var(--danger-glow);
            border-color: var(--danger);
            color: var(--danger);
            box-shadow: 0 0 10px var(--danger-glow);
        }

        .node-inactive .node-circle {
            background-color: rgba(255, 255, 255, 0.02);
            border-color: var(--card-border);
            color: var(--text-muted);
        }

        .chain-line {
            position: absolute;
            top: 16px;
            left: 40px;
            right: 40px;
            height: 2px;
            background-color: rgba(255, 255, 255, 0.05);
            z-index: 0;
        }

        /* Logs Panel */
        .logs-panel {
            background-color: var(--card-bg);
            border: 1px solid var(--card-border);
            border-radius: 20px;
            padding: 1.5rem;
            backdrop-filter: blur(12px);
        }

        .panel-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 1.25rem;
        }

        .panel-title {
            font-size: 1.25rem;
            font-weight: 600;
            display: flex;
            align-items: center;
            gap: 0.5rem;
        }

        .filter-buttons {
            display: flex;
            gap: 0.5rem;
            background: rgba(255, 255, 255, 0.03);
            padding: 0.25rem;
            border-radius: 10px;
            border: 1px solid var(--card-border);
        }

        .filter-btn {
            background: none;
            border: none;
            color: var(--text-muted);
            font-size: 0.825rem;
            font-weight: 500;
            padding: 0.375rem 0.75rem;
            border-radius: 8px;
            cursor: pointer;
            transition: all 0.2s ease;
        }

        .filter-btn.active {
            background-color: rgba(255, 255, 255, 0.08);
            color: var(--text-main);
        }

        .table-container {
            max-height: 400px;
            overflow-y: auto;
            border-radius: 12px;
            border: 1px solid var(--card-border);
        }

        table {
            width: 100%;
            border-collapse: collapse;
            text-align: left;
            font-size: 0.9rem;
        }

        th {
            background-color: rgba(255, 255, 255, 0.02);
            color: var(--text-muted);
            font-weight: 600;
            padding: 0.75rem 1rem;
            border-bottom: 1px solid var(--card-border);
            font-size: 0.8rem;
            text-transform: uppercase;
            letter-spacing: 0.05em;
        }

        td {
            padding: 0.75rem 1rem;
            border-bottom: 1px solid rgba(255, 255, 255, 0.03);
            vertical-align: middle;
        }

        tr:last-child td {
            border-bottom: none;
        }

        tr:hover td {
            background-color: rgba(255, 255, 255, 0.01);
        }

        .log-ts {
            color: var(--text-muted);
            font-family: monospace;
            font-size: 0.85rem;
            white-space: nowrap;
        }

        .log-iface {
            font-weight: 600;
            font-size: 0.825rem;
        }

        .log-badge {
            font-size: 0.75rem;
            font-weight: 600;
            padding: 0.125rem 0.5rem;
            border-radius: 6px;
            display: inline-block;
        }

        .log-badge-ok { background-color: var(--success-glow); color: var(--success); }
        .log-badge-down { background-color: var(--danger-glow); color: var(--danger); }
        .log-badge-warn { background-color: var(--warning-glow); color: var(--warning); }

        footer {
            text-align: center;
            margin-top: 3rem;
            color: var(--text-muted);
            font-size: 0.8rem;
        }

        /* Scrollbars */
        ::-webkit-scrollbar {
            width: 8px;
        }
        ::-webkit-scrollbar-track {
            background: transparent;
        }
        ::-webkit-scrollbar-thumb {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 4px;
        }
        ::-webkit-scrollbar-thumb:hover {
            background: rgba(255, 255, 255, 0.1);
        }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <div class="title-area">
                <h1>
                    <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.55a11 11 0 0 1 14.08 0"></path><path d="M1.42 9a16 16 0 0 1 21.16 0"></path><path d="M8.53 16.11a6 6 0 0 1 6.95 0"></path><circle cx="12" cy="20" r="1"></circle></svg>
                    Internet Health Monitor
                </h1>
            </div>
            <div class="last-update">
                <div class="pulse-dot"></div>
                Updated: <span id="update-time">${last_updated}</span>
            </div>
        </header>

        <!-- Status Hero banner -->
        <div class="status-hero ${overall_class}">
            <span class="status-badge">System Status</span>
            <div class="status-title">${overall_status}</div>
            <div class="status-desc">${overall_desc}</div>
        </div>

        <div class="interfaces-grid">
            <!-- eth0 Card -->
            <div class="card">
                <div class="card-header">
                    <div class="card-title">
                        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="2" width="20" height="8" rx="2" ry="2"></rect><rect x="2" y="14" width="20" height="8" rx="2" ry="2"></rect><line x1="6" y1="6" x2="6.01" y2="6"></line><line x1="6" y1="18" x2="6.01" y2="18"></line></svg>
                        Wired (eth0)
                    </div>
                    <div id="eth0-state" class="state-indicator">Checking...</div>
                </div>
                <div class="dns-chain-visual">
                    <div class="dns-chain-title">DNS Resolution Path</div>
                    <div class="chain-nodes">
                        <div class="chain-line"></div>
                        <div id="eth0-node-pihole" class="node">
                            <div class="node-circle">P1</div>
                            <div class="node-name">Pi-hole</div>
                        </div>
                        <div id="eth0-node-dnscrypt" class="node">
                            <div class="node-circle">D1</div>
                            <div class="node-name">dnscrypt-proxy</div>
                        </div>
                        <div id="eth0-node-cloudflare" class="node">
                            <div class="node-circle">CF</div>
                            <div class="node-name">Cloudflare</div>
                        </div>
                    </div>
                </div>
            </div>

            <!-- wlan0 Card -->
            <div class="card">
                <div class="card-header">
                    <div class="card-title">
                        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.55a11 11 0 0 1 14.08 0"></path><path d="M1.42 9a16 16 0 0 1 21.16 0"></path><path d="M8.53 16.11a6 6 0 0 1 6.95 0"></path><circle cx="12" cy="20" r="1"></circle></svg>
                        Wireless (wlan0)
                    </div>
                    <div id="wlan0-state" class="state-indicator">Checking...</div>
                </div>
                <div class="dns-chain-visual">
                    <div class="dns-chain-title">DNS Resolution Path</div>
                    <div class="chain-nodes">
                        <div class="chain-line"></div>
                        <div id="wlan0-node-pihole" class="node">
                            <div class="node-circle">P1</div>
                            <div class="node-name">Pi-hole</div>
                        </div>
                        <div id="wlan0-node-dnscrypt" class="node">
                            <div class="node-circle">D1</div>
                            <div class="node-name">dnscrypt-proxy</div>
                        </div>
                        <div id="wlan0-node-cloudflare" class="node">
                            <div class="node-circle">CF</div>
                            <div class="node-name">Cloudflare</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Logs Panel -->
        <div class="logs-panel">
            <div class="panel-header">
                <div class="panel-title">
                    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"></path><polyline points="14 2 14 8 20 8"></polyline><line x1="16" y1="13" x2="8" y2="13"></line><line x1="16" y1="17" x2="8" y2="17"></line><polyline points="10 9 9 9 8 9"></polyline></svg>
                    Recent Monitoring Logs
                </div>
                <div class="filter-buttons">
                    <button id="filter-all" class="filter-btn active" onclick="filterLogs('all')">All</button>
                    <button id="filter-ok" class="filter-btn" onclick="filterLogs('ok')">OK</button>
                    <button id="filter-issues" class="filter-btn" onclick="filterLogs('issues')">Alerts</button>
                </div>
            </div>
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th>Timestamp</th>
                            <th>Interface</th>
                            <th>Status / Message</th>
                        </tr>
                    </thead>
                    <tbody id="logs-body">
                        <!-- Filled by JS -->
                    </tbody>
                </table>
            </div>
        </div>
    </div>

    <footer>
        <p>Internet Health Check Daemon • Refreshing automatically in 30 seconds</p>
    </footer>

    <script>
        // State variables injected from bash
        const interfaces = {
            eth0: {
                exists: ${STATUS_eth0_EXISTS:-false},
                connectivity: "${STATUS_eth0_CONNECTIVITY:-INACTIVE}",
                dns: ${STATUS_eth0_DNS:-true},
                pihole: ${STATUS_eth0_PIHOLE:-true},
                dnscrypt: ${STATUS_eth0_DNSCRYPT:-true},
                cloudflare: ${STATUS_eth0_CLOUDFLARE:-true}
            },
            wlan0: {
                exists: ${STATUS_wlan0_EXISTS:-false},
                connectivity: "${STATUS_wlan0_CONNECTIVITY:-INACTIVE}",
                dns: ${STATUS_wlan0_DNS:-true},
                pihole: ${STATUS_wlan0_PIHOLE:-true},
                dnscrypt: ${STATUS_wlan0_DNSCRYPT:-true},
                cloudflare: ${STATUS_wlan0_CLOUDFLARE:-true}
            }
        };

        const rawLogs = ${logs_json};

        // Render Interface States
        function renderInterfaces() {
            for (const [iface, data] of Object.entries(interfaces)) {
                const stateEl = document.getElementById(iface + '-state');
                const nodePihole = document.getElementById(iface + '-node-pihole');
                const nodeDnscrypt = document.getElementById(iface + '-node-dnscrypt');
                const nodeCloudflare = document.getElementById(iface + '-node-cloudflare');

                if (!data.exists) {
                    stateEl.className = "state-indicator state-inactive";
                    stateEl.textContent = "INACTIVE";
                    nodePihole.className = "node node-inactive";
                    nodeDnscrypt.className = "node node-inactive";
                    nodeCloudflare.className = "node node-inactive";
                    continue;
                }

                if (data.connectivity === "DOWN") {
                    stateEl.className = "state-indicator state-down";
                    stateEl.textContent = "OFFLINE";
                    nodePihole.className = "node node-fail";
                    nodeDnscrypt.className = "node node-fail";
                    nodeCloudflare.className = "node node-fail";
                } else {
                    stateEl.className = "state-indicator state-ok";
                    stateEl.textContent = data.dns ? "ONLINE" : "DNS ISSUE";
                    
                    nodePihole.className = "node " + (data.pihole ? "node-pass" : "node-fail");
                    nodeDnscrypt.className = "node " + (data.dnscrypt ? "node-pass" : "node-fail");
                    nodeCloudflare.className = "node " + (data.cloudflare ? "node-pass" : "node-fail");
                }
            }
        }

        // Render Logs
        let activeFilter = 'all';
        function renderLogs() {
            const tbody = document.getElementById('logs-body');
            tbody.innerHTML = '';
            
            rawLogs.forEach(log => {
                const isOk = log.message.trim() === 'OK';
                const isDown = log.message.includes('DOWN') || log.message.includes('Fail during Ping');
                
                if (activeFilter === 'ok' && !isOk) return;
                if (activeFilter === 'issues' && isOk) return;

                const tr = document.createElement('tr');
                
                let badgeClass = 'log-badge-ok';
                let statusLabel = 'OK';
                
                if (isDown) {
                    badgeClass = 'log-badge-down';
                    statusLabel = 'OUTAGE';
                } else if (!isOk) {
                    badgeClass = 'log-badge-warn';
                    statusLabel = 'WARNING';
                }

                tr.innerHTML = '<tr>' +
                    '<td class="log-ts">' + log.timestamp + '</td>' +
                    '<td class="log-iface">' + log.interface + '</td>' +
                    '<td>' +
                        '<span class="log-badge ' + badgeClass + '">' + statusLabel + '</span>' +
                        '<span style="margin-left: 0.5rem">' + log.message + '</span>' +
                    '</td>' +
                '</tr>';
                tbody.appendChild(tr);
            });
        }

        function filterLogs(filterType) {
            activeFilter = filterType;
            document.querySelectorAll('.filter-btn').forEach(btn => btn.classList.remove('active'));
            var filterId = 'filter-' + (filterType === 'issues' ? 'issues' : filterType);
            document.getElementById(filterId).classList.add('active');
            renderLogs();
        };

        // Initial setup
        renderInterfaces();
        renderLogs();

        // Auto reload page every 30 seconds
        setTimeout(() => {
            window.location.reload();
        }, 30000);
    </script>
</body>
</html>
EOF

    # Overwrite the final file (handles permissions cleanly)
    if cat "$temp_html" > "$HTML_FILE" 2>/dev/null; then
        rm -f "$temp_html"
    elif sudo cp -f "$temp_html" "$HTML_FILE" 2>/dev/null; then
        rm -f "$temp_html"
    else
        mv -f "$temp_html" "$HTML_FILE"
    fi
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
  --html-file FILE      Generate a beautiful HTML status dashboard at FILE
  -h, --help            Show this help message

Examples:
  # Print to stdout (default)
  ./internet_health_check.sh
  
  # Write to log file
  ./internet_health_check.sh --log-file logs/internet_health.log
  
  # Generate HTML dashboard (needs sudo if in /var/www/html/)
  ./internet_health_check.sh --log-file logs/internet_health.log --html-file /var/www/html/health.html
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
            --html-file)
                HTML_FILE="$2"
                shift 2
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
    
    # Initialize interface existence variables
    STATUS_eth0_EXISTS=false
    STATUS_wlan0_EXISTS=false
    
    # Define interfaces: wired first, then wireless
    local interfaces=("eth0" "wlan0")
    
    for interface in "${interfaces[@]}"; do
        # Check if interface exists
        if ! ip link show "$interface" >/dev/null 2>&1; then
            continue
        fi
        
        eval "STATUS_${interface}_EXISTS=true"
        
        # Check connectivity first
        connectivity=$(check_connectivity "$interface")
        eval "STATUS_${interface}_CONNECTIVITY=\"\$connectivity\""
        
        # Check DNS chain only if connectivity is OK
        local dns_ok="true"
        if [[ "$connectivity" == "OK" ]]; then
            check_dns_chain "$interface"
            dns_ok="$DNS_OK_RESULT"
        else
            eval "STATUS_${interface}_PIHOLE=false"
            eval "STATUS_${interface}_DNSCRYPT=false"
            eval "STATUS_${interface}_CLOUDFLARE=false"
        fi
        eval "STATUS_${interface}_DNS=\"\$dns_ok\""
        
        # Report current status
        determine_current_status "$interface" "$connectivity" "$dns_ok"
    done
    
    # After checking all interfaces, if HTML_FILE is set, generate the HTML page
    if [[ -n "$HTML_FILE" ]]; then
        generate_html_page
    fi
}

main "$@"