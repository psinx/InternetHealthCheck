# Internet Health Check

A comprehensive bash script for monitoring internet connectivity and DNS chain health with complete test coverage.

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
| `tests/test_internet_health_check.sh` | Test suite (12 tests, 100% pass rate) |
| `logs/internet_health.log` | Monitoring logs (auto-rotated at 2MB) |

## Log Format

All log entries include a timestamp, interface identifier, and status message.

### Successful System Status
```
2026-02-17 10:30:45 [INTERNET-HEALTH-CHECK] [eth0] OK
2026-02-17 10:30:50 [INTERNET-HEALTH-CHECK] [wlan0] OK
```

### Connectivity Failure
```
2026-02-17 10:35:12 [INTERNET-HEALTH-CHECK] Test: Fail during PING on eth0: 1.1.1.1 did not respond (connectivity outage)
2026-02-17 10:35:12 [INTERNET-HEALTH-CHECK] [eth0] DOWN - CONNECTIVITY OUTAGE detected
```

### DNS Chain Issue (with connectivity OK)
```
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] DOWN
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Test: Fail via Pi-hole (127.0.0.1:53)
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via dnscrypt-proxy (127.0.0.1:5053)
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via Cloudflare public (1.1.1.1:53)
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole × dnscrypt-proxy → Cloudflare
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole forwarding
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Issue: DNS issue detected. Connectivity still OK
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth8] DOWN
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

# Run every 5 minutes with disk wear reduction (RPi/SD card optimization)
*/5 * * * * ~/InternetHealthCheck/internet_health_check.sh --log-file ~/InternetHealthCheck/logs/internet_health.log --reduce-disk-wear
```

### Disk Wear Reduction (for RPi)

The `--reduce-disk-wear` flag minimizes SD card/storage wear by reading the log file history to intelligently suppress repetitive OK logs:

**How it works:**
- Reads the last `[eth0] OK` and `[wlan0] OK` lines from the log file
- Compares their timestamps against the log file's modification time
- If both OK entries are within 60 seconds of the last file write, they're from the last complete run
- When both are recent and both are OK, suppresses new OK logs (no write needed)
- **Failures are always logged immediately**, regardless of the flag
- **24-hour timeout**: Always logs after 24 hours of silence

**Why this approach:**
- Log file modification time is the definitive "last write" marker
- If both interfaces' OK entries are recent relative to file mod time, they're definitely from one coherent run
- No separate state file needed - state is inferred from log content vs. filesystem metadata

**Why this matters for RPi:**
- Every write to an SD card reduces its lifespan
- On a 5-minute cron schedule: saves ~98% of disk writes when system is healthy
- Maintains complete failure alerting - issues are logged immediately

**Usage with cron:**
```bash
# Reduces writes while maintaining immediate failure alerts
*/5 * * * * ~/InternetHealthCheck/internet_health_check.sh --log-file ~/logs/internet_health.log --reduce-disk-wear
```

**Example behavior with `--reduce-disk-wear`:**
- Run 1 (12:00): Logs OK for both interfaces
- Runs 2-12 (12:05-13:00): Suppresses OK logs (within 24h, both still OK)
- Run 13 (next day 12:00): Logs OK again (24h threshold passed)
- DNS failure at any time: Logs immediately regardless of flag

**Example behavior with `--log-file` alone (no disk wear reduction):**
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

The test suite includes 9 test functions covering 12 individual test assertions (100% passing):

| Test Function | Assertions | Coverage |
|---|---|---|
| Test 1: All systems OK | 1 | Verifies normal operation |
| Test 2: Connectivity DOWN | 2 | Ping failure detection & alert logging |
| Test 3: Repeated OK state | 1 | Multiple consecutive runs with OK state |
| Test 4: Pi-hole DNS fails | 2 | Individual service failure & diagnostics |
| Test 5: dnscrypt DNS fails | 1 | Individual service failure detection |
| Test 6: Cloudflare DNS fails | 2 | Individual service failure & chain notation |
| Test 7: All DNS services fail | 1 | Multiple service failure handling |
| Test 8: DNS issue with OK connectivity | 1 | Partial failure detection |
| Test 9: Pi-hole and dnscrypt fail | 1 | Multiple service combinations |
| **Total** | **12** | **Complete coverage** |

### Running Tests

```bash
# From tests directory
cd tests/
./test_internet_health_check.sh

# From parent directory
./tests/test_internet_health_check.sh
```

**Test Results:** ✅ 12 tests passed (100% pass rate)

## Architecture

### Code Organization

The script is organized into functional sections:

1. **Configuration & Logging** - Constants, log directory setup, logging functions
   - `log()` - Write timestamped messages to file or stderr
   - `should_log_ok()` - Intelligent OK suppression for disk wear reduction
   - `rotate_log()` - Automatic log rotation at 2MB with 7 backups

2. **Connectivity Check** - Network interface testing
   - `check_connectivity(interface)` - Ping the target IP, return OK/DOWN
   - Logs detailed failure messages including timeout and target

3. **DNS Chain Checks** - Multi-layer DNS validation
   - `check_pihole_dns(interface)` - Query local Pi-hole instance
   - `check_dnscrypt_dns(interface)` - Query dnscrypt-proxy on port 5053
   - `check_cloudflare_dns(interface)` - Query public Cloudflare DNS
   - All functions bind to interface IP using `dig -b` flag for interface-specific testing

4. **DNS Chain Diagnostics** - Failure analysis and reporting
   - `log_dns_results()` - Log individual DNS test results
   - `determine_failure_point()` - Identify which DNS service failed
   - `log_dns_diagnostics()` - Log detailed diagnostic information

5. **Status Reporting** - Final status determination
   - `determine_current_status()` - Combine connectivity + DNS results
   - Output summary: OK, OUTAGE, or DNS ISSUE

6. **Main Execution** - Argument parsing and orchestration
   - Parse `--log-file` and `--reduce-disk-wear` flags
   - Iterate through interfaces (eth0, wlan0)
   - Call check functions and report status
   - Handle missing interfaces gracefully

### Multi-Interface Design

Both interfaces (eth0 and wlan0) are tested independently:
- Sequentially: eth0 first, then wlan0
- Each gets complete connectivity + DNS validation
- Separate log entries enable independent monitoring
- Allows you to track wired vs wireless health separately

### Scenario Examples

**Scenario 1: All Systems Healthy**
```
2026-02-17 10:30:45 [INTERNET-HEALTH-CHECK] [eth0] OK
2026-02-17 10:30:50 [INTERNET-HEALTH-CHECK] [wlan0] OK
```

**Scenario 2: Pi-hole DNS Fails**
```
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] DOWN
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Test: Fail via Pi-hole (127.0.0.1:53)
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via dnscrypt-proxy (127.0.0.1:5053)
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Test: Pass via Cloudflare public (1.1.1.1:53)
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole × dnscrypt-proxy → Cloudflare
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Issue: Pi-hole forwarding
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] Issue: DNS issue detected. Connectivity still OK
2026-02-17 10:40:05 [INTERNET-HEALTH-CHECK] [eth0] DOWN
```

**Scenario 3: No Internet Connectivity**
```
2026-02-17 10:35:12 [INTERNET-HEALTH-CHECK] Test: Fail during PING on eth0: 1.1.1.1 did not respond (connectivity outage)
2026-02-17 10:35:12 [INTERNET-HEALTH-CHECK] [eth0] DOWN - CONNECTIVITY OUTAGE detected
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

