# Internet Health Check

A comprehensive bash script for monitoring internet connectivity and DNS chain health, with complete test coverage and refactored for production use.

## Quick Start

```bash
# Run the health check
./internet_health_check.sh

# Run tests
cd tests/
./test_internet_health_check.sh

# View logs
tail -f logs/internet_health.log

# Check status
cat logs/last_status
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
| `internet_health_check.sh` | Main script (PRODUCTION READY) |
| `tests/test_internet_health_check.sh` | Test suite (10 tests, 100% pass rate) |
| `logs/internet_health.log` | Monitoring logs (auto-rotated at 2MB) |
| `logs/last_status` | Current status file |

## Script Features

### Connectivity Monitoring

## Log Format

Example output when DNS issue detected:
```
2026-02-16 21:02:22 [HEALTH-CHECK] DOWN
2026-02-16 21:02:22 [HEALTH-CHECK] Test: Fail via Pi-hole (127.0.0.1:53)
2026-02-16 21:02:22 [HEALTH-CHECK] Test: Pass via dnscrypt-proxy (127.0.0.1:5053)
2026-02-16 21:02:22 [HEALTH-CHECK] Test: Pass via Cloudflare public (1.1.1.1:53)
2026-02-16 21:02:22 [HEALTH-CHECK] Issue: Pi-hole × dnscrypt-proxy → Cloudflare
2026-02-16 21:02:22 [HEALTH-CHECK] Issue: Pi-hole forwarding
2026-02-16 21:02:22 [HEALTH-CHECK] Issue: DNS issue detected. Connectivity still OK
2026-02-16 21:02:22 [HEALTH-CHECK] DOWN
```

**Key indicators:**
- `Test: Pass` - DNS service responding
- `Test: Fail` - DNS service not responding
- `Issue: × location` - Where the chain breaks
- `Issue: description` - Why it failed
- `DOWN` markers - Start and end of error block

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

## Script Output States

The script saves state to `logs/last_status`:
- `OK` - All systems operational
- `DNS_ISSUE` - DNS problem detected but connectivity OK
- `CONNECTIVITY_DOWN` - No internet connectivity

## Usage

### Standalone Execution
```bash
./internet_health_check.sh
```

### Schedule with Cron
```bash
# Run every 5 minutes
*/5 * * * * ~/InternetHealthCheck/internet_health_check.sh
```

### View Results
```bash
# Real-time log viewing
tail -f ~/InternetHealthCheck/logs/internet_health.log

# View current status
cat ~/InternetHealthCheck/logs/last_status

# Check recent health checks (last 50 lines)
tail -50 ~/InternetHealthCheck/logs/internet_health.log
```

### Log Rotation
Logs are automatically rotated when they exceed 2MB:
- Current log: `internet_health.log`
- Rotated logs: `internet_health.log.1.gz`, `internet_health.log.2.gz`, etc.
- Maximum 7 rotated logs kept

## Test Suite

Comprehensive test coverage with 10 test scenarios:

| Test | Coverage |
|------|----------|
| All systems OK | Verifies normal operation |
| Connectivity DOWN | Ping failure detection |
| Connectivity recovery | State transition after outage |
| Pi-hole DNS fails | Individual service failure detection |
| dnscrypt DNS fails | Individual service failure detection |
| Cloudflare DNS fails | Individual service failure detection |
| All DNS fails | Multiple service failure handling |
| Repeated OK state | No spurious recovery messages |
| DNS issue with OK connectivity | Partial failure state |
| Partial failures | Multiple service combinations |

### Running Tests

```bash
# From tests directory
cd tests/
./test_internet_health_check.sh

# From parent directory
./tests/test_internet_health_check.sh
```

**Test Results:** ✅ 10 tests passed (100% pass rate)

## Architecture & Refactoring

### Code Organization

### Scenario 1: All Systems Healthy
```
Log: [HEALTH-CHECK] OK
Status: OK
```

### Scenario 2: Pi-hole DNS Fails
```
Log: [HEALTH-CHECK] DOWN
Log: [HEALTH-CHECK] Test: Fail via Pi-hole (127.0.0.1:53)
Log: [HEALTH-CHECK] Test: Pass via dnscrypt-proxy (127.0.0.1:5053)
Log: [HEALTH-CHECK] Test: Pass via Cloudflare public (1.1.1.1:53)
Log: [HEALTH-CHECK] Issue: Pi-hole × dnscrypt-proxy → Cloudflare
Log: [HEALTH-CHECK] Issue: Pi-hole forwarding
Log: [HEALTH-CHECK] Issue: DNS issue detected. Connectivity still OK
Log: [HEALTH-CHECK] DOWN
Status: DNS_ISSUE
```

### Scenario 3: No Internet Connectivity
```
Log: [HEALTH-CHECK] ALERT - PING FAIL: 1.1.1.1 did not respond (connectivity outage)
Status: CONNECTIVITY_DOWN
```

### Scenario 4: Connectivity Restored
```
Log: [HEALTH-CHECK] RECOVERED - Connectivity restored
Status: OK
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

**Last Updated:** February 16, 2026
# InternetHealthCheck
