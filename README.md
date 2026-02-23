# Internet Health Check

A bash script for monitoring internet connectivity and DNS chain health with test coverage.

## Quick Start

```bash
# Run the health check (logs to stdout)
./internet_health_check.sh

# Run the health check (logs to file)
./internet_health_check.sh --log-file logs/internet_health.log

# Run tests
cd tests/
./test_internet_health_check.sh

# View logs
tail -f logs/internet_health.log
```

## Overview

The Internet Health Check script monitors your internet connection by testing:
1. **Connectivity** - Ping to 1.1.1.1 (Cloudflare)
2. **DNS Chain** - Tests three DNS services in sequence:
   - Pi-hole (127.0.0.1:53)
   - dnscrypt-proxy (127.0.0.1:5053)
   - Cloudflare public DNS (1.1.1.1:53)

When a DNS failure is detected, the script identifies where in the chain the break occurs and logs diagnostic information.

## Files

| File | Purpose |
|------|---------|
| `internet_health_check.sh` | Main script |
| `tests/test_internet_health_check.sh` | Test suite (15 tests, 100% pass rate) |
| `logs/internet_health.log` | Monitoring logs (auto-rotated at 2MB) |

## Log Format

All log entries include a timestamp, interface identifier, and status message.

### Successful System Status
```
Log: [INTERNET-HEALTH-CHECK] [eth0] OK
Log: [INTERNET-HEALTH-CHECK] [wlan0] OK
```

### Connectivity Failure
```
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Fail during Ping - 1.1.1.1 did not respond
Log: [INTERNET-HEALTH-CHECK] [eth0] DOWN - CONNECTIVITY OUTAGE detected
```

### DNS Chain Issue (with connectivity OK)
```
Log: [INTERNET-HEALTH-CHECK] [eth0] DOWN
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Fail via Pi-hole (127.0.0.1:53)
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via dnscrypt-proxy (127.0.0.1:5053)
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via Cloudflare public (1.1.1.1:53)
Log: [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole × dnscrypt-proxy → Cloudflare
Log: [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole forwarding
Log: [INTERNET-HEALTH-CHECK] [eth0] Issue: DNS issue detected. Connectivity still OK
Log: [INTERNET-HEALTH-CHECK] [eth0] DOWN
```

**Key indicators:**
- `[interface] OK` - Interface healthy (both connectivity and DNS OK)
- `[interface] DOWN - CONNECTIVITY OUTAGE detected` - Ping failed (no internet access)
- `[interface] DOWN` (block marker) - Start and end of DNS issue error block
- `Test: Pass` - DNS service responding
- `Test: Fail` - DNS service not responding
- `Issue: × location` - Where the DNS chain breaks
- `Issue: description` - Why it failed (forwarding, DoH, upstream connectivity)

## Configuration

Edit these constants in the script to customize:

```bash
readonly PING_TARGET="1.1.1.1"           # IP to ping for connectivity test
readonly DNS_TEST_DOMAIN="cloudflare.com" # Domain to resolve for DNS tests
readonly PING_TIMEOUT=5                   # Timeout for ping (seconds)
readonly PING_COUNT=4                     # Number of ping packets
readonly PIHOLE_PORT="53"                 # Pi-hole port
readonly DNSCRYPT_PORT="5053"             # dnscrypt-proxy port
readonly MAX_LOG_SIZE=$((2 * 1024 * 1024)) # Log rotation size (2MB)
readonly MAX_ROTATIONS=7                  # Number of rotated logs to keep
```

## Usage

### Command Line Options
```bash
./internet_health_check.sh [OPTIONS]

Options:
  --log-file FILE       Write logs to FILE instead of stdout
  --reduce-disk-wear    Reduce disk writes for RPi/SD card/USB
                        Skips logging OK status if < 24h since last entry
                        Failures are always logged immediately
  -h, --help            Show help message
```

### Standalone Execution (logs to stdout)
```bash
./internet_health_check.sh
```

Output will appear in the terminal:
```
2026-02-17 10:30:45 [INTERNET-HEALTH-CHECK] [eth0] OK
2026-02-17 10:30:50 [INTERNET-HEALTH-CHECK] [wlan0] OK
```

