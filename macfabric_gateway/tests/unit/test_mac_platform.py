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


# ── 保留内存用户可设置（2026-11-16）：env > packs policy.json > 默认 8192 ──

def _write_policy(state_dir, reserved_mb):
    packs = state_dir / "packs"
    packs.mkdir(parents=True, exist_ok=True)
    (packs / "policy.json").write_text(
        '{"max_model_parameters_b": 4, "system_reserved_memory_mb": %d}'
        % reserved_mb, encoding="utf-8")


def test_budget_reads_pack_policy_when_env_unset(monkeypatch, tmp_path):
    """设置页保存的 system_reserved_memory_mb 是账本保留的唯一用户入口（D2 全局唯一公式）。"""
    monkeypatch.setattr(mp, "mem_total_mb", lambda: 32768)
    monkeypatch.delenv("MACFABRIC_RESERVE_MB", raising=False)
    monkeypatch.setenv("MACFABRIC_STATE_DIR", str(tmp_path))
    _write_policy(tmp_path, 6144)
    assert mp.budget_mb() == 32768 - 6144


def test_env_overrides_pack_policy(monkeypatch, tmp_path):
    """显式 env 仍是最高优先级覆盖（开发/测试逃生口）。"""
    monkeypatch.setattr(mp, "mem_total_mb", lambda: 32768)
    monkeypatch.setenv("MACFABRIC_RESERVE_MB", "16384")
    monkeypatch.setenv("MACFABRIC_STATE_DIR", str(tmp_path))
    _write_policy(tmp_path, 6144)
    assert mp.budget_mb() == 16384


def test_budget_falls_back_to_default_on_missing_or_bad_policy(
        monkeypatch, tmp_path):
    monkeypatch.setattr(mp, "mem_total_mb", lambda: 32768)
    monkeypatch.delenv("MACFABRIC_RESERVE_MB", raising=False)
    monkeypatch.setenv("MACFABRIC_STATE_DIR", str(tmp_path))
    # 缺文件 → 默认 8192
    assert mp.budget_mb() == 24576
    # 损坏 JSON → 默认
    (tmp_path / "packs").mkdir()
    (tmp_path / "packs" / "policy.json").write_text("{broken", encoding="utf-8")
    assert mp.budget_mb() == 24576
    # 非法值（<1）→ 默认
    _write_policy(tmp_path, 0)
    assert mp.budget_mb() == 24576


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
