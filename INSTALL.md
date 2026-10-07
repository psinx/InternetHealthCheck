# Installation & Deployment Guide

This guide walks through setting up **Internet Health Check** on:
1. **Pi-hole v6 Server (Raspberry Pi OS / Debian / Ubuntu)** — *Recommended production setup with full AdminLTE web dashboard, zero-disk-wear RAM logging, and cron/systemd automation.*
2. **Client Workstation (macOS / Linux)** — *Client-side CLI health checks monitoring local network interfaces and LAN Pi-hole resolvers.*

---

## 📋 System Requirements & Prerequisites

### Linux (Raspberry Pi OS, Debian, Ubuntu)
Install the standard networking and DNS utilities:
```bash
sudo apt-get update
sudo apt-get install -y bash curl dnsutils iproute2 iputils-ping python3
```
*Note: `python3` (standard in all modern Linux distributions) is required for the single-pass consolidated `status.json` telemetry engine.*

### macOS (Darwin)
No extra packages required! macOS includes `bash`, `curl`, `dig`, `ifconfig`, `ping`, `scutil`, and `python3` out-of-the-box.

---

## 🚀 Method 1: Production Pi-hole v6 Server Installation

### Step 1: Clone the Repository
Clone the repository to a permanent location (e.g., `~/InternetHealthCheck` or `/opt/InternetHealthCheck`):
```bash
cd ~
git clone https://github.com/psinx/InternetHealthCheck.git
cd InternetHealthCheck
chmod +x internet_health_check.sh tests/test_internet_health_check.sh
```

### Step 2: Deploy Web Dashboard Assets
Internet Health Check provides three web dashboard endpoints:
* **Root Standalone Dashboard**: Accessible at `http://<pi-ip>/`
* **Dedicated Health Route**: Accessible at `http://<pi-ip>/health/`
* **Pi-hole v6 Admin Interface**: Integrated Lua page accessible at `http://<pi-ip>/admin/health.lp`

Create the web directories and copy the dashboard assets:
```bash
# Create target web directories
sudo mkdir -p /var/www/html/health /var/www/html/admin

# 1. Deploy Root Dashboard
sudo cp -f templates/dashboard.html /var/www/html/index.html
sudo cp -f templates/app.js /var/www/html/app.js

# 2. Deploy Subdirectory Dashboard (/health/)
sudo cp -f templates/dashboard.html /var/www/html/health/index.html
sudo cp -f templates/app.js /var/www/html/health/app.js

# 3. Deploy Native Pi-hole v6 Admin Template
sudo cp -f templates/health.lp /var/www/html/admin/health.lp

# Ensure the web server (www-data) can read files and write status.json
sudo chown -R www-data:www-data /var/www/html/health
sudo chmod -R 755 /var/www/html
```

### Step 3: Configure Automated Monitoring

#### Option A: Cron Job (Recommended & Simple)
Edit the crontab for your monitoring user (or `root`):
```bash
crontab -e
```
Add the following line to run the health check every 5 minutes (or `* * * * *` for every minute):
```cron
*/5 * * * * /home/prateek/InternetHealthCheck/internet_health_check.sh --reduce-disk-wear --html-file /var/www/html/health/index.html --log-file /home/prateek/InternetHealthCheck/logs/internet_health.log >/dev/null 2>&1
```

> [!TIP]
> **What `--reduce-disk-wear` does:**
> High-frequency health state records are written to high-speed RAM (`/dev/shm/internet_health_history.txt`). Redundant `OK` entries are suppressed, writing to disk only upon outages, state transitions, or 24h heartbeats to maximize Raspberry Pi SD card longevity.
>
> **Concurrency Protection:**
> The script automatically uses non-blocking POSIX `flock` (`/dev/shm/internet_health_check.lock`) to prevent overlapping executions if a probe takes longer than usual.

#### Option B: Systemd Service & Timer (Alternative)
If you prefer systemd timers over cron:

1. Create `/etc/systemd/system/internet-health.service`:
```ini
[Unit]
Description=Internet Health Check & DNS Diagnostics
After=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/opt/InternetHealthCheck/internet_health_check.sh --reduce-disk-wear --html-file /var/www/html/health/index.html --log-file /var/log/internet_health.log
```

