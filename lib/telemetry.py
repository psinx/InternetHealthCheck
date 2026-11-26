#!/usr/bin/env python3
"""
lib/telemetry.py - Telemetry aggregator, recovery state machine, and status.json builder.

Reads current live probe results + metadata JSON from stdin, merges chronological
RAM state history and optional disk logs, and writes consolidated status.json.
"""

import argparse
import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional, Set, Tuple

DAY_LABELS = ["Today", "Yesterday", "2 Days Ago"]
IFACE_BRACKET_RE = re.compile(r"\[([a-zA-Z0-9._-]+)\]")


def is_wireless_iface(iface: str) -> bool:
    """Return True if interface name is conventionally wireless."""
    return iface.startswith(("wlan", "wlp", "wlo", "wlx", "wifi", "ath"))


def parse_bool(val: Any, default: Optional[bool] = True) -> Optional[bool]:
    if isinstance(val, bool):
        return val
    if val is None:
        return default
    s = str(val).strip().lower()
    if s in ("true", "1", "ok", "yes"):
        return True
    if s in ("false", "0", "fail", "down", "no"):
        return False
    if s in ("null", "none", "skipped", ""):
        return None
    return default


def parse_float(val: Any, default: float = 0.0) -> float:
    try:
        return float(str(val).strip().rstrip("%ms"))
    except (ValueError, TypeError):
        return default


def parse_int(val: Any, default: int = 0) -> int:
    try:
        return int(float(str(val).strip().rstrip("ms")))
    except (ValueError, TypeError):
        return default


def compute_system_status(interfaces: Dict[str, Dict[str, Any]]) -> str:
    """Compute overall status strictly from configured (non-unused) interfaces."""
    configured = [
        data for data in interfaces.values()
        if data.get("state") != "unused" and data.get("admin_up", True) is not False
    ]
    if not configured:
        return "Outage"

    all_down = all(data.get("connectivity") == "DOWN" for data in configured)
    if all_down:
        return "Outage"

    any_issue = any(
        data.get("connectivity") == "DOWN"
        or data.get("dns_ok") is False
        or data.get("degraded") is True
        for data in configured
    )
    if any_issue:
        return "Degraded"

    return "Healthy"


