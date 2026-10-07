# Internet Health Check 3.1

A modular, lightweight Bash and telemetry suite for monitoring internet connectivity and DNS chain health on Linux, Raspberry Pi OS, and macOS. Features a native **Pi-hole v6 AdminLTE** web dashboard, zero-disk-wear RAM state tracking, interactive 72-hour historical SLA grid, recent incident logs, auto dark/light theme switching, floating root-cause diagnostics tooltips, and real-time CLI diagnostics.

[![Version v3.1.0](https://img.shields.io/badge/version-3.1.0-blue.svg)](https://github.com/psinx/InternetHealthCheck/releases/tag/v3.1.0)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

---

## 🚀 Quick Start

```bash
# Run real-time check (pretty visual output in terminal)
./internet_health_check.sh

# Run check with standard log lines to stdout
./internet_health_check.sh --format log

# Run on macOS client monitoring LAN Pi-hole server
./internet_health_check.sh --pihole-host 192.168.1.2 --skip-dnscrypt

# Run health check with Pi-hole v6 HTML dashboard & RAM-based disk-wear protection
./internet_health_check.sh --log-file logs/internet_health.log --reduce-disk-wear --html-file /var/www/html/health/index.html

# Run automated test suite (26 assertions)
./tests/test_internet_health_check.sh
```

> [!IMPORTANT]
> **Looking for full production deployment instructions?**  
> Check the dedicated [**Installation & Deployment Guide (INSTALL.md)**](file:///workspaces/InternetHealthCheck/INSTALL.md) for step-by-step setup on Raspberry Pi OS, Pi-hole v6 web integration, cron automation, and systemd services.

---

## 🌟 Key Features

* **Native Pi-hole v6 AdminLTE Dashboard Integration**:
  * Styled natively after Pi-hole v6 using AdminLTE layout engine and theme CSS variables.
  * **Auto Dark / Light Mode**: Automatically switches between dark and light themes following system `prefers-color-scheme`, perfectly matching Pi-hole admin behavior.
  * **Clean Typography**: Clutter-free design with semantic AdminLTE status badges and clean typography (no unicode symbol noise).
  * **Mobile Responsive**: Adapts DNS chain diagram into an intuitive multi-column grid on mobile viewports with a ☰ hamburger sidebar toggle.

* **Structured 4-Tier Dashboard Layout**:
  1. **Row 1 — Live DNS Chain Diagnostics**: Visual chain flow (`CLIENT` ➔ `Pi-hole` ➔ `dnscrypt-proxy` ➔ `Cloudflare`) with multiline interface status (`eth0: Online`, `wlan0: Online`).
  2. **Row 2 — Live Status Badges**: Hop Latency Benchmarks (Pi-hole, dnscrypt, Cloudflare) and Network Interfaces link/packet loss tracking.
  3. **Row 3 — Historical Uptime (Last 72 Hours)**: Chronological 3-row grid (*2 Days Ago*, *Yesterday*, *Today*) with local clock hour mapping and dynamic SLA percentage.
  4. **Row 4 — Recent Events & Outages Log**: Detailed timestamped incident table capturing interface disconnects and outages.

* **72-Hour Historical SLA Grid & Floating Tooltips**:
  * Chronological 3-row uptime grid with 24-hour hour-block resolution.
  * **STATUS: Healthy** and **SLA: XX.XX%** status badges with dynamic threshold color coding (Green ≥ 99.0%, Orange 95.0%–98.99%, Red < 95.0%).
  * **Floating Interactive Tooltips**: Hover over grid cells to inspect graphical mini DNS chain flows, root-cause component failure state (`OK` vs `FAIL`), and affected network interface breakdown (`eth0`, `wlan0`).

* **Single-Pass Consolidated Telemetry Backend (`status.json`)**:
  * Lightning-fast Python-powered state compiler generating consolidated `status.json` with SLA metrics, 72h historical grid states, active interface telemetry, and recent incident logs in a single run.
  * Asynchronous front-end polling with relative timestamp ticker ("Updated: just now", "Updated: 2m ago", with automatic "Stale" alerts).

* **Smart Multi-Interface & Maintenance Window Tolerance**:
  * Distinguishes total WAN outages (`DANGER`) vs single-interface failover / DNS forwarding glitches (`WARNING`).
  * Ignores single-interface `wlan0` maintenance drops (such as planned 30-minute weekly router reboots) when primary wired `eth0` is healthy and carrying traffic, avoiding false SLA penalties.

* **Zero Disk Wear for Raspberry Pi & Concurrency Locking**:
  * Stores high-frequency 5-minute RAM state records in `/dev/shm/internet_health_history.txt` (falls back to `/tmp/` on macOS).
  * Restricts disk log writes to state transitions and outages to maximize SD card longevity.
  * Non-blocking POSIX `flock` concurrency locking prevents overlapping cron runs.

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
├── internet_health_check.sh   # Main CLI runner, telemetry compiler, & flag parser
├── INSTALL.md                 # Detailed installation & production deployment guide
├── README.md                  # Project overview & documentation
├── CHANGELOG.md               # Version release notes (v1.0.0 through v3.1.0)
├── lib/
│   ├── network.sh             # Network interface discovery, ping, & dig DNS queries
│   ├── logger.sh              # RAM state engine, disk wear reduction, & log rotation
│   └── display.sh             # Terminal formatting and visual status output
├── templates/
│   ├── dashboard.html         # Native Pi-hole v6 AdminLTE dashboard template
│   ├── app.js                 # CSP-compliant dashboard renderer & tooltip engine
│   └── health.lp              # Native Pi-hole v6 Lua template integration page
├── tests/
│   └── test_internet_health_check.sh  # Automated unit & integration test suite (26 assertions)
└── logs/                      # Log directory (auto-rotated at 2 MB)
```

---

## 🛠️ Usage & CLI Options

```bash
Usage: ./internet_health_check.sh [OPTIONS]

Options:
  --log-file FILE       Write logs to FILE instead of stdout.
  --reduce-disk-wear    Reduce log writes: store rolling history in RAM (/dev/shm/ or /tmp),
                        only write state changes or outages to disk log.
  --format FORMAT       Output format: 'pretty' (visual checklist) or 'log' (syslog style).
                        Defaults to 'pretty' in interactive terminals, 'log' when piped/cron.
  --pretty              Shortcut for --format pretty.
  --log-format          Shortcut for --format log.
  --html-file FILE      Generate a Pi-hole v6 style HTML status dashboard at FILE and status.json.
  --interfaces IFACES   Comma-separated list of interfaces (e.g., "eth0,wlan0" or "en0").
                        Defaults to auto-detecting all active interfaces.
  --upstream-dns IP     Override upstream DNS IP for resolution testing (default: 1.1.1.3).
  --pihole-host HOST    Pi-hole host/IP to query (default: 127.0.0.1 on Linux, LAN IP on Mac).
  --dnscrypt-host HOST  dnscrypt-proxy host/IP to query (default: 127.0.0.1).
  --skip-dnscrypt       Skip dnscrypt-proxy hop (ideal for client-side Mac checks).
  -h, --help            Show this help message.
```

---

## 📦 Production Installation Summary

For the complete guide with systemd and permissions, see [**INSTALL.md**](file:///workspaces/InternetHealthCheck/INSTALL.md).

```bash
# 1. Clone into persistent location
git clone https://github.com/psinx/InternetHealthCheck.git ~/InternetHealthCheck
cd ~/InternetHealthCheck

# 2. Deploy dashboard files to web server
sudo mkdir -p /var/www/html/health /var/www/html/admin
sudo cp -f templates/dashboard.html /var/www/html/index.html
sudo cp -f templates/app.js /var/www/html/app.js
sudo cp -f templates/dashboard.html /var/www/html/health/index.html
sudo cp -f templates/app.js /var/www/html/health/app.js
sudo cp -f templates/health.lp /var/www/html/admin/health.lp

# 3. Add to crontab (crontab -e)
*/5 * * * * ~/InternetHealthCheck/internet_health_check.sh --reduce-disk-wear --html-file /var/www/html/health/index.html --log-file ~/InternetHealthCheck/logs/internet_health.log >/dev/null 2>&1
```

---

## 🍏 macOS Compatibility & Client Mode

The suite runs natively on **macOS (Darwin)** without requiring third-party package managers:

* **Zero Extra Dependencies**: macOS includes `ping`, `dig`, `ifconfig`, and `scutil` out-of-the-box.
* **BSD Ping Adaptation**: Automatically detects Darwin and uses `-W <ms>` (milliseconds timeout) and `-S <source_ip>` (unicast source binding), avoiding the standard Linux `-I` and seconds-timeout packet drops.
* **RAM State Fallback**: When `/dev/shm` is not mounted (standard macOS behavior), rolling RAM history transparently falls back to `/tmp/internet_health_history.txt`.
* **Interface Filtering**: Filters out dormant virtual interfaces (e.g., inactive Thunderbolt bridges `en1`–`en6`), inspecting only links with assigned IP addresses (typically `en0` for Wi-Fi).
* **Client Mode**: When run on a Mac workstation, the script can auto-discover your local router or Pi-hole DNS server via `scutil --dns` or point explicitly to your Pi-hole host:
  ```bash
  ./internet_health_check.sh --pihole-host 192.168.1.2 --skip-dnscrypt
  ```

---

## 📊 Live Terminal Output

Running `./internet_health_check.sh` interactively in your terminal displays real-time visual health status:

```text
==========================================
INTERNET HEALTH - REAL-TIME STATUS
==========================================

Interface: eth0
  1. Physical Link: CONNECTED
  2. Local IP Assigned: 192.168.1.2
  3. Internet Ping (1.1.1.1): PASS (16ms, 0% loss)
  4. DNS Chain Resolution:
     Hop 1 (Pi-hole @127.0.0.1:53): PASS (0ms)
     Hop 2 (dnscrypt-proxy @127.0.0.1:5053): PASS (24ms)
     Hop 3 (Cloudflare @1.1.1.3:53): PASS (20ms)
  STATUS: Interface online and fully operational.
```

---

## 🛡️ Raspberry Pi & SD Card Optimization (`--reduce-disk-wear`)

When running via `cron` (e.g. every 5 minutes), the `--reduce-disk-wear` flag:
1. Writes high-frequency status updates to RAM (`/dev/shm/internet_health_history.txt` on Linux, `/tmp/` on macOS).
2. Suppresses redundant `OK` disk log entries while connectivity remains healthy.
3. Automatically triggers an immediate disk write and syslog alert upon **state changes** (e.g. `OK` ➔ `OUTAGE` or `OUTAGE` ➔ `OK`).
4. Logs a 24-hour heartbeat to preserve long-term historical records across reboots.

---

## 🧪 Test Suite

Run the automated unit and integration test suite:

```bash
./tests/test_internet_health_check.sh
```

**Results:** ✅ 21 test scenarios / 26 assertions passed (100% pass rate).

---

## 📄 License

MIT License. See [LICENSE](file:///workspaces/InternetHealthCheck/LICENSE) for details.