2. Create `/etc/systemd/system/internet-health.timer`:
```ini
[Unit]
Description=Run Internet Health Check every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min
AccuracySec=10s

[Install]
WantedBy=timers.target
```

3. Enable and start the timer:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now internet-health.timer
sudo systemctl status internet-health.timer
```

---

## 🍏 Method 2: Client Workstation Installation (macOS / Linux Client)

Run Internet Health Check directly on your Mac or Linux desktop to monitor your LAN link and verify queries reaching your Pi-hole server:

```bash
git clone https://github.com/psinx/InternetHealthCheck.git
cd InternetHealthCheck

# Run visual health check pointing to your Pi-hole IP (bypassing Hop 2 dnscrypt):
./internet_health_check.sh --pihole-host 192.168.1.2 --skip-dnscrypt
```

---

## 🔍 Verification & Testing

### 1. Run an Interactive Health Check
Execute the script manually to ensure interface auto-detection and DNS resolution are working:
```bash
./internet_health_check.sh
```
Expected output:
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

### 2. Verify `status.json` Telemetry Generation
Check that `status.json` was generated with SLA, interfaces, history, and incident data:
```bash
cat /var/www/html/health/status.json
```

### 3. Run the Automated Test Suite
Run the 26-assertion unit and integration test suite:
```bash
./tests/test_internet_health_check.sh
```
All tests should pass:
```text
==========================================
Results: 26 passed, 0 failed
==========================================
✓ All tests passed!
```

### 4. Verify in Browser
Open `http://<your-pihole-ip>/` or `http://<your-pihole-ip>/health/` in your browser. You should see:
* **Row 1**: Live DNS Chain Diagnostics (`CLIENT` -> `Pi-hole` -> `dnscrypt-proxy` -> `Cloudflare`).
* **Row 2**: Hop Latency Benchmark & Network Interfaces (Live Status).
* **Row 3**: Historical Uptime (Last 72 Hours) with chronological 2 Days Ago -> Yesterday -> Today.
* **Row 4**: Recent Events & Outages Log.

---

## ⚙️ CLI Flags & Options Reference

| Flag | Argument | Description |
|---|---|---|
| `--reduce-disk-wear` | None | Stores rolling status in RAM (`/dev/shm`), writing to disk only on state transitions or outages. |
| `--html-file` | `FILE` | Generates dashboard and writes consolidated `status.json` to the target directory. |
| `--log-file` | `FILE` | Path to persistent disk log (defaults to stdout or `logs/internet_health.log`). |
| `--interfaces` | `IFACES` | Comma-separated interface list (e.g., `eth0,wlan0`). Defaults to auto-discovery. |
| `--pihole-host` | `HOST` | Pi-hole host/IP to query (default: `127.0.0.1` on server, or LAN IP on client). |
| `--dnscrypt-host` | `HOST` | dnscrypt-proxy host/IP to query (default: `127.0.0.1`). |
| `--skip-dnscrypt` | None | Bypasses dnscrypt hop (recommended for LAN client checks). |
| `--upstream-dns` | `IP` | Upstream DNS server to test (default: auto-detected or `1.1.1.3`). |
| `--format` | `pretty|log` | Visual checklist (`pretty`) or syslog format (`log`). |
| `-h`, `--help` | None | Display usage and help message. |

---

## 🗑️ Uninstallation

To remove Internet Health Check:
1. Remove cron job (`crontab -e`) or stop systemd timer:
   ```bash
   sudo systemctl disable --now internet-health.timer
   sudo rm -f /etc/systemd/system/internet-health.*
   sudo systemctl daemon-reload
   ```
2. Remove dashboard assets:
   ```bash
   sudo rm -rf /var/www/html/health /var/www/html/admin/health.lp
   ```
3. Remove RAM files:
   ```bash
   rm -f /dev/shm/internet_health_* /tmp/internet_health_*
   ```
4. Remove repository folder:
   ```bash
   rm -rf ~/InternetHealthCheck
   ```