class InterfaceHourState:
    """Per-interface chronological state within a single 1-hour bucket."""

    def __init__(self) -> None:
        self.had_danger: bool = False
        self.had_warning: bool = False
        self.first_issue_ts: str = ""
        self.first_issue_detail: str = ""
        self.last_ok: bool = True
        self.last_ts: float = -1.0
        self.recovered_at: str = ""
        self.ok_samples: int = 0
        self.total_samples: int = 0
        self.latched_client: bool = True
        self.latched_pi: Optional[bool] = None
        self.latched_dns: Optional[bool] = None
        self.latched_cf: Optional[bool] = None
        self.slow_hops: Set[str] = set()

    def record_sample(
        self,
        ts: float,
        dt: datetime,
        conn: str,
        dns: str,
        pi_ok: Optional[bool],
        dns_ok: Optional[bool],
        cf_ok: Optional[bool],
        pi_lat: int,
        dns_lat: int,
        cf_lat: int,
        loss: float,
        client_ok: bool,
        thresholds: Dict[str, float],
        skip_dnscrypt: bool,
        count_sample: bool = True,
        slow_hints: Optional[Set[str]] = None,
        detail_override: str = "",
    ) -> None:
        if conn == "UNUSED":
            return

        pi_warn = thresholds.get("pihole_ms", 150)
        dc_warn = thresholds.get("dnscrypt_ms", 200)
        up_warn = thresholds.get("upstream_ms", 200)
        loss_warn = thresholds.get("loss_pct", 5)

        slow_now: Set[str] = set(slow_hints) if slow_hints else set()
        if pi_ok is True and pi_lat >= pi_warn:
            slow_now.add("pihole")
        if not skip_dnscrypt and dns_ok is True and dns_lat >= dc_warn:
            slow_now.add("dnscrypt")
        if cf_ok is True and cf_lat >= up_warn:
            slow_now.add("cloudflare")

        is_degraded = bool(slow_now) or (conn == "OK" and loss >= loss_warn)
        is_failure = (conn == "DOWN") or (dns == "false") or (not client_ok)
        sample_ok = (not is_failure) and (not is_degraded)

        if count_sample:
            self.total_samples += 1
            if sample_ok:
                self.ok_samples += 1

        if ts >= self.last_ts:
            self.last_ts = ts
            if not sample_ok:
                self.last_ok = False
                self.recovered_at = ""
            else:
                if (self.had_danger or self.had_warning) and not self.last_ok:
                    self.recovered_at = dt.strftime("%H:%M:%S")
                self.last_ok = True

        if is_failure:
            self.had_danger = True
            if not self.first_issue_ts:
                self.first_issue_ts = dt.strftime("%Y-%m-%d %H:%M:%S")
                if detail_override:
                    self.first_issue_detail = detail_override
                elif not client_ok:
                    self.first_issue_detail = "Client link / IP unavailable"
                elif conn == "DOWN":
                    self.first_issue_detail = f"Connectivity outage ({loss:.0f}% loss)"
                else:
                    self.first_issue_detail = "DNS resolution failed"

            if not client_ok:
                self.latched_client = False
            else:
                if pi_ok is False:
                    self.latched_pi = False
                elif pi_ok is True and self.latched_pi is None:
                    self.latched_pi = True

                if not skip_dnscrypt:
                    if dns_ok is False:
                        self.latched_dns = False
                    elif dns_ok is True and self.latched_dns is None:
                        self.latched_dns = True

                if cf_ok is False or conn == "DOWN":
                    self.latched_cf = False
                elif cf_ok is True and self.latched_cf is None:
                    self.latched_cf = True

        elif is_degraded:
            self.had_warning = True
            self.slow_hops.update(slow_now)
            if self.latched_pi is None and pi_ok is not None:
                self.latched_pi = pi_ok
            if not skip_dnscrypt and self.latched_dns is None and dns_ok is not None:
                self.latched_dns = dns_ok
            if self.latched_cf is None and cf_ok is not None:
                self.latched_cf = cf_ok

            if not self.first_issue_ts:
                if detail_override:
                    deg_txt = detail_override
                elif "cloudflare" in slow_now and cf_lat > 0:
                    deg_txt = f"{cf_lat}ms Upstream"
                elif "dnscrypt" in slow_now and dns_lat > 0:
                    deg_txt = f"{dns_lat}ms dnscrypt"
                elif "pihole" in slow_now and pi_lat > 0:
                    deg_txt = f"{pi_lat}ms DNS"
                else:
                    deg_txt = f"{loss:.0f}% Loss"
                self.first_issue_ts = f"{dt.strftime('%Y-%m-%d %H:%M:%S')} ({deg_txt})"
                self.first_issue_detail = deg_txt
        else:
            if self.latched_pi is None and pi_ok is True:
                self.latched_pi = True
            if not skip_dnscrypt and self.latched_dns is None and dns_ok is True:
                self.latched_dns = True
            if self.latched_cf is None and cf_ok is True:
                self.latched_cf = True