### Log to File
```bash
./internet_health_check.sh --log-file logs/internet_health.log
```

Logs are appended to the file and auto-rotated when exceeding 2MB.

### Schedule with Cron
```bash
# Run every 5 minutes, logging to file
*/5 * * * * ~/InternetHealthCheck/internet_health_check.sh --log-file ~/InternetHealthCheck/logs/internet_health.log

# Run every 5 minutes with disk wear reduction (Raspberry Pi/SD card optimization)
*/5 * * * * ~/InternetHealthCheck/internet_health_check.sh --log-file ~/InternetHealthCheck/logs/internet_health.log --reduce-disk-wear
```

### Disk Wear Reduction (for Raspberry Pi)

The `--reduce-disk-wear` flag minimizes SD card/storage wear by reading the log file history to intelligently suppress repetitive OK logs:

**How it works:**
- Reads the last entry (any status) for each interface from the log file
- Checks if the last entry contains error markers (DOWN, Issue, Test: Fail) to detect state changes
- If the last entry is an error, logs immediately (state changed from error to OK)
- If both entries are OK, compares their timestamps against the log file's modification time
- If both OK entries are within 60 seconds of the last file write, they're from the last logged run
- When both are recent and both are OK, suppresses new OK logs (no write needed)
- **Failures are always logged immediately**, regardless of the flag
- **24-hour timeout**: Always logs after 24 hours of silence

**Why this matters for Raspberry Pi:**
- Every write to an SD card reduces its lifespan
- On a 5-minute cron schedule: saves ~98% of disk writes when system is healthy
- Maintains complete failure alerting - issues are logged immediately

**Example behavior with `--reduce-disk-wear`:**
- Run 1 (12:00): Logs OK for both interfaces
- Runs 2-12 (12:05-13:00): Suppresses OK logs (within 24h, both still OK)
- Runs continue (13:05, 13:10...): Suppresses OK logs (within 24h window)
- Run at 12:05 next day: Logs OK again (24+ hours since first log)

**Example with `--log-file` alone (no disk wear reduction):**
- All runs: Logs OK every time (5 minute interval)

### View Results
```bash
# Real-time log viewing
tail -f ~/InternetHealthCheck/logs/internet_health.log

# Check recent health checks (last 50 lines)
tail -50 ~/InternetHealthCheck/logs/internet_health.log
```

### Log Rotation
Logs are automatically rotated when they exceed 2MB:
- Current log: `internet_health.log`
- Rotated logs: `internet_health.log.1.gz`, `internet_health.log.2.gz`, etc.
- Maximum 7 rotated logs kept

## Test Suite

The test suite includes 15 comprehensive test functions covering all script functionality with 100% pass rate:

| Test | Coverage |
|---|---|
| Test 1 | All systems OK - normal operation |
| Test 2 | Connectivity failure - ping target unresponsive |
| Test 3 | Repeated OK checks - consecutive healthy states |
| Test 4 | Pi-hole DNS failure - individual DNS service down |
| Test 5 | dnscrypt DNS failure - individual DNS service down |
| Test 6 | Cloudflare DNS failure - public DNS unavailable |
| Test 7 | All DNS services fail - complete DNS chain down |
| Test 8 | DNS issue with connectivity OK - partial failures |
| Test 9 | Pi-hole and dnscrypt fail - multiple DNS hops down |
| Test 10 | `should_log_ok()` scenarios - disk wear reduction logic |
| Test 11 | `should_log_ok()` suppression - recent OK entry handling |
| Test 12 | `should_log_ok()` state change detection - error to OK transitions |
| Test 13 | `rotate_log()` small files - no rotation for < 2MB |
| Test 14 | `rotate_log()` large files - rotation triggered at 2MB |
| Test 15 | `usage()` output - help message display |

### Running Tests

```bash
# From tests directory
cd tests/
./test_internet_health_check.sh

# From parent directory
./tests/test_internet_health_check.sh
```

**Test Results:** ✅ 15 tests passed (100% pass rate)

## Architecture

### Code Organization

