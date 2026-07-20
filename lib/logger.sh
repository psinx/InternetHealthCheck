#!/usr/bin/env bash

# lib/logger.sh - Logging and state database management

RAM_STATE_FILE="${RAM_STATE_FILE:-/dev/shm/internet_health_history.txt}"
readonly RAM_STATE_FILE
readonly MAX_RAM_LINES=8640 # 30 days of 5-minute runs (30 * 24 * 12)

# Write to the physical disk log file
log() {
    local message="$1"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_entry="$timestamp ${TAG} $message"
    
    if [[ "$LOG_TO_FILE" == "true" && -n "$LOG_FILE" ]]; then
        echo "$log_entry" >> "$LOG_FILE"
        WRITE_OCCURRED=true
    else
        echo "$log_entry" >&2
    fi
}

# Syslog alerting
syslog_alert() {
    local message="$1"
    local priority="${2:-user.notice}"
    # Send message to syslog with tag
    logger -t "internet-health-check" -p "$priority" "$message" 2>/dev/null || true
}

# Append check run to RAM state database
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
    
    local timestamp
    timestamp=$(date +%s)
    
    # Create logs directory in RAM if needed
    mkdir -p "/dev/shm" 2>/dev/null
    
    # Append CSV line to RAM file
    # Format: timestamp,interface,connectivity,dns_ok,pihole_ok,dnscrypt_ok,cloudflare_ok,pihole_lat,dnscrypt_lat,cf_lat,loss
    echo "$timestamp,$interface,$connectivity,$dns_ok,$pihole,$dnscrypt,$cloudflare,$pi_lat,$dns_lat,$cf_lat,$loss" >> "$RAM_STATE_FILE"
    
    # Prune history to limit size
    if [[ -f "$RAM_STATE_FILE" ]]; then
        # Use tail to keep last 8640 lines in RAM
        local temp_file="/dev/shm/ih_tmp.$$"
        tail -n "$MAX_RAM_LINES" "$RAM_STATE_FILE" > "$temp_file" 2>/dev/null && mv -f "$temp_file" "$RAM_STATE_FILE"
    fi
}

# Determine if the current run state has changed compared to the last run in RAM
detect_state_change() {
    local interface=$1
    local current_connectivity=$2
    local current_dns_ok=$3
    
    [[ ! -f "$RAM_STATE_FILE" ]] && return 0
    
    # Get all entries for this interface
    local entries
    entries=$(grep -F ",$interface," "$RAM_STATE_FILE" 2>/dev/null || true)
    
    [[ -z "$entries" ]] && return 0
    
    local count
    count=$(echo "$entries" | wc -l)
    
    # If only 1 entry, there is no previous state to compare against, so log it
    if (( count < 2 )); then
        return 0
    fi
    
    # Parse the second to last entry (the previous run)
    local last_entry
    last_entry=$(echo "$entries" | tail -n 2 | head -n 1)
    
    local last_conn
    last_conn=$(echo "$last_entry" | cut -d, -f3)
    local last_dns
    last_dns=$(echo "$last_entry" | cut -d, -f4)
    
    if [[ "$last_conn" != "$current_connectivity" || "$last_dns" != "$current_dns_ok" ]]; then
        return 0 # State changed
    fi
    
    return 1 # State identical
}

# Log rotation for disk logs
rotate_log() {
    [[ "$LOG_TO_FILE" != "true" || -z "$LOG_FILE" || ! -f "$LOG_FILE" ]] && return
    
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null)
    size=$((size + 0)) 2>/dev/null || size=0
    
    if (( size > MAX_LOG_SIZE )); then
        for ((i=MAX_ROTATIONS; i>=1; i--)); do
            local old="$LOG_FILE.$i"
            local new="$LOG_FILE.$((i+1))"
            [[ -f "$old" ]] && mv -f "$old" "$new" 2>/dev/null
        done
        
        gzip -f -c "$LOG_FILE" > "$LOG_FILE.1.gz" 2>/dev/null
        : > "$LOG_FILE"
        log "LOG ROTATED"
    fi
}

