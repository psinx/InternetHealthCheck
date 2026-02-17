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

### Successful System Status
```
Log: [INTERNET-HEALTH-CHECK] [eth0] OK
Log: [INTERNET-HEALTH-CHECK] [wlan0] OK
```

### Connectivity Failure
```
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

Comprehensive test coverage with 12 test scenarios (100% passing):

| Test | Coverage |
|------|----------|
| All systems OK | Verifies normal operation |
| Connectivity DOWN | Ping failure detection |
| Repeated OK state | Multiple runs with OK state |
| Pi-hole DNS fails | Individual service failure detection |
| dnscrypt DNS fails | Individual service failure detection |
| Cloudflare DNS fails | Individual service failure detection |
| All DNS fails | Multiple service failure handling |
| DNS issue with OK connectivity | Partial failure detection |
| Partial failures | Multiple service combinations |
| Multi-interface coordination | eth0 and wlan0 independent checks |
| Disk wear reduction logic | OK suppression within 24h window |
| State inference from logs | Reads last run from log file |

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

### Scenario 1: All Systems Healthy
```
Log: [INTERNET-HEALTH-CHECK] [eth0] OK
Log: [INTERNET-HEALTH-CHECK] [wlan0] OK
```

### Scenario 2: Pi-hole DNS Fails
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

### Scenario 3: No Internet Connectivity
```
Log: [INTERNET-HEALTH-CHECK] [eth0] DOWN - CONNECTIVITY OUTAGE detected
```

## DNS Chain Visualization

The script shows DNS chain status using a simple notation:

- `→` = Connection works
- `×` = Connection fails

**Examples:**
- Pi-hole fails: `Pi-hole × dnscrypt-proxy → Cloudflare`
- dnscrypt fails: `Pi-hole → dnscrypt-proxy × Cloudflare`
- Cloudflare fails: `Pi-hole → dnscrypt-proxy × Cloudflare` (same as dnscrypt)

The issue description clarifies which component is actually failing.

---

**Last Updated:** February 17, 2026
# InternetHealthCheck
