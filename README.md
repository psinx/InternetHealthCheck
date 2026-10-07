# Internet Health Check

Lightweight Bash and telemetry monitor for internet connectivity and DNS chain health on Linux, Raspberry Pi OS, and macOS. Features a native Pi-hole v6 AdminLTE web dashboard, zero-disk-wear RAM state tracking, 72-hour historical SLA grid, and real-time CLI diagnostics.

[![Version v3.1.0](https://img.shields.io/badge/version-3.1.0-blue.svg)](https://github.com/psinx/InternetHealthCheck/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Quick Start

```bash
# Interactive real-time check (terminal visual display)
./internet_health_check.sh

# Syslog format to stdout
./internet_health_check.sh --format log

# Client check against remote Pi-hole (skipping Hop 2 dnscrypt)
./internet_health_check.sh --pihole-host 192.168.1.2 --skip-dnscrypt

# Run test suite
./tests/test_internet_health_check.sh
```

---

## Installation & Deployment

### Prerequisites

* **Linux (Debian / Ubuntu / Raspberry Pi OS)**:
  ```bash
  sudo apt-get install -y bash curl dnsutils iproute2 iputils-ping python3
  ```
* **macOS**: Built-in tools (`ping`, `dig`, `ifconfig`, `scutil`, `python3`) supported out-of-the-box.

### 1. Pi-hole Server Setup (Production)

Clone the repository:
```bash
git clone https://github.com/psinx/InternetHealthCheck.git ~/InternetHealthCheck
cd ~/InternetHealthCheck
chmod +x internet_health_check.sh tests/test_internet_health_check.sh
```

Deploy web assets to your web server root and/or Pi-hole admin:
```bash
sudo mkdir -p /var/www/html/health /var/www/html/admin

# Standalone dashboards (http://<pi-ip>/ and http://<pi-ip>/health/)
sudo cp -f templates/dashboard.html /var/www/html/index.html
sudo cp -f templates/app.js /var/www/html/app.js
sudo cp -f templates/dashboard.html /var/www/html/health/index.html
sudo cp -f templates/app.js /var/www/html/health/app.js

# Pi-hole v6 AdminLTE page (http://<pi-ip>/admin/health.lp)
sudo cp -f templates/health.lp /var/www/html/admin/health.lp

sudo chown -R www-data:www-data /var/www/html/health
```

Add a cron job (`crontab -e`) to poll every 5 minutes:
```cron
*/5 * * * * ~/InternetHealthCheck/internet_health_check.sh --reduce-disk-wear --html-file /var/www/html/health/index.html --log-file ~/InternetHealthCheck/logs/internet_health.log >/dev/null 2>&1
```

> **Why `--reduce-disk-wear`?**  
> High-frequency 5-minute states are buffered in RAM (`/dev/shm/internet_health_history.txt`). Redundant `OK` entries are suppressed from disk logs, only writing during outages, state transitions, or 24-hour heartbeats to protect SD cards from wear. Concurrency is guarded via non-blocking POSIX `flock`.

### 2. Client Setup (macOS / Linux Workstation)

To run as a client monitor against a remote Pi-hole:
```bash
git clone https://github.com/psinx/InternetHealthCheck.git
cd InternetHealthCheck
./internet_health_check.sh --pihole-host 192.168.1.2 --skip-dnscrypt
```

---

## CLI Options

| Flag | Argument | Description |
|---|---|---|
| `--reduce-disk-wear` | None | Buffer state in RAM (`/dev/shm`); write to disk only on state change/outage |
| `--html-file` | `FILE` | Write `status.json` and deploy web assets to target directory |
| `--log-file` | `FILE` | Persistent disk log path (default: stdout or `logs/internet_health.log`) |
| `--interfaces` | `IFACES` | Comma-separated interface list (default: auto-detected) |
| `--pihole-host` | `HOST` | Pi-hole host/IP (default: `127.0.0.1` on Linux, LAN resolver on macOS) |
| `--dnscrypt-host` | `HOST` | dnscrypt-proxy host/IP (default: `127.0.0.1`) |
| `--skip-dnscrypt` | None | Skip dnscrypt-proxy hop (recommended for client checks) |
| `--upstream-dns` | `IP` | Upstream DNS server to query (default: auto-detected or `1.1.1.3`) |
| `--format` | `pretty\|log` | Visual checklist (`pretty`) or timestamped syslog (`log`) |
| `-h`, `--help` | None | Display help message |

---

## Dashboard Architecture

The web dashboard is organized into four tiers matching Pi-hole v6 styling:

1. **Live DNS Chain Diagnostics**: `CLIENT` ➔ `Pi-hole` (`:53`) ➔ `dnscrypt-proxy` (`:5053`) ➔ `Cloudflare` (`1.1.1.3:53`), with multiline interface status (`eth0: Online`, `wlan0: Online`).
2. **Live Status**: Hop latency benchmarks and network interface packet loss metrics.
3. **Historical Uptime (72 Hours)**: Chronological 3-row uptime grid (*2 Days Ago*, *Yesterday*, *Today*) with hover tooltips showing root-cause failures and SLA percentage.
4. **Recent Events & Outages Log**: Timestamped table of interface link drops and WAN outages.

* **Single-Pass Telemetry**: The script writes a consolidated `status.json` in a single run, and the front-end polls it asynchronously every 30 seconds with relative freshness tickers.
* **Auto Theme**: Automatically matches system `prefers-color-scheme` (dark/light mode).
* **Clean UI**: Semantic AdminLTE status badges without unicode symbol clutter.

---

## Testing

Run the automated test suite (26 assertions covering DNS chains, lock contention, RAM fallback, and telemetry generation):

```bash
./tests/test_internet_health_check.sh
```

---

## Releases & Changelog

Release history and release notes are maintained directly in [GitHub Releases](https://github.com/psinx/InternetHealthCheck/releases).

---

## License

[MIT](LICENSE)
