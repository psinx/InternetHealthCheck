#!/usr/bin/env python3
"""Unit tests for lib/telemetry.py state machine, recovery attribution, and Apdex SLA."""

import os
import sys
from datetime import datetime, timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "lib"))
import telemetry  # noqa: E402


DEFAULT_META = {
    "host": "blackhole",
    "pihole_target": "127.0.0.1:53",
    "dnscrypt_target": "127.0.0.1:5053",
    "skip_dnscrypt": False,
    "upstream_ip": "1.1.1.3",
    "upstream_secondary_ip": "9.9.9.9",
    "upstream_protocol": "UDP/53",
    "cache_busted": False,
    "thresholds": {"pihole_ms": 150, "dnscrypt_ms": 200, "upstream_ms": 200, "loss_pct": 5},
}


def make_live(interfaces, meta=None):
    return {"metadata": meta or DEFAULT_META, "interfaces": interfaces}


def healthy_iface(admin_up=True, state="online"):
    return {
        "exists": True,
        "admin_up": admin_up,
        "carrier": 1 if admin_up else 0,
        "has_ip": admin_up,
        "ip": "192.168.1.2" if admin_up else "",
        "state": state,
        "connectivity": "OK" if admin_up else "UNUSED",
        "dns_ok": True,
        "degraded": False,
        "degradation_reason": "",
        "client_ok": True,
        "pihole": True if admin_up else None,
        "dnscrypt": True if admin_up else None,
        "cloudflare": True if admin_up else None,
        "upstream_secondary_ok": True if admin_up else None,
        "upstream_ip": "1.1.1.3",
        "upstream_secondary_ip": "9.9.9.9",
        "latency_ping": 10.0,
        "latency_pihole": 1,
        "latency_dnscrypt": 2,
        "latency_cloudflare": 14,
        "latency_upstream_secondary": 18,
        "packet_loss": 0.0,
    }


def test_unmonitored_hours_default_to_inactive(tmp_path):
    now_dt = datetime(2026, 11, 26, 15, 30, 0)
    ram = tmp_path / "ram.txt"
    ram.write_text(f"{int(now_dt.timestamp())},eth0,OK,true,true,true,true,1,2,14,0,true,online,10\n")

    payload = telemetry.build_telemetry_payload(
        make_live({"eth0": healthy_iface()}), str(ram), "", now_dt=now_dt
    )
    today = next(d for d in payload["history"] if d["label"] == "Today")
    yesterday = next(d for d in payload["history"] if d["label"] == "Yesterday")

    assert today["hours"][15]["status"] == "OK"
    assert today["hours"][10]["status"] == "INACTIVE"
    assert yesterday["hours"][12]["status"] == "INACTIVE"
    assert payload["sla_percentage"] == 100.0


def test_outage_then_recovery_latches_failed_hop_and_sets_recovered(tmp_path):
    now_dt = datetime(2026, 11, 26, 15, 45, 0)
    t_fail = int(datetime(2026, 11, 26, 15, 15, 5).timestamp())
    t_rec = int(datetime(2026, 11, 26, 15, 25, 30).timestamp())
    t_ok2 = int(datetime(2026, 11, 26, 15, 35, 0).timestamp())

    ram = tmp_path / "ram.txt"
    # Note: out-of-order input to also verify chronological sorting
    ram.write_text(
        f"{t_ok2},eth0,OK,true,true,true,true,2,3,15,0,true,online,10\n"
        f"{t_fail},eth0,OK,false,false,true,true,-1,2,15,0,true,down,10\n"
        f"{t_rec},eth0,OK,true,true,true,true,1,2,14,0,true,online,10\n"
    )

    payload = telemetry.build_telemetry_payload(
        make_live({"eth0": healthy_iface()}), str(ram), "", now_dt=now_dt
    )
    h15 = payload["history"][2]["hours"][15]
    assert h15["status"] == "DANGER"
    assert h15["has_recovered"] is True
    assert h15["recovered_at"] == "15:25:30"
    assert h15["pihole"] is False
    assert h15["dnscrypt"] is True
    assert h15["cloudflare"] is True
    assert h15["uptime"] == 67


