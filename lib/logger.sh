#!/usr/bin/env bash

# lib/logger.sh - Logging, state database, log rotation, and alerting

if [[ -z "${DEFAULT_RAM_DIR:-}" ]]; then
    if [[ -d "/tmp" && "$(df -PT /tmp 2>/dev/null | awk 'NR==2{print $2}')" == "tmpfs" ]]; then
        DEFAULT_RAM_DIR="/tmp"
    elif [[ -d "/dev/shm" ]]; then
        DEFAULT_RAM_DIR="/dev/shm"
    else
        DEFAULT_RAM_DIR="/tmp"
    fi
fi
RAM_STATE_FILE="${RAM_STATE_FILE:-${DEFAULT_RAM_DIR}/internet_health_history.txt}"
readonly RAM_STATE_FILE
readonly MAX_RAM_LINES=17280 # 30 days of 5-minute runs across 2 interfaces (30 * 24 * 12 * 2)

# Write to the physical disk log file (or stderr in non-pretty stdout mode)
log() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="$timestamp ${TAG} $message"

    if [[ "$LOG_TO_FILE" == "true" && -n "$LOG_FILE" ]]; then
        echo "$log_entry" >> "$LOG_FILE"
        WRITE_OCCURRED=true
    elif [[ "${OUTPUT_FORMAT:-}" != "pretty" ]]; then
        echo "$log_entry" >&2
    fi
}

# Syslog alerting
syslog_alert() {
    local message="$1"
    local priority="${2:-user.notice}"
    logger -t "internet-health-check" -p "$priority" "$message" 2>/dev/null || true
}

