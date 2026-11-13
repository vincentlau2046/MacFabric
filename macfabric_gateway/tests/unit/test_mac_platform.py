"""MacFabric P1 单测 — 平台层门禁（CUDA 线退役 / macOS 探测）。"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from inferfabric import mac_platform as mp


def test_budget_formula_ram_minus_8g(monkeypatch):
    monkeypatch.setattr(mp, "mem_total_mb", lambda: 32768)
    monkeypatch.setenv("MACFABRIC_RESERVE_MB", "8192")
    assert mp.budget_mb() == 24576


def test_budget_128g_mac_no_artificial_cap(monkeypatch):
    """D2: 128GB Mac 不人为设第二上限。"""
    monkeypatch.setattr(mp, "mem_total_mb", lambda: 131072)
    monkeypatch.setenv("MACFABRIC_RESERVE_MB", "8192")
    assert mp.budget_mb() == 122880


def test_budget_respect_env_override(monkeypatch):
    monkeypatch.setattr(mp, "mem_total_mb", lambda: 32768)
    monkeypatch.setenv("MACFABRIC_RESERVE_MB", "16384")
    assert mp.budget_mb() == 16384


def test_mem_total_real_probe_if_macos():
    """在 macOS 上真实探测应成功且数值合理；非 macOS 返回 None。"""
    total = mp.mem_total_mb()
    if mp.IS_MACOS:
        assert total and total > 8192
    else:
        assert total is None


def test_pid_on_port_returns_int_or_none():
    """烟测：8999 上若无监听则 None；不抛异常即通过。"""
    pid = mp.pid_on_port(59999)
    assert pid is None or isinstance(pid, int)


def test_mem_used_not_exceed_total():
    if mp.IS_MACOS:
        used, total = mp.mem_used_mb(), mp.mem_total_mb()
        assert used is not None
        assert 0 <= used <= total
