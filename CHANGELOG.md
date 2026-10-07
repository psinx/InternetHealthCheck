# Changelog & Release Notes

All notable changes to the **Internet Health Check** project are documented in this file.

The project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v3.1.0] - 2026-10-07

> [!NOTE]
> **Typography & UX Polish Release**: Focuses on typographic clarity, clutter reduction, and layout refinements across both standalone and Pi-hole v6 Lua templates.

### 🎨 UX & Visual Improvements
- **Clean Typography (Symbol Clutter Elimination)**:
  - Removed unicode symbol prefixes (`✓`, `✕`, `!`, `●`) from status labels, badges, interface states, hop latencies, and tooltips.
  - Status indicators now rely purely on semantic AdminLTE badge styling and clean textual status (`Healthy`, `Degraded`, `Online`, `Down`, `OK`, `FAIL`).
- **Multiline Client Network Links**:
  - Split client interfaces into dedicated lines (`eth0: Online` / `wlan0: Online`) instead of pipe-delimited text.
- **Verbal Consistency & Footer Attribution**:
  - Harmonized navigation and header titles across Pi-hole v6 AdminLTE integration.
  - Added open-source footer link directly to the GitHub repository.
- **Cache-Busting Update**:
  - Bumped frontend script version parameter to `v=3.1` across HTML templates.

---

## [v3.0.0] - 2026-10-06

> [!IMPORTANT]
> **Major Architecture & Layout Redesign**: Introduces a single-pass consolidated JSON telemetry engine (`status.json`), 4-tier dashboard layout, native Pi-hole v6 Lua integration (`health.lp`), Recent Events & Outages logging, and POSIX `flock` concurrency locking.

### 🚀 Highlights & New Features

- **Structured 4-Tier Dashboard Layout**:
  - **Row 1**: Live DNS Chain Diagnostics (`CLIENT` ➔ `Pi-hole` ➔ `dnscrypt-proxy` ➔ `Cloudflare`).
  - **Row 2**: Live Hop Latency Benchmarks (Pi-hole, dnscrypt-proxy, Cloudflare upstream) & Network Interfaces (eth0, wlan0, packet loss).
  - **Row 3**: Historical Uptime (Last 72 Hours) displayed in chronological order (*2 Days Ago*, *Yesterday*, *Today*) with SLA percentage.
  - **Row 4**: Recent Events & Outages Log detailing timestamped outages and interface events.

- **Single-Pass Consolidated Telemetry Backend (`status.json`)**:
  - Replaced fragmented multi-pass file parsing with a consolidated Python telemetry aggregator.
  - Computes SLA percentage, 72h hourly status matrix, component node states, active interface telemetry, and recent incidents into a single structured payload.
  - Front-end fetches `status.json` asynchronously every 30 seconds with relative freshness tickers ("Updated: just now", "Updated: 3m ago", with automatic "Stale" alerts).

- **POSIX `flock` Concurrency Protection**:
  - Integrated non-blocking file locking (`/dev/shm/internet_health_check.lock`) to prevent overlapping executions when cron probes take longer than expected.

- **Native Pi-hole v6 Lua Template (`templates/health.lp`)**:
  - Dedicated Lua server page for native embedding directly inside Pi-hole v6's web server at `/var/www/html/admin/health.lp`.

- **Expanded Automated Test Suite**:
  - Expanded test coverage from 20 to 26 assertions (`tests/test_internet_health_check.sh`), verifying consolidated JSON generation, lock contention, RAM fallbacks, and multi-hop resolution.

---

## [v2.0.0] - 2026-07-26

> [!IMPORTANT]
> **Major Version 2.0 Release**: This release introduced native **Pi-hole v6 AdminLTE** integration, automatic dark/light theme switching, responsive mobile layouts, 72-hour historical SLA tracking, and multi-interface failover awareness.

### 🚀 Highlights & Features

- **Native Pi-hole v6 AdminLTE Dashboard Integration**:
  - Full-screen dashboard styled after Pi-hole v6 using native `adminlte.min.js` and CSS theme variables.
  - Automatic **Dark / Light Mode** switching following system `prefers-color-scheme`, perfectly matching Pi-hole admin behavior.
  - Hamburger sidebar toggle for mobile devices.

- **Interactive 72-Hour Historical SLA Grid**:
  - Chronological 3-row grid with 24-hour hour-block resolution.
  - Dynamic **SLA: XX.XX%** badge with color-coded status thresholds:
    - Green (`label-success`): SLA ≥ 99.00%
    - Orange (`label-warning`): SLA 95.00% – 98.99%
    - Red (`label-danger`): SLA < 95.00%

- **Floating Root-Cause Diagnostics Tooltips**:
  - Interactive hover tooltips rendering a graphical mini DNS chain flow:
    `Client -> Pi-hole -> dnscrypt-proxy -> Cloudflare (DoH)`
  - Pinpoints exact component failure (e.g. `Pi-hole (FAIL)` vs `Cloudflare (FAIL)`).

- **Smart Multi-Interface & Maintenance Window Tolerance**:
  - Distinguishes total WAN outages (`DANGER`) vs single-interface failover / DNS forwarding glitches (`WARNING`).
  - Ignores single-interface `wlan0` maintenance drops when wired `eth0` is healthy and passing traffic.

---

## [v1.0.0] - 2026-07-26

> [!NOTE]
> **Initial Stable Core Release**: Covered baseline monitoring scripts, zero-disk-wear RAM logging, state-change logging, and CLI diagnostic options.

### ⚡ Features & Core Engine

- **Multi-Interface Ping & DNS Chain Monitoring**:
  - Dual-interface support (`eth0`, `wlan0`).
  - Multi-hop DNS resolution checks: local Pi-hole (`:53`), local dnscrypt-proxy (`:5053`), and upstream Cloudflare DoH (`1.1.1.3:53`).
- **Zero-Disk-Wear RAM Logging & Disk Protection**:
  - Fast RAM state logging in `/dev/shm/internet_health_history.txt`.
  - Disk logging restricted to state changes and outages to protect Raspberry Pi SD cards.
  - Automatic log rotation (2 MB max size, up to 7 archive rotations).
- **CLI Options & Diagnostic Suite**:
  - CLI flags: `--log-file`, `--reduce-disk-wear`, `--html-file`, `--upstream-dns`, and `--interfaces`.

---

## Release Summary

| Release Tag | Highlights |
|---|---|
| **`v1.0.0`** | Baseline Bash engine, RAM logging, disk wear reduction, CLI flags |
| **`v2.0.0`** | Pi-hole v6 AdminLTE UI, Auto Dark Mode, 72h SLA Grid, Floating Tooltips, Mobile Grid |
| **`v3.0.0`** | 4-Tier Dashboard Layout, Single-Pass `status.json`, Outages Log, `flock` Locking, Lua Template |
| **`v3.1.0`** | Clean Typography, Symbol Clutter Removal, Multiline Interface Links, Cache-Busting v3.1 |
