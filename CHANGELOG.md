# Changelog & Release Notes

All notable changes to the **Internet Health Check** project are documented in this file.

The project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [v2.0.0] - 2026-07-26

> [!IMPORTANT]
> **Major Version 2.0 Release**: This release introduces native **Pi-hole v6 AdminLTE** integration, automatic dark/light theme switching, responsive mobile layouts, 72-hour historical SLA tracking, and multi-interface failover awareness.

### 🚀 Highlights & New Features

- **Native Pi-hole v6 AdminLTE Dashboard Integration**:
  - Full-screen dashboard styled after Pi-hole v6 using native `adminlte.min.js` and CSS theme variables.
  - Automatic **Dark / Light Mode** switching following system `prefers-color-scheme`, perfectly matching Pi-hole admin behavior.
  - Hamburger sidebar toggle for mobile devices.

- **Interactive 72-Hour Historical SLA Grid**:
  - Chronological 3-row grid ("2 Days Ago", "Yesterday", "Today") with 24-hour hour-block resolution.
  - Dynamic **● SLA: XX.XX%** badge with color-coded status thresholds:
    - 🟢 **Green (`label-success`)**: SLA ≥ 99.00%
    - 🟠 **Orange (`label-warning`)**: SLA 95.00% – 98.99%
    - 🔴 **Red (`label-danger`)**: SLA < 95.00%
  - Future hours today marked as gray `Pending` slots.

- **Floating Root-Cause Diagnostics Tooltips**:
  - Interactive hover tooltips rendering a graphical mini DNS chain flow:
    `Client -> Pi-hole -> dnscrypt-proxy -> Cloudflare (DoH)`
  - Pinpoints exact component failure (e.g. `Pi-hole (FAIL)` vs `Cloudflare (FAIL)`).
  - Displays affected network interfaces (`eth0`, `wlan0`) and first incident timestamp per hour.

- **Smart Multi-Interface & Maintenance Window Tolerance**:
  - Distinguishes total WAN outages (🔴 **`DANGER`**) vs single-interface failover / DNS forwarding glitches (🟠 **`WARNING`**).
  - Ignores single-interface `wlan0` maintenance drops (such as planned 30-minute weekly router reboots) when wired `eth0` is healthy and passing traffic, avoiding false SLA penalties.

- **Mobile Responsiveness**:
  - Responsive DNS chain diagram wrapping into a 2×2 grid on portrait screens (< 767px).
  - Responsive 3-label time header (`00:00 · 12:00 · 23:59`) to prevent label cutoff on small viewports.

- **Content Security Policy (CSP) Compliance**:
  - Clean separation of HTML and JavaScript into a standalone `app.js` with cache-busting `?v=1.6`.

---

## [v1.0.0] - 2026-07-26 (Tag: `76c0311`)

> [!NOTE]
> **Initial Stable Core Release**: Covers baseline monitoring scripts, zero-disk-wear RAM logging, state-change logging, and CLI diagnostic options up to commit `76c0311`.

### ⚡ Features & Core Engine

- **Multi-Interface Ping & DNS Chain Monitoring**:
  - Dual-interface support (`eth0`, `wlan0`).
  - Multi-hop DNS resolution checks: local Pi-hole (`:53`), local dnscrypt-proxy (`:5053`), and upstream Cloudflare DoH (`1.1.1.3:53`).
  - Automatic `dnscrypt-proxy` upstream DNS server auto-detection.

- **Zero-Disk-Wear RAM Logging & Disk Protection**:
  - Fast RAM state logging in `/dev/shm/internet_health_history.txt`.
  - Disk logging restricted to state changes and outages to protect Raspberry Pi SD cards.
  - Automatic log rotation (2 MB max size, up to 7 archive rotations).

- **CLI Options & Diagnostic Suite**:
  - CLI flags: `--log-file`, `--reduce-disk-wear`, `--html-file`, `--upstream-dns`, and `--interface`.
  - Comprehensive unit testing suite (`tests/test_internet_health_check.sh`).

---

## Commit Comparison Summary

| Release Tag | Target Commit | Highlights |
|---|---|---|
| **`v1.0.0`** | [`76c0311`](file:///workspace/internet_health_check.sh) | Baseline Bash engine, RAM logging, disk wear reduction, CLI flags |
| **`v2.0.0`** | [`4955034`](file:///workspace/internet_health_check.sh) | Pi-hole v6 AdminLTE UI, Auto Dark Mode, 72h SLA Grid, Floating Tooltips, Mobile 2x2 Grid |