The script is organized into the following functional sections:

**1. Configuration & Logging** - Constants, setup, and logging functions
- `log(message)` - Write timestamped messages to file or stderr
- `should_log_ok(interface)` - Intelligent suppression for disk wear reduction (checks 24h timeout, state changes, recent entries)
- `rotate_log()` - Automatic log rotation at 2MB with 7 backups kept

**2. Connectivity Check** - Network interface connectivity testing
- `check_connectivity(interface)` - Tests ping to target IP, returns OK/DOWN
- Logs detailed failure messages with target, timeout info

**3. DNS Chain Checks** - Multi-layer DNS validation
- `check_dns(interface, server, port)` - Generic DNS query function using dig
- Tests three DNS endpoints in sequence:
  - Pi-hole on 127.0.0.1:53
  - dnscrypt-proxy on 127.0.0.1:5053
  - Cloudflare public DNS on 1.1.1.1:53
- Binds to interface IP using `dig -b` for interface-specific testing
- `check_dns_chain(interface)` - Orchestrates all DNS tests and returns overall DNS status

**4. DNS Results & Diagnostics** - Failure analysis and reporting
- `log_dns_results(interface, results...)` - Logs individual DNS test pass/fail results
- `determine_failure_point(results...)` - Identifies which DNS service failed
- `log_dns_diagnostics(interface, failure_point)` - Logs detailed diagnostic messages

**5. Status Reporting** - Final status determination
- `determine_current_status(interface, connectivity, dns_ok)` - Combines connectivity + DNS results
- Outputs: `OK` for healthy, `DOWN - CONNECTIVITY OUTAGE` for ping failure, or `DOWN` blocks for DNS issues

**6. Argument Parsing & Main Execution** - Optional flags and orchestration
- `usage()` - Displays help message
- `main()` - Parses flags (`--log-file`, `--reduce-disk-wear`, `-h/--help`)
- Iterates through interfaces (eth0, wlan0)
- Handles missing interfaces gracefully

### Multi-Interface Support

Both interfaces (eth0 and wlan0) are tested independently:
- Sequentially: eth0 first, then wlan0
- Each gets complete connectivity + DNS validation
- Separate log entries enable independent monitoring
- Allows you to track wired vs wireless health separately

### Scenario Examples

**Scenario 1: All Systems Healthy**
```
Log: [INTERNET-HEALTH-CHECK] [eth0] OK
Log: [INTERNET-HEALTH-CHECK] [wlan0] OK
```

**Scenario 2: Pi-hole DNS Fails**
```
Log: [INTERNET-HEALTH-CHECK] [eth0] DOWN
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Fail via Pi-hole (127.0.0.1:53)
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via dnscrypt-proxy (127.0.0.1:5053)
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via Cloudflare public (1.1.1.1:53)
Log: [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole × dnscrypt-proxy → Cloudflare
Log: [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole forwarding
Log: [INTERNET-HEALTH-CHECK] [eth0] Issue: DNS issue detected. Connectivity still OK
Log: [INTERNET-HEALTH-CHECK] [eth0] DOWN
```

**Scenario 3: No Internet Connectivity**
```
Log: [INTERNET-HEALTH-CHECK] [eth0] Test: Fail during Ping - 1.1.1.1 did not respond
Log: [INTERNET-HEALTH-CHECK] [eth0] DOWN - CONNECTIVITY OUTAGE detected
```

## DNS Chain Visualization

The script shows DNS chain status using a simple notation to indicate where failures occur:

- `→` = Connection works  
- `×` = Connection fails

**Failure point examples:**
- Pi-hole fails: `Pi-hole × dnscrypt-proxy → Cloudflare` (Pi-hole can't reach dnscrypt-proxy)
- dnscrypt fails: `Pi-hole → dnscrypt-proxy × Cloudflare` (dnscrypt-proxy can't reach Cloudflare)
- Cloudflare fails: `Pi-hole → dnscrypt-proxy × Cloudflare` (Cloudflare upstream unreachable)

The issue description clarifies which component is actually failing and suggests the probable cause.

---

**Last Updated:** February 17, 2026

