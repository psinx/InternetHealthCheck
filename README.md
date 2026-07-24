# Internet Health Check 2.0

A modular, lightweight Bash suite for monitoring internet connectivity and DNS chain health on Linux and Raspberry Pi OS. Includes a Pi-hole v6 styled web dashboard, zero-disk-wear RAM state tracking, real-time CLI diagnostics, and automated test coverage.

---

## 🚀 Quick Start

```bash
# Run real-time diagnostic scan
./internet_health_check.sh --diagnose

# Run standard health check (output to stdout)
./internet_health_check.sh

# Run health check with Pi-hole v6 HTML dashboard & RAM-based disk-wear protection
./internet_health_check.sh --log-file logs/health.log --reduce-disk-wear --html-file /var/www/html/health/index.html

# Run unit and integration test suite
./tests/test_internet_health_check.sh
```

---

## 🌟 Key Features

* **Modular Architecture**: Decoupled engine into modular components (`lib/network.sh`, `lib/logger.sh`, `lib/diagnose.sh`).
* **Pi-hole v6 Admin Dashboard**: Generates a clean, dark-mode status page (`--html-file`) with 72-hour interactive history grid.
* **Zero Disk Wear for Raspberry Pi**: Supports RAM-based state tracking (`/dev/shm/` or `tmpfs` auto-detection) with intelligent transition logging to protect SD cards and SSDs from wear.
* **Interactive CLI Diagnostics (`--diagnose`)**: Displays a color-coded tree diagram of interface link status, gateway pings, and hop-by-hop DNS chain latencies in your terminal.
* **Multi-Layer DNS Chain Monitoring**: Sequentially validates:
  1. **Pi-hole** (`127.0.0.1:53`)
  2. **dnscrypt-proxy** (`127.0.0.1:5053`)
  3. **Upstream Public DNS** (Cloudflare `1.1.1.1:53` / Google `8.8.8.8`)
* **Dynamic Interface Auto-Detection**: Auto-discovers physical active interfaces (e.g. `eth0`, `wlan0`), filtering out virtual docker/bridge links. Custom interfaces can be specified with `--interfaces`.

---

## 📁 Repository Structure

```
/workspace/
├── internet_health_check.sh   # Main CLI runner, daemon entrypoint, & flag parser
├── lib/
│   ├── network.sh             # Network interface discovery, ping, & dig DNS queries
│   ├── logger.sh              # RAM state engine, disk wear reduction, & log rotation
│   └── diagnose.sh            # Terminal diagnostic scanner (--diagnose)
├── templates/
│   └── dashboard.html         # Pi-hole v6 styled HTML status page template
├── tests/
│   └── test_internet_health_check.sh  # Automated unit & integration test suite (18 tests)
└── logs/                      # Log directory (auto-rotated at 2MB)
```

---

## 🛠️ Usage & Options

```bash
Usage: ./internet_health_check.sh [OPTIONS]

Options:
  --log-file FILE       Write logs to FILE instead of stdout.
  --reduce-disk-wear    Reduce log writes: store rolling history in RAM (/dev/shm/),
                        only write state changes or outages to disk log.
  --html-file FILE      Generate a Pi-hole v6 style HTML status dashboard at FILE.
  --interfaces IFACES   Comma-separated list of interfaces (e.g., "eth0,wlan0").
                        Defaults to auto-detecting all active interfaces.
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
     ✓ Hop 2 (dnscrypt-proxy @127.0.0.1:5053): PASS (0ms)
     ✓ Hop 3 (Cloudflare public @1.1.1.1:53): PASS (16ms)
  STATUS: Interface online and fully operational.
```

---

## 🛡️ Raspberry Pi & SD Card Optimization (`--reduce-disk-wear`)

When running via `cron` (e.g. every 5 minutes), the `--reduce-disk-wear` flag:
1. Writes high-frequency 5-minute status updates to RAM (`/dev/shm/` or `/tmp/`).
2. Suppresses redundant `OK` disk log entries while the connection remains healthy.
3. Automatically triggers an immediate disk write and syslog alert upon **state changes** (e.g. `OK` ➔ `OUTAGE` or `OUTAGE` ➔ `OK`).
4. Logs a 24-hour heartbeat to preserve long-term historical records.

---

## 🧪 Test Suite

Run the test suite to verify script functionality and regression prevention:

```bash
./tests/test_internet_health_check.sh
```

**Results:** ✅ 18 tests passed (100% pass rate)

---

## 📄 License

MIT License. See [LICENSE](file:///workspace/LICENSE) for details.