def test_flapping_re_outage_resets_recovered(tmp_path):
    now_dt = datetime(2026, 11, 26, 15, 50, 0)
    t1 = int(datetime(2026, 11, 26, 15, 10, 0).timestamp())
    t2 = int(datetime(2026, 11, 26, 15, 20, 0).timestamp())
    t3 = int(datetime(2026, 11, 26, 15, 40, 0).timestamp())

    ram = tmp_path / "ram.txt"
    ram.write_text(
        f"{t1},eth0,OK,false,false,true,true,-1,2,15,0,true,down,10\n"
        f"{t2},eth0,OK,true,true,true,true,1,2,14,0,true,online,10\n"
        f"{t3},eth0,OK,false,true,false,true,1,-1,14,0,true,down,10\n"
    )

    payload = telemetry.build_telemetry_payload(
        make_live({"eth0": healthy_iface()}), str(ram), "", now_dt=now_dt
    )
    h15 = payload["history"][2]["hours"][15]
    assert h15["status"] == "DANGER"
    assert h15["has_recovered"] is False
    assert h15["recovered_at"] == ""
    assert h15["pihole"] is False
    assert h15["dnscrypt"] is False


def test_multi_interface_interleaving_does_not_falsely_recover(tmp_path):
    now_dt = datetime(2026, 11, 26, 15, 30, 0)
    t1 = int(datetime(2026, 11, 26, 15, 15, 0).timestamp())
    t2 = int(datetime(2026, 11, 26, 15, 15, 4).timestamp())

    ram = tmp_path / "ram.txt"
    ram.write_text(
        f"{t1},eth0,DOWN,false,null,null,null,-1,-1,-1,100,false,down,-1\n"
        f"{t2},wlan0,OK,true,true,true,true,3,4,18,0,true,online,12\n"
    )

    payload = telemetry.build_telemetry_payload(
        make_live({"eth0": healthy_iface(), "wlan0": healthy_iface()}), str(ram), "", now_dt=now_dt
    )
    h15 = payload["history"][2]["hours"][15]
    assert h15["status"] == "DANGER"
    assert h15["has_recovered"] is False
    assert h15["client_ok"] is False
    # Client L1/L2 drop must NOT blame Pi-hole or dnscrypt as FAIL
    assert h15["pihole"] is None
    assert h15["dnscrypt"] is None


def test_unused_interface_excluded_from_status_and_sla(tmp_path):
    now_dt = datetime(2026, 11, 26, 15, 30, 0)
    ram = tmp_path / "ram.txt"
    ram.write_text(f"{int(now_dt.timestamp())},eth0,OK,true,true,true,true,1,0,12,0,true,online,10\n")

    unused_wlan = healthy_iface(admin_up=False, state="unused")
    unused_wlan["connectivity"] = "UNUSED"

    payload = telemetry.build_telemetry_payload(
        make_live({"eth0": healthy_iface(), "wlan0": unused_wlan}), str(ram), "", now_dt=now_dt
    )
    assert payload["status"] == "Healthy"
    assert payload["sla_percentage"] == 100.0


def test_latency_degradation_populates_slow_hops_and_apdex(tmp_path):
    now_dt = datetime(2026, 11, 26, 15, 30, 0)
    t_h14 = int(datetime(2026, 11, 26, 14, 15, 0).timestamp())
    t_h15 = int(now_dt.timestamp())

    ram = tmp_path / "ram.txt"
    ram.write_text(
        f"{t_h14},eth0,OK,true,true,true,true,240,2,15,0,true,degraded,10\n"
        f"{t_h15},eth0,OK,true,true,true,true,2,2,15,0,true,online,10\n"
    )

    payload = telemetry.build_telemetry_payload(
        make_live({"eth0": healthy_iface()}), str(ram), "", now_dt=now_dt
    )
    h14 = payload["history"][2]["hours"][14]
    assert h14["status"] == "WARNING"
    assert h14["slow_hops"] == ["pihole"]
    # 1 OK + 1 WARNING (0.5 credit) => 75.0% Apdex SLA
    assert payload["sla_percentage"] == 75.0