# Webhook alerting (non-fatal HTTP JSON POST on state transitions)
send_webhook_alert() {
    local iface=$1 status=$2 message=$3
    local url="${WEBHOOK_URL:-}"
    [[ -z "$url" ]] && return 0
    command -v curl >/dev/null 2>&1 || return 0

    local host_name payload ts
    host_name=$(hostname 2>/dev/null || echo "unknown")
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    if command -v python3 >/dev/null 2>&1; then
        payload=$(python3 -c '
import json, sys
print(json.dumps({
    "host": sys.argv[1],
    "interface": sys.argv[2],
    "status": sys.argv[3],
    "message": sys.argv[4],
    "timestamp": sys.argv[5],
}))
' "$host_name" "$iface" "$status" "$message" "$ts" 2>/dev/null)
    else
        payload="{\"host\":\"$host_name\",\"interface\":\"$iface\",\"status\":\"$status\",\"timestamp\":\"$ts\"}"
    fi

    curl -fsS --max-time 5 -H "Content-Type: application/json" -d "$payload" "$url" >/dev/null 2>&1 || true
}

# Append check run to RAM state database
# Format: ts,iface,connectivity,dns_ok,pihole_ok,dnscrypt_ok,cf_ok,pi_lat,dns_lat,cf_lat,loss,client_ok,state,ping_lat
record_run() {
    local interface=$1
    local connectivity=$2
    local dns_ok=$3
    local pihole=$4
    local dnscrypt=$5
    local cloudflare=$6
    local pi_lat=$7
    local dns_lat=$8
    local cf_lat=$9
    local loss=${10}
    local client_ok=${11:-true}
    local iface_state=${12:-""}
    local ping_lat=${13:--1}

    local timestamp
    timestamp=$(date +%s)

    local ram_dir
    ram_dir=$(dirname "$RAM_STATE_FILE")
    mkdir -p "$ram_dir" 2>/dev/null

    echo "$timestamp,$interface,$connectivity,$dns_ok,$pihole,$dnscrypt,$cloudflare,$pi_lat,$dns_lat,$cf_lat,$loss,$client_ok,$iface_state,$ping_lat" >> "$RAM_STATE_FILE"

    # Prune only when exceeding buffer headroom (avoids rewriting file on every run)
    if [[ -f "$RAM_STATE_FILE" ]]; then
        local line_count
        line_count=$(wc -l < "$RAM_STATE_FILE" 2>/dev/null || echo 0)
        if (( line_count > MAX_RAM_LINES + 500 )); then
            local temp_file="${ram_dir}/ih_tmp.$$"
            if tail -n "$MAX_RAM_LINES" "$RAM_STATE_FILE" > "$temp_file" 2>/dev/null; then
                mv -f "$temp_file" "$RAM_STATE_FILE" 2>/dev/null || rm -f "$temp_file" 2>/dev/null
            else
                rm -f "$temp_file" 2>/dev/null
            fi
        fi
    fi
}

# Determine if the current run state has changed compared to the LAST recorded run in RAM.
# Must be called BEFORE record_run() appends the current run!
detect_state_change() {
    local interface=$1
    local current_connectivity=$2
    local current_dns_ok=$3
    local current_degraded=${4:-false}

    [[ ! -f "$RAM_STATE_FILE" ]] && return 0

    local last_entry
    last_entry=$(grep -F ",$interface," "$RAM_STATE_FILE" 2>/dev/null | grep -v ',UNUSED,' | tail -n 1 || true)

    [[ -z "$last_entry" ]] && return 0

    local last_conn last_dns last_pi_ok last_dc_ok last_cf_ok last_pi_lat last_dc_lat last_cf_lat last_loss
    IFS=',' read -r _ _ last_conn last_dns last_pi_ok last_dc_ok last_cf_ok last_pi_lat last_dc_lat last_cf_lat last_loss _ <<< "$last_entry"

    local pi_warn="${PIHOLE_LATENCY_WARN_MS:-150}"
    local dc_warn="${DNSCRYPT_LATENCY_WARN_MS:-200}"
    local up_warn="${UPSTREAM_LATENCY_WARN_MS:-200}"
    local loss_warn="${PACKET_LOSS_WARN_PCT:-5}"

    local last_degraded=false
    if [[ "$last_conn" == "OK" && "$last_dns" == "true" ]]; then
        if [[ "$last_pi_ok" == "true" && "${last_pi_lat:-0}" -ge "$pi_warn" ]] 2>/dev/null; then
            last_degraded=true
        elif [[ "${SKIP_DNSCRYPT:-false}" != "true" && "$last_dc_ok" == "true" && "${last_dc_lat:-0}" -ge "$dc_warn" ]] 2>/dev/null; then
            last_degraded=true
        elif [[ "$last_cf_ok" == "true" && "${last_cf_lat:-0}" -ge "$up_warn" ]] 2>/dev/null; then
            last_degraded=true
        elif [[ -n "$last_loss" ]]; then
            local loss_hit=0
            loss_hit=$(awk -v l="${last_loss%\%}" -v w="$loss_warn" 'BEGIN { print (l+0 >= w+0) ? 1 : 0 }' 2>/dev/null || echo 0)
            (( loss_hit == 1 )) && last_degraded=true
        fi
    fi

    if [[ "$last_conn" != "$current_connectivity" || "$last_dns" != "$current_dns_ok" || "$last_degraded" != "$current_degraded" ]]; then
        return 0
    fi

    return 1
}

# Return 0 if --reduce-disk-wear should write an hourly OK heartbeat to disk for this interface
should_log_hourly_heartbeat() {
    local interface=$1
    [[ "$LOG_TO_FILE" != "true" || -z "$LOG_FILE" ]] && return 1
    [[ ! -f "$LOG_FILE" ]] && return 0

    local current_hour_prefix
    current_hour_prefix=$(date '+%Y-%m-%d %H')

    if tail -n 50 "$LOG_FILE" 2>/dev/null | grep -F "${current_hour_prefix}:" | grep -qF "[$interface]"; then
        return 1
    fi
    return 0
}

# Log rotation for disk logs (preserves .1.gz, .2.gz, ... up to MAX_ROTATIONS)
rotate_log() {
    [[ "$LOG_TO_FILE" != "true" || -z "$LOG_FILE" || ! -f "$LOG_FILE" ]] && return

    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null)
    size=$((size + 0)) 2>/dev/null || size=0

    if (( size > MAX_LOG_SIZE )); then
        for ((i=MAX_ROTATIONS; i>=1; i--)); do
            local old="$LOG_FILE.$i.gz"
            local new="$LOG_FILE.$((i+1)).gz"
            [[ -f "$old" ]] && mv -f "$old" "$new" 2>/dev/null
        done

        gzip -f -c "$LOG_FILE" > "$LOG_FILE.1.gz" 2>/dev/null
        : > "$LOG_FILE"
        log "LOG ROTATED"
    fi
}