def load_ram_entries(ram_file: str) -> List[Dict[str, Any]]:
    """Parse RAM CSV state database and sort chronologically."""
    entries: List[Dict[str, Any]] = []
    if not ram_file or not os.path.exists(ram_file):
        return entries

    try:
        with open(ram_file, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError as exc:
        print(f"[telemetry] Warning: failed to read RAM file {ram_file}: {exc}", file=sys.stderr)
        return entries

    for idx, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped:
            continue
        parts = stripped.split(",")
        if len(parts) < 4:
            continue
        try:
            ts = float(parts[0])
            dt = datetime.fromtimestamp(ts)
        except (ValueError, OSError):
            print(f"[telemetry] Warning: invalid timestamp in {ram_file}:{idx}", file=sys.stderr)
            continue

        iface = parts[1].strip() or "eth0"
        conn = parts[2].strip().upper()
        dns = parts[3].strip().lower()
        state = parts[12].strip().lower() if len(parts) > 12 else ""
        if state == "unused" or conn == "UNUSED":
            continue

        pi_ok = parse_bool(parts[4], True) if len(parts) > 4 else True
        dns_ok = parse_bool(parts[5], True) if len(parts) > 5 else True
        cf_ok = parse_bool(parts[6], (conn == "OK" and dns == "true")) if len(parts) > 6 else (conn == "OK" and dns == "true")
        pi_lat = parse_int(parts[7], 0) if len(parts) > 7 else 0
        dns_lat = parse_int(parts[8], 0) if len(parts) > 8 else 0
        cf_lat = parse_int(parts[9], 0) if len(parts) > 9 else 0
        loss = parse_float(parts[10], 0.0) if len(parts) > 10 else 0.0
        client_ok_raw = parse_bool(parts[11], None) if len(parts) > 11 else None

        if client_ok_raw is not None:
            client_ok = client_ok_raw
        else:
            # In extended runs without explicit client_ok, conn=DOWN + null DNS nodes indicates L1/L2 drop
            client_ok = not (conn == "DOWN" and pi_ok is None and cf_ok is None)

        entries.append({
            "source": "ram",
            "ts": ts,
            "dt": dt,
            "iface": iface,
            "conn": conn,
            "dns": dns,
            "pi_ok": pi_ok,
            "dns_ok": dns_ok,
            "cf_ok": cf_ok,
            "pi_lat": pi_lat,
            "dns_lat": dns_lat,
            "cf_lat": cf_lat,
            "loss": loss,
            "client_ok": client_ok,
        })

    entries.sort(key=lambda e: e["ts"])
    return entries


def resolve_candidate_logs(explicit_log_file: str) -> List[str]:
    """Return list of disk log files to read hermetically."""
    if explicit_log_file:
        return [explicit_log_file] if os.path.exists(explicit_log_file) else []

    if os.environ.get("TELEMETRY_NO_DEFAULT_LOGS") == "1":
        return []

    candidates: List[str] = []
    script_dir = os.environ.get("SCRIPT_DIR", "")
    if script_dir:
        default_log = os.path.join(script_dir, "logs", "internet_health.log")
        if os.path.exists(default_log):
            candidates.append(default_log)
    if os.path.exists("/var/log/internet_health.log") and "/var/log/internet_health.log" not in candidates:
        candidates.append("/var/log/internet_health.log")
    return candidates


def load_disk_events(log_paths: List[str]) -> List[Dict[str, Any]]:
    """Parse chronological log entries across any interface name."""
    events: List[Dict[str, Any]] = []
    for path in log_paths:
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                lines = f.readlines()
        except OSError as exc:
            print(f"[telemetry] Warning: failed to read log file {path}: {exc}", file=sys.stderr)
            continue

        for line in lines:
            if "[INTERNET-HEALTH-CHECK]" not in line:
                continue
            parts = line.strip().split(None, 3)
            if len(parts) < 4:
                continue
            time_str = f"{parts[0]} {parts[1]}"
            try:
                dt = datetime.strptime(time_str, "%Y-%m-%d %H:%M:%S")
                ts = dt.timestamp()
            except ValueError:
                continue

            msg = parts[3]
            ifaces = [m for m in IFACE_BRACKET_RE.findall(msg) if m != "INTERNET-HEALTH-CHECK"]
            iface = ifaces[0] if ifaces else "eth0"

            kind = "info"
            pi_ok: Optional[bool] = True
            dns_ok: Optional[bool] = True
            cf_ok: Optional[bool] = True
            client_ok = True
            slow_hints: Set[str] = set()
            detail = ""

            if "Fail during Ping" in msg or "CONNECTIVITY OUTAGE" in msg:
                kind = "down"
                cf_ok = False
                detail = "ICMP Ping failed"
            elif "Fail via Pi-hole" in msg:
                kind = "dns_fail"
                pi_ok = False
                detail = "Pi-hole probe failed"
            elif "Fail via dnscrypt" in msg:
                kind = "dns_fail"
                dns_ok = False
                detail = "dnscrypt-proxy probe failed"
            elif "Fail via Cloudflare" in msg or "Fail via Upstream" in msg:
                kind = "dns_fail"
                cf_ok = False
                detail = "Upstream DNS failed"
            elif "Physical Link" in msg or "No IP" in msg or "DISCONNECTED" in msg:
                kind = "down"
                client_ok = False
                pi_ok = None
                dns_ok = None
                cf_ok = None
                detail = "Client link / IP unavailable"
            elif re.search(r"\] DOWN\b", line):
                kind = "down"
                detail = "Interface / connectivity DOWN"
            elif "Warning:" in msg or re.search(r"\] DEGRADED\b", line):
                kind = "degraded"
                if "Pi-hole" in msg:
                    slow_hints.add("pihole")
                if "dnscrypt" in msg:
                    slow_hints.add("dnscrypt")
                if "Upstream" in msg or "Cloudflare" in msg:
                    slow_hints.add("cloudflare")
                detail = msg.split("Warning: ", 1)[1].strip() if "Warning: " in msg else "Degraded performance"
            elif re.search(r"\] OK\b", line):
                kind = "ok"
            else:
                continue

            events.append({
                "source": "disk",
                "ts": ts,
                "dt": dt,
                "time_str": time_str,
                "iface": iface,
                "kind": kind,
                "pi_ok": pi_ok,
                "dns_ok": dns_ok,
                "cf_ok": cf_ok,
                "client_ok": client_ok,
                "slow_hints": slow_hints,
                "detail": detail,
                "raw": line.strip(),
            })

    events.sort(key=lambda e: e["ts"])
    return events


def build_telemetry_payload(
    live_data: Dict[str, Any],
    ram_file: str,
    log_file: str,
    now_dt: Optional[datetime] = None,
) -> Dict[str, Any]:
    """Build consolidated status.json payload from live check, RAM, and disk history."""
    if now_dt is None:
        now_dt = datetime.now()
    today_date = now_dt.date()
    now_ts = now_dt.timestamp()
    max_age_seconds = 72 * 3600

    metadata = live_data.get("metadata", {})
    interfaces = live_data.get("interfaces", {})
    skip_dnscrypt = bool(metadata.get("skip_dnscrypt", False))
    thresholds = metadata.get("thresholds", {
        "pihole_ms": 150,
        "dnscrypt_ms": 200,
        "upstream_ms": 200,
        "loss_pct": 5,
    })

    system_status = compute_system_status(interfaces)

    # Per-(day_label, hour_idx) dictionary of iface -> InterfaceHourState
    hour_ifaces: Dict[str, List[Dict[str, InterfaceHourState]]] = {
        label: [{} for _ in range(24)] for label in DAY_LABELS
    }

    ram_entries = load_ram_entries(ram_file)
    log_paths = resolve_candidate_logs(log_file)
    disk_events = load_disk_events(log_paths)

    # Track timestamps covered by RAM per (day, hour, iface) so disk log fills gaps
    # (e.g. post-reboot history) without overriding richer RAM samples from the same tick.
    ram_ts_by_bucket: Dict[Tuple[str, int, str], List[float]] = {}

    for entry in ram_entries:
        dt = entry["dt"]
        days_diff = (today_date - dt.date()).days
        if not (0 <= days_diff < 3):
            continue
        day_label = DAY_LABELS[days_diff]
        hour_idx = dt.hour
        iface = entry["iface"]
        bucket = hour_ifaces[day_label][hour_idx]
        if iface not in bucket:
            bucket[iface] = InterfaceHourState()

        bucket[iface].record_sample(
            ts=entry["ts"],
            dt=dt,
            conn=entry["conn"],
            dns=entry["dns"],
            pi_ok=entry["pi_ok"],
            dns_ok=entry["dns_ok"],
            cf_ok=entry["cf_ok"],
            pi_lat=entry["pi_lat"],
            dns_lat=entry["dns_lat"],
            cf_lat=entry["cf_lat"],
            loss=entry["loss"],
            client_ok=entry["client_ok"],
            thresholds=thresholds,
            skip_dnscrypt=skip_dnscrypt,
            count_sample=True,
        )
        ram_ts_by_bucket.setdefault((day_label, hour_idx, iface), []).append(entry["ts"])

    for ev in disk_events:
        dt = ev["dt"]
        days_diff = (today_date - dt.date()).days
        if not (0 <= days_diff < 3):
            continue
        day_label = DAY_LABELS[days_diff]
        hour_idx = dt.hour
        iface = ev["iface"]
        bucket = hour_ifaces[day_label][hour_idx]
        if iface not in bucket:
            bucket[iface] = InterfaceHourState()

        has_ram_in_hour = bool(ram_ts_by_bucket.get((day_label, hour_idx, iface)))
        near_ram = any(
            abs(ev["ts"] - rts) <= 30.0
            for rts in ram_ts_by_bucket.get((day_label, hour_idx, iface), [])
        )
        # Skip plain OK transitions from disk if RAM already captured that window
        if ev["kind"] == "ok" and near_ram:
            continue

        if ev["kind"] == "ok":
            conn, dns = "OK", "true"
        elif ev["kind"] == "degraded":
            conn, dns = "OK", "true"
        elif ev["kind"] == "dns_fail":
            conn, dns = "OK", "false"
        else:
            conn, dns = "DOWN", "false"

        bucket[iface].record_sample(
            ts=ev["ts"],
            dt=dt,
            conn=conn,
            dns=dns,
            pi_ok=ev["pi_ok"],
            dns_ok=ev["dns_ok"],
            cf_ok=ev["cf_ok"],
            pi_lat=int(thresholds.get("pihole_ms", 150)) if "pihole" in ev["slow_hints"] else 0,
            dns_lat=int(thresholds.get("dnscrypt_ms", 200)) if "dnscrypt" in ev["slow_hints"] else 0,
            cf_lat=int(thresholds.get("upstream_ms", 200)) if "cloudflare" in ev["slow_hints"] else 0,
            loss=float(thresholds.get("loss_pct", 5)) if ev["kind"] == "degraded" and not ev["slow_hints"] else 0.0,
            client_ok=ev["client_ok"],
            thresholds=thresholds,
            skip_dnscrypt=skip_dnscrypt,
            count_sample=not has_ram_in_hour,
            slow_hints=ev["slow_hints"],
            detail_override=ev["detail"],
        )

    # Aggregate 72-hour grid & compute Apdex SLA (unmonitored hours remain INACTIVE)
    active_hours = 0
    healthy_hours = 0
    warning_hours = 0
    history_res: List[Dict[str, Any]] = []

    for days_ago, day_label in [(2, "2 Days Ago"), (1, "Yesterday"), (0, "Today")]:
        target_dt = now_dt - timedelta(days=days_ago)
        date_str = target_dt.strftime("%-d %b")
        day_cells: List[Dict[str, Any]] = []

        for h in range(24):
            bucket = hour_ifaces[day_label][h]
            if not bucket or (days_ago == 0 and h > now_dt.hour):
                day_cells.append({
                    "hour": h,
                    "status": "INACTIVE",
                    "uptime": 0,
                    "has_recovered": False,
                    "recovered_at": "",
                    "earliest_issue": "",
                    "iface": "",
                    "tested_ifaces": "",
                    "client_ok": True,
                    "pihole": True,
                    "dnscrypt": None if skip_dnscrypt else True,
                    "cloudflare": True,
                    "slow_hops": [],
                })
                continue

            affected = [iface for iface, st in bucket.items() if st.had_danger or st.had_warning]
            tested = sorted(bucket.keys())

            if not affected:
                st_str = "OK"
            else:
                non_wireless_bucket = [iface for iface in bucket if not is_wireless_iface(iface)]
                non_wireless_host = [
                    name for name, d in interfaces.items()
                    if not is_wireless_iface(name) and d.get("state") != "unused" and d.get("admin_up", True) is not False
                ]
                has_wired_host = bool(non_wireless_bucket) or bool(non_wireless_host)
                primary_danger = any(bucket[iface].had_danger for iface in non_wireless_bucket)
                if primary_danger or (not has_wired_host and all(bucket[iface].had_danger for iface in bucket)):
                    st_str = "DANGER"
                else:
                    st_str = "WARNING"

            active_hours += 1
            if st_str == "OK":
                healthy_hours += 1
            elif st_str == "WARNING":
                warning_hours += 1

            has_recovered = bool(
                st_str in ("DANGER", "WARNING")
                and affected
                and all(bucket[iface].last_ok for iface in affected)
            )
            recovered_at = ""
            if has_recovered:
                rec_times = [bucket[iface].recovered_at for iface in affected if bucket[iface].recovered_at]
                recovered_at = max(rec_times) if rec_times else ""

            total_s = sum(st.total_samples for st in bucket.values())
            ok_s = sum(st.ok_samples for st in bucket.values())
            if total_s > 0:
                uptime_pct = round(ok_s / total_s * 100)
            else:
                uptime_pct = 100 if st_str == "OK" else 0

            # Root-cause attribution across affected interfaces
            if st_str == "OK":
                client_ok = True
                pi_node: Optional[bool] = True
                dns_node: Optional[bool] = None if skip_dnscrypt else True
                cf_node: Optional[bool] = True
                slow_hops: List[str] = []
                earliest_issue = ""
            else:
                client_ok = not any(not bucket[i].latched_client for i in affected)
                pi_vals = [bucket[i].latched_pi for i in affected if bucket[i].latched_pi is not None]
                dns_vals = [bucket[i].latched_dns for i in affected if bucket[i].latched_dns is not None]
                cf_vals = [bucket[i].latched_cf for i in affected if bucket[i].latched_cf is not None]

                pi_node = False if False in pi_vals else (True if True in pi_vals else None)
                if skip_dnscrypt:
                    dns_node = None
                else:
                    dns_node = False if False in dns_vals else (True if True in dns_vals else None)
                cf_node = False if False in cf_vals else (True if True in cf_vals else None)

                slow_set: Set[str] = set()
                for i in affected:
                    slow_set.update(bucket[i].slow_hops)
                slow_hops = sorted(slow_set)

                issue_times = [bucket[i].first_issue_ts for i in affected if bucket[i].first_issue_ts]
                earliest_issue = min(issue_times) if issue_times else ""

            day_cells.append({
                "hour": h,
                "status": st_str,
                "uptime": uptime_pct,
                "has_recovered": has_recovered,
                "recovered_at": recovered_at,
                "earliest_issue": earliest_issue,
                "iface": ", ".join(sorted(affected)),
                "tested_ifaces": ", ".join(tested),
                "client_ok": client_ok,
                "pihole": pi_node,
                "dnscrypt": dns_node,
                "cloudflare": cf_node,
                "slow_hops": slow_hops,
            })

        history_res.append({"label": day_label, "date": date_str, "hours": day_cells})

    sla_pct = round(((healthy_hours + 0.5 * warning_hours) / active_hours * 100.0), 2) if active_hours > 0 else 100.0

    # Extract & deduplicate recent incidents (30s window per iface + category)
    incidents: List[Dict[str, str]] = []
    seen_recent: List[Tuple[float, str, str]] = []

    def is_duplicate(ts: float, iface: str, category: str) -> bool:
        for prev_ts, prev_iface, prev_cat in seen_recent:
            if prev_iface == iface and prev_cat == category and abs(ts - prev_ts) <= 30.0:
                return True
        return False

    # Prefer RAM incidents (have exact latencies), supplemented by disk log events
    raw_incidents: List[Dict[str, Any]] = []
    for entry in ram_entries:
        ts = entry["ts"]
        if (now_ts - ts) > max_age_seconds:
            continue
        pi_lat = entry["pi_lat"]
        dns_lat = entry["dns_lat"]
        cf_lat = entry["cf_lat"]
        loss = entry["loss"]
        is_deg = (
            (entry["pi_ok"] is True and pi_lat >= thresholds.get("pihole_ms", 150))
            or (not skip_dnscrypt and entry["dns_ok"] is True and dns_lat >= thresholds.get("dnscrypt_ms", 200))
            or (entry["cf_ok"] is True and cf_lat >= thresholds.get("upstream_ms", 200))
            or (entry["conn"] == "OK" and loss >= thresholds.get("loss_pct", 5))
        )
        if entry["conn"] == "DOWN" or entry["dns"] == "false" or is_deg:
            iface = entry["iface"]
            is_outage = (entry["conn"] == "DOWN" or entry["dns"] == "false") and not is_wireless_iface(iface)
            if entry["dns"] == "false" and entry["conn"] == "OK":
                is_outage = True
            if is_deg and entry["conn"] == "OK" and entry["dns"] == "true":
                badge = "Warning"
                if pi_lat >= thresholds.get("pihole_ms", 150):
                    deg_txt = f"{pi_lat}ms Pi-hole"
                elif not skip_dnscrypt and dns_lat >= thresholds.get("dnscrypt_ms", 200):
                    deg_txt = f"{dns_lat}ms dnscrypt"
                elif cf_lat >= thresholds.get("upstream_ms", 200):
                    deg_txt = f"{cf_lat}ms Upstream"
                else:
                    deg_txt = f"{loss:.0f}% Packet Loss"
                desc = f"Degraded performance ({deg_txt})"
                cat = "warning"
            elif is_outage:
                badge = "Outage"
                if not entry["client_ok"]:
                    desc = f"Client link / IP unavailable ({iface})"
                elif entry["conn"] == "DOWN":
                    desc = "DOWN - Connectivity outage detected"
                else:
                    desc = "DNS resolution failure detected"
                cat = "outage"
            else:
                badge = "Warning"
                desc = f"Interface link down ({iface})"
                cat = "outage"
            raw_incidents.append({
                "ts": ts,
                "iface": iface,
                "cat": cat,
                "type": "outage" if badge == "Outage" else "warning",
                "badge": badge,
                "timestamp": f"{entry['dt'].strftime('%Y-%m-%d %H:%M:%S')} ({iface})",
                "description": desc,
                "duration": "",
            })

    for ev in disk_events:
        ts = ev["ts"]
        if (now_ts - ts) > max_age_seconds or ev["kind"] not in ("down", "dns_fail", "degraded"):
            continue
        iface = ev["iface"]
        if ev["kind"] == "degraded":
            badge = "Warning"
            desc = f"Degraded performance - {ev['detail']}"
            cat = "warning"
        else:
            is_outage = (not is_wireless_iface(iface)) or ev["kind"] == "dns_fail"
            badge = "Outage" if is_outage else "Warning"
            desc = ev["detail"] or ("DOWN - Connectivity outage detected" if is_outage else f"Interface link down ({iface})")
            cat = "outage"
        raw_incidents.append({
            "ts": ts,
            "iface": iface,
            "cat": cat,
            "type": "outage" if badge == "Outage" else "warning",
            "badge": badge,
            "timestamp": f"{ev['time_str']} ({iface})",
            "description": desc,
            "duration": "",
        })

    # Reverse chronological, deduplicated, cap at 10
    raw_incidents.sort(key=lambda r: r["ts"], reverse=True)
    for item in raw_incidents:
        if len(incidents) >= 10:
            break
        if not is_duplicate(item["ts"], item["iface"], item["cat"]):
            seen_recent.append((item["ts"], item["iface"], item["cat"]))
            incidents.append({
                "type": item["type"],
                "badge": item["badge"],
                "timestamp": item["timestamp"],
                "description": item["description"],
                "duration": item["duration"],
            })

    return {
        "timestamp": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "status": system_status,
        "sla_percentage": sla_pct,
        "metadata": metadata,
        "interfaces": interfaces,
        "history": history_res,
        "incidents": incidents,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Aggregate InternetHealthCheck telemetry into status.json")
    parser.add_argument("--out", required=True, help="Output status.json path")
    parser.add_argument("--ram-file", default="", help="RAM state history CSV path")
    parser.add_argument("--log-file", default="", help="Persistent disk log file path")
    args = parser.parse_args()

    raw_stdin = sys.stdin.read().strip()
    if not raw_stdin:
        print("[telemetry] Error: empty stdin payload", file=sys.stderr)
        return 1

    live_data = json.loads(raw_stdin)
    payload = build_telemetry_payload(live_data, args.ram_file, args.log_file)

    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