def test_disk_and_ram_dedup_and_non_eth0_recovery(tmp_path):
    now_dt = datetime(2026, 11, 26, 15, 40, 0)
    t_down = datetime(2026, 11, 26, 15, 10, 0)
    t_ok = datetime(2026, 11, 26, 15, 20, 0)

    log_file = tmp_path / "health.log"
    log_file.write_text(
        f"{t_down.strftime('%Y-%m-%d %H:%M:%S')} [INTERNET-HEALTH-CHECK] [en0] Test: Fail via Pi-hole (192.168.1.2:53)\n"
        f"{t_down.strftime('%Y-%m-%d %H:%M:%S')} [INTERNET-HEALTH-CHECK] [en0] DOWN\n"
        f"{t_ok.strftime('%Y-%m-%d %H:%M:%S')} [INTERNET-HEALTH-CHECK] [en0] OK\n"
    )
    ram = tmp_path / "ram.txt"
    # RAM recorded 12s after disk log due to timeout drift -> must deduplicate to 1 incident
    ram.write_text(f"{int(t_down.timestamp()) + 12},en0,OK,false,false,true,true,-1,0,15,0,true,down,10\n")

    payload = telemetry.build_telemetry_payload(
        make_live({"en0": healthy_iface()}), str(ram), str(log_file), now_dt=now_dt
    )
    h15 = payload["history"][2]["hours"][15]
    assert h15["status"] == "DANGER"
    assert h15["has_recovered"] is True
    assert h15["recovered_at"] == "15:20:00"
    assert h15["pihole"] is False
    assert len(payload["incidents"]) == 1


def test_current_hour_metadata(tmp_path):
    now_dt = datetime(2026, 4, 20, 15, 22, 0)
    ram = tmp_path / "ram.csv"
    log_file = tmp_path / "hc.log"
    ram.write_text(f"{int(now_dt.timestamp()) - 60},en0,OK,true,true,true,true,12,20,25,0,true,,\n")

    payload = telemetry.build_telemetry_payload(
        make_live({"en0": healthy_iface()}), str(ram), str(log_file), now_dt=now_dt
    )
    h15 = payload["history"][2]["hours"][15]
    h14 = payload["history"][2]["hours"][14]
    y15 = payload["history"][1]["hours"][15]
    assert h15["is_current"] is True
    assert h15["elapsed_minutes"] == 22
    assert h14["is_current"] is False
    assert y15["is_current"] is False


def test_disk_hourly_heartbeat_survives_ram_wipe(tmp_path):
    now_dt = datetime(2026, 4, 20, 15, 10, 0)
    ram = tmp_path / "ram_empty.csv"
    log_file = tmp_path / "hc.log"
    log_file.write_text(
        "\n".join([
            "2026-04-20 12:00:05 [INTERNET-HEALTH-CHECK] [eth0] OK",
            "2026-04-20 13:00:05 [INTERNET-HEALTH-CHECK] [eth0] OK",
            "2026-04-20 14:00:05 [INTERNET-HEALTH-CHECK] [eth0] OK",
        ]) + "\n"
    )

    payload = telemetry.build_telemetry_payload(
        make_live({"en0": healthy_iface()}), str(ram), str(log_file), now_dt=now_dt
    )
    today = payload["history"][2]["hours"]
    for hr in (12, 13, 14):
        assert today[hr]["status"] == "OK"
    assert payload["sla_percentage"] == 100.0
