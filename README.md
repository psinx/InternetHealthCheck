# Internet Health Check 2.0

A modular, lightweight Bash suite for monitoring internet connectivity and DNS chain health on Linux and Raspberry Pi OS. Features a native **Pi-hole v6 AdminLTE** web dashboard, zero-disk-wear RAM state tracking, interactive 72-hour historical SLA grid, auto dark/light theme switching, floating root-cause diagnostics tooltips, and real-time CLI diagnostics.

[![Version v2.0.0](https://img.shields.io/badge/version-2.0.0-blue.svg)](https://github.com/psinx/InternetHealthCheck/releases/tag/v2.0.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## 🚀 Quick Start

```bash
# Run real-time diagnostic scan
./internet_health_check.sh --diagnose

# Run standard health check (output to stdout)
./internet_health_check.sh

# Run health check with Pi-hole v6 HTML dashboard & RAM-based disk-wear protection
./internet_health_check.sh --log-file logs/internet_health.log --reduce-disk-wear --html-file /var/www/html/health.html

# Run automated test suite
./tests/test_internet_health_check.sh
```

---

## 🌟 Key Features

* **Native Pi-hole v6 AdminLTE Dashboard Integration**:
  * Styled natively after Pi-hole v6 using AdminLTE v3 layout engine and theme CSS variables.
  * **Auto Dark / Light Mode**: Automatically switches between dark and light themes following system `prefers-color-scheme`, matching Pi-hole admin behavior.
  * **Mobile Responsive**: Adapts DNS chain diagram into a 2×2 grid on mobile viewports with a ☰ hamburger sidebar toggle.

* **72-Hour Historical SLA Grid & Floating Tooltips**:
  * Chronological 3-row uptime grid (*2 Days Ago*, *Yesterday*, *Today*) with local clock hour mapping.
  * **● STATUS: Operational** and **● SLA: XX.XX%** status badges with dynamic threshold color coding (Green ≥ 99.0%, Orange 95.0%–98.99%, Red < 95.0%).
  * **Floating Interactive Tooltips**: Hover over grid cells to inspect graphical mini DNS chain flows (`Client -> Pi-hole -> dnscrypt-proxy -> Cloudflare`), root-cause component failure state (`OK` vs `FAIL`), and affected network interface breakdown (`eth0`, `wlan0`).

* **Smart Multi-Interface & Maintenance Window Tolerance**:
  * Distinguishes total WAN outages (🔴 **`DANGER`**) vs single-interface failover / DNS forwarding glitches (🟠 **`WARNING`**).
  * Ignores single-interface `wlan0` maintenance drops (such as planned 30-minute weekly router reboots) when primary wired `eth0` is healthy and carrying traffic, avoiding false SLA penalties.

* **Zero Disk Wear for Raspberry Pi**:
  * Stores high-frequency 5-minute RAM state records in `/dev/shm/internet_health_history.txt`.
  * Restricts disk log writes to state transitions and outages to protect SD card longevity.

* **Multi-Hop DNS Chain & Interface Auto-Detection**:
  * Sequentially validates:
    1. **Pi-hole** (`127.0.0.1:53`)
    2. **dnscrypt-proxy** (`127.0.0.1:5053`)
    3. **Upstream Public DNS** (Cloudflare `1.1.1.3:53` / Google `8.8.8.8`)
  * Auto-detects active interfaces (`eth0`, `wlan0`) and reads `dnscrypt-proxy` configuration files for dynamic resolver IP resolution.

---

## 📁 Repository Structure

```
.
├── internet_health_check.sh   # Main CLI runner, daemon entrypoint, & flag parser
├── lib/
│   ├── network.sh             # Network interface discovery, ping, & dig DNS queries
│   ├── logger.sh              # RAM state engine, disk wear reduction, & log rotation
│   └── diagnose.sh            # Terminal diagnostic scanner (--diagnose)
├── templates/
│   ├── dashboard.html         # Native Pi-hole v6 AdminLTE dashboard template
│   ├── app.js                 # CSP-compliant dashboard renderer & tooltip engine
│   └── health.lp              # Pi-hole v6 Lua template integration page
├── tests/
│   └── test_internet_health_check.sh  # Automated unit & integration test suite (18 tests)
├── CHANGELOG.md               # Version release notes (v1.0.0, v2.0.0)
└── logs/                      # Log directory (auto-rotated at 2 MB)
```

---

## 🛠️ Usage & CLI Options

```bash
Usage: ./internet_health_check.sh [OPTIONS]

Options:
  --log-file FILE       Write logs to FILE instead of stdout.
  --reduce-disk-wear    Reduce log writes: store rolling history in RAM (/dev/shm/),
                        only write state changes or outages to disk log.
  --html-file FILE      Generate a Pi-hole v6 style HTML status dashboard at FILE.
  --interfaces IFACES   Comma-separated list of interfaces (e.g., "eth0,wlan0").
                        Defaults to auto-detecting all active interfaces.
  --upstream-dns IP     Override upstream DNS IP for resolution testing.
  --diagnose            Perform a real-time terminal diagnostics scan and exit.
  -h, --help            Show this help message.
```

---

## 📊 Live Terminal Diagnostics (`--diagnose`)

Run `./internet_health_check.sh --diagnose` to inspect network health directly in your terminal:

```
==========================================
INTERNET HEALTH - REAL-TIME DIAGNOSTICS
==========================================

Checking Interface: eth0
  ✓ 1. Physical Link: CONNECTED
  ✓ 2. Local IP Assigned: 192.168.1.2
  ✓ 3. Gateway Ping (192.168.1.1): RESPONDING
  4. DNS Chain Resolution:
     ✓ Hop 1 (Pi-hole @127.0.0.1:53): PASS (4ms)
     ✓ Hop 2 (dnscrypt-proxy @127.0.0.1:5053): PASS (4ms)
     ✓ Hop 3 (Cloudflare public @1.1.1.3:53): PASS (16ms)
  STATUS: Interface online and fully operational.
```

---

## 🛡️ Raspberry Pi & SD Card Optimization (`--reduce-disk-wear`)

When running via `cron` (e.g. every 5 minutes), the `--reduce-disk-wear` flag:
1. Writes high-frequency status updates to RAM (`/dev/shm/internet_health_history.txt`).
2. Suppresses redundant `OK` disk log entries while connectivity remains healthy.
3. Automatically triggers an immediate disk write and syslog alert upon **state changes** (e.g. `OK` ➔ `OUTAGE` or `OUTAGE` ➔ `OK`).
4. Logs a 24-hour heartbeat to preserve long-term historical records across reboots.

---

## 🧪 Test Suite

Run the automated unit and integration test suite:

```bash
./tests/test_internet_health_check.sh
```

**Results:** ✅ 18 tests passed (100% pass rate)

---

## 📄 License

MIT License. See [LICENSE](file:///workspace/LICENSE) for details.