# Generate the JSON payload for the dashboard
generate_status_json() {
    local output_file=$1
    [[ -z "$output_file" ]] && return
    
    local temp_json="/tmp/status.json.tmp"
    
    # 1. Build basic fields
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Get overall status from globals set in main loop
    local overall_status="Healthy"
    if [[ "$STATUS_eth0_CONNECTIVITY" == "DOWN" && "$STATUS_wlan0_CONNECTIVITY" == "DOWN" ]]; then
        overall_status="Outage"
    elif [[ "$STATUS_eth0_CONNECTIVITY" == "DOWN" || "$STATUS_wlan0_CONNECTIVITY" == "DOWN" ]]; then
        overall_status="Partial Outage"
    elif [[ "$STATUS_eth0_DNS" == "false" || "$STATUS_wlan0_DNS" == "false" ]]; then
        overall_status="DNS Issues"
    fi
    
    # 2. Calculate SLA percentage over the last 30 days
    local total_runs=0
    local healthy_runs=0
    local sla_pct=100.00
    if [[ -f "$RAM_STATE_FILE" ]]; then
        total_runs=$(wc -l < "$RAM_STATE_FILE" 2>/dev/null || echo 0)
        # Healthy runs have connectivity=OK and dns_ok=true
        healthy_runs=$(grep -c ",OK,true," "$RAM_STATE_FILE" 2>/dev/null || echo 0)
        if (( total_runs > 0 )); then
            # Perform floating point division in awk
            sla_pct=$(awk "BEGIN {printf \"%.2f\", ($healthy_runs / $total_runs) * 100}")
        fi
    fi

    # 3. Generate Uptime History JSON structure
    # We will build a JSON array of the last 72 hours (3 rows of 24 hours)
    # And a 30-day daily summary list
    local history_json="["
    local current_time
    current_time=$(date +%s)
    local one_hour=3600
    local one_day=86400
    
    # Compile 72 hours grid (Today, Yesterday, 2 Days Ago)
    local labels=("2 Days Ago" "Yesterday" "Today")
    for d in {0..2}; do
        local label="${labels[$d]}"
        [[ $d -gt 0 ]] && history_json+=","
        history_json+="{\"label\":\"$label\",\"hours\":["
        
        # Hours from 0 to 23
        for h in {0..23}; do
            [[ $h -gt 0 ]] && history_json+=","
            
            # Determine timestamp range for this specific hour
            # We map Today, Yesterday, and 2 Days Ago relative to the start of today
            local day_start
            if [[ "$OSTYPE" == "darwin"* ]]; then
                day_start=$(date -j -f "%Y-%m-%d" "$(date +%Y-%m-%d)" +%s 2>/dev/null)
            else
                day_start=$(date -d "today 00:00:00" +%s 2>/dev/null)
            fi
            
            local target_day_start=$(( day_start - (2 - d) * one_day ))
            local hour_start=$(( target_day_start + h * one_hour ))
            local hour_end=$(( hour_start + one_hour ))
            
            # Query RAM file for entries in this hour
            local hour_status="INACTIVE"
            local hour_uptime=100
            
            if [[ -f "$RAM_STATE_FILE" ]]; then
                # Get all records in this hour window
                local records
                records=$(awk -F, -v start="$hour_start" -v end="$hour_end" '$1 >= start && $1 < end' "$RAM_STATE_FILE")
                
                if [[ -n "$records" ]]; then
                    local total_h_runs
                    total_h_runs=$(echo "$records" | wc -l)
                    local fail_h_runs
                    fail_h_runs=$(echo "$records" | grep -vc ",OK,true," || echo 0)
                    local outage_h_runs
                    outage_h_runs=$(echo "$records" | grep -c ",DOWN," || echo 0)
                    
                    if (( outage_h_runs > 0 )); then
                        hour_status="DANGER"
                    elif (( fail_h_runs > 0 )); then
                        hour_status="WARNING"
                    else
                        hour_status="OK"
                    fi
                    
                    # Calculate uptime percentage for this hour
                    if (( total_h_runs > 0 )); then
                        hour_uptime=$(( (total_h_runs - outage_h_runs) * 100 / total_h_runs ))
                    fi
                fi
            fi
            
            history_json+="{\"hour\":$h,\"status\":\"$hour_status\",\"uptime\":$hour_uptime}"
        done
        history_json+="]}"
    done
    history_json+="]"

    # 4. Generate incident reports from the text logs
    # We parse the main log file to retrieve DOWN incidents and DNS chain failures
    local incidents_json="["
    if [[ -f "$LOG_FILE" ]]; then
        local count=0
        # Parse log file for DOWN/Test: Fail entries
        # Format: 2026-07-20 02:15:02 [INTERNET-HEALTH-CHECK] [eth0] Test: Fail during Ping
        while read -r line; do
            [[ -z "$line" ]] && continue
            local ts
            ts=$(echo "$line" | cut -d' ' -f1-2)
            local rest
            rest=$(echo "$line" | cut -d' ' -f3-)
            local iface
            iface=$(echo "$rest" | grep -oE '\[[a-zA-Z0-9]+\]' | tail -1 | tr -d '[]')
            local msg
            msg=$(echo "$rest" | sed -E 's/.*\[[a-zA-Z0-9]+\] //')
            
            # Escape quotes
            msg=$(echo "$msg" | sed 's/"/\\"/g')
            
            local type="warning"
            local badge="DNS Fail"
            if [[ "$msg" =~ "DOWN" || "$msg" =~ "Ping" ]]; then
                type="outage"
                badge="Outage"
            fi
            
            [[ $count -gt 0 ]] && incidents_json+=","
            incidents_json+="{\"type\":\"$type\",\"badge\":\"$badge\",\"timestamp\":\"$ts ($iface)\",\"description\":\"$msg\",\"duration\":\"\"}"
            ((count++)) || true
            [[ $count -ge 10 ]] && break # Limit to last 10 incidents
        done < <(grep -a "INTERNET-HEALTH-CHECK" "$LOG_FILE" | grep -E "DOWN|Test: Fail" | tail -n 10 | tac)
    fi
    incidents_json+="]"

    # Assemble final JSON
    cat << EOF > "$temp_json"
{
  "timestamp": "$timestamp",
  "status": "$overall_status",
  "sla_percentage": $sla_pct,
  "interfaces": {
    "eth0": {
      "exists": ${STATUS_eth0_EXISTS:-false},
      "connectivity": "${STATUS_eth0_CONNECTIVITY:-INACTIVE}",
      "dns_ok": ${STATUS_eth0_DNS:-true},
      "pihole": ${STATUS_eth0_PIHOLE:-true},
      "dnscrypt": ${STATUS_eth0_DNSCRYPT:-true},
      "cloudflare": ${STATUS_eth0_CLOUDFLARE:-true},
      "latency_pihole": ${STATUS_eth0_PIHOLE_LAT:-0},
      "latency_dnscrypt": ${STATUS_eth0_DNSCRYPT_LAT:-0},
      "latency_cloudflare": ${STATUS_eth0_CLOUDFLARE_LAT:-0},
      "packet_loss": ${STATUS_eth0_LOSS:-0.0}
    },
    "wlan0": {
      "exists": ${STATUS_wlan0_EXISTS:-false},
      "connectivity": "${STATUS_wlan0_CONNECTIVITY:-INACTIVE}",
      "dns_ok": ${STATUS_wlan0_DNS:-true},
      "pihole": ${STATUS_wlan0_PIHOLE:-true},
      "dnscrypt": ${STATUS_wlan0_DNSCRYPT:-true},
      "cloudflare": ${STATUS_wlan0_CLOUDFLARE:-true},
      "latency_pihole": ${STATUS_wlan0_PIHOLE_LAT:-0},
      "latency_dnscrypt": ${STATUS_wlan0_DNSCRYPT_LAT:-0},
      "latency_cloudflare": ${STATUS_wlan0_CLOUDFLARE_LAT:-0},
      "packet_loss": ${STATUS_wlan0_LOSS:-0.0}
    }
  },
  "history": $history_json,
  "incidents": $incidents_json
}
EOF

    # Output to the final destination safely
    mkdir -p "$(dirname "$output_file")" 2>/dev/null
    if cat "$temp_json" > "$output_file" 2>/dev/null; then
        rm -f "$temp_json"
    else
        mv -f "$temp_json" "$output_file"
    fi
}
