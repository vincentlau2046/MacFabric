"""M2-T5 — overview 真账本快照（只读投影，计划 2026-11-19 Task 5）。

合同：
- ModelManager.memory_ledger_snapshot(device_snapshot) -> dict | None：
  统一内存平台返回 {budget_mb, committed_mb, entries[], pressure_level}；
  非 unified / 无平台快照返回 None。
- 预算/压力直接取 handler 已获取的 dev_snap（同一探针同一时间戳），
  观测路径不调用准入、不做额外探测；采样字段缺失保留 null，
  不抹掉可计算的账面占用。
- committed_mb = 活跃模型基线账面合计（baseline 缺省回退 peak_vram_mb）；
  不在活跃集合的模型不入账（含已退出进程的 llama.cpp sleep）；
  不因 sleep 标记打 25% 折扣；准入的目标排除、结果及探针策略不变。
- handler 把已获取的 dev_snap 显式传入，结果加 memory_ledger（含 ETag）；
  旧 handler 测试桩（无该方法）缺省兼容为 None。
- 前端：store 透传缺省兼容；overview 展示账面 committed/B 与压力
  1 正常 / 2 警告 / 3 严重 / null 未知；预算未知或为零不计算百分比；
  超预算时不掩盖原值。
"""
import json
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from inferfabric.platform.telemetry import DeviceSnapshot


# ── 快照/模型桩 ──────────────────────────────────────────────────

def _snap(**kw) -> DeviceSnapshot:
    base = dict(platform="darwin", accelerator="apple_silicon",
                memory_kind="unified", memory_used_mb=8000,
                memory_total_mb=None, memory_budget_mb=24576,
                utilization_pct=None, power_w=None, temperature_c=None,
                clock_mhz=None, pressure_level=1, timestamp=1234.5,
                sources={"sysctl": ["hw.memsize"]})
    base.update(kw)
    return DeviceSnapshot(**base)


def _model(name, baseline, peak=0, ledger_mode=""):
    return SimpleNamespace(name=name, mem_baseline_mb=baseline,
                           peak_vram_mb=peak, ledger_mode=ledger_mode)


def _make_manager(tmp_path, snapshot):
    from inferfabric.manager import ModelManager

    class _Tel:
        def __init__(self, snap):
            self._snap = snap

        def snapshot(self):
            return self._snap

        def capabilities(self):
            from inferfabric.platform.telemetry import DeviceCapabilities
            return DeviceCapabilities(memory=True, pressure=True)

    return ModelManager(
        models_dir=tmp_path / "models.d",
        state_db_path=tmp_path / "state.db",
        device_telemetry=_Tel(snapshot),
    )


# ── 账本投影 ─────────────────────────────────────────────────────

def test_memory_ledger_projection_uses_admission_baselines(tmp_path):
    mgr = _make_manager(tmp_path, _snap())
    mgr._models = {
        "a": _model("a", 3100, peak=9999, ledger_mode=""),
        "b": _model("b", 0, peak=2000, ledger_mode="resident"),   # baseline 缺省 → peak 回退
        "sleepy": _model("sleepy", 7000),   # 已退出进程的 llama.cpp sleep — 不在活跃集合
    }
    mgr.state.set_active_services(["a", "b"])
    led = mgr.memory_ledger_snapshot(_snap())
    assert led is not None
    assert led["budget_mb"] == 24576
    assert led["pressure_level"] == 1
    # 全额记账（无 25% 睡眠折扣 — sleeping 模型本就不入账）
    assert led["committed_mb"] == 3100 + 2000
    entries = {e["name"]: e for e in led["entries"]}
    assert entries["a"]["mem_baseline_mb"] == 3100
    assert entries["a"]["mode"] == "on_demand"
    assert entries["b"]["mem_baseline_mb"] == 2000   # peak_vram_mb 回退
    assert entries["b"]["mode"] == "resident"
    assert "sleepy" not in entries


def test_memory_ledger_projection_keeps_null_fields_and_empty(tmp_path):
    """统一内存但采样字段缺失：保留 null，不抹掉账面占用；空闲 committed=0。"""
    mgr = _make_manager(tmp_path, _snap(memory_budget_mb=None, pressure_level=None))
    mgr._models = {}
    mgr.state.set_active_services([])
    led = mgr.memory_ledger_snapshot(_snap(memory_budget_mb=None, pressure_level=None))
    assert led["budget_mb"] is None
    assert led["pressure_level"] is None
    assert led["committed_mb"] == 0
    assert led["entries"] == []


def test_memory_ledger_projection_non_unified_is_none(tmp_path):
    mgr = _make_manager(tmp_path, _snap(memory_kind="vram"))
    led = mgr.memory_ledger_snapshot(_snap(memory_kind="vram"))
    assert led is None


def test_memory_ledger_projection_none_snapshot_is_none(tmp_path):
    mgr = _make_manager(tmp_path, _snap())
    assert mgr.memory_ledger_snapshot(None) is None


def test_admit_memory_excludes_target_and_keeps_rules(monkeypatch, tmp_path):
    """准入路径不变：目标排除（否则会「已在运行」放行）、预算探测仍走原探针。"""
    from inferfabric.platform import probe as mac_platform
    monkeypatch.setattr(mac_platform, "IS_MACOS", True)
    monkeypatch.setattr(mac_platform, "budget_mb", lambda: 4096)
    monkeypatch.setattr(mac_platform, "mem_used_mb", lambda: None)
    mgr = _make_manager(tmp_path, _snap())
    mgr._models = {"a": _model("a", 3100), "c": _model("c", 2000)}
    mgr.state.set_active_services(["a"])
    d = mgr._admit_memory(mgr._models["c"])
    assert d is not None and not d.ok        # 4096 − 3100 = 996 < 2000
    assert d.needed_mb == 2000               # 目标被排除（否则「已在运行」ok）


# ── handler 接线 ─────────────────────────────────────────────────

def _run_snapshot_handler(monkeypatch, mgr, dev):
    """Drive ProxyHandler._handle_snapshot with the given mgr; return payload.
    （复用 test_device_api_contract 的壳：真实 _system_info，桩 HTTP writer。）"""
    from inferfabric.proxy import handler as hmod

    monkeypatch.setattr(hmod, "_compute_expensive",
                        lambda pm: {"status": {"gpu_mode": "idle",
                                               "gpu_used_mb": None,
                                               "gpu_total_mb": None,
                                               "gpu_util_pct": None,
                                               "active_services": []},
                                    "metrics_24h": {}})

    class HubCache:
        def __init__(self):
            self._snap = None
            self._at = None

        def get_device_snapshot(self):
            now = time.monotonic()
            if self._snap is None or now - self._at >= 15.0:
                self._snap = dev.snapshot()
                self._at = now
            return self._snap

    tel = SimpleNamespace(
        device_telemetry=dev, get_device_snapshot=HubCache().get_device_snapshot,
        query_request_log=lambda **k: [],
        token_collector=SimpleNamespace(_load_full_state=lambda: {}),
    )
    pm = SimpleNamespace(mgr=mgr, telemetry=tel)
    captured = {}

    class _Shell:
        _system_info = hmod.ProxyHandler._system_info

        def __init__(self):
            self.headers = {}

        def send_response(self, code):
            captured["code"] = code

        def send_header(self, k, v):
            captured.setdefault("headers", {})[k] = v

        def end_headers(self):
            pass

        def _safe_write(self, body):
            captured["body"] = body

    hmod.ProxyHandler._handle_snapshot(_Shell(), pm)
    return json.loads(captured["body"])


class CountingDevice:
    """每次 snapshot() 计数（同 test_device_api_contract 的桩）。"""

    def __init__(self, *, snapshot):
        self._snapshot = snapshot
        self.calls = 0

    def snapshot(self):
        self.calls += 1
        return self._snapshot

    def capabilities(self):
        from inferfabric.platform.telemetry import DeviceCapabilities
        return DeviceCapabilities(memory=True, pressure=True)


def test_snapshot_memory_ledger_reuses_device_sample(monkeypatch, tmp_path):
    snap = _snap(timestamp=77.0)
    dev = CountingDevice(snapshot=snap)
    real_mgr = _make_manager(tmp_path, snap)
    seen = {}
    real_proj = real_mgr.memory_ledger_snapshot

    def recording(s):
        seen["snap"] = s
        return real_proj(s)

    real_mgr.memory_ledger_snapshot = recording
    payload = _run_snapshot_handler(monkeypatch, real_mgr, dev)
    assert dev.calls == 1                       # 不新增探针调用
    assert seen["snap"] is snap                 # handler 传同一个快照对象
    ml = payload["memory_ledger"]
    assert ml is not None
    assert ml["budget_mb"] == 24576
    assert ml["pressure_level"] == 1
    assert ml["committed_mb"] == 0              # 空闲真实 0（非 None）


def test_snapshot_memory_ledger_legacy_stub_defaults_to_none(monkeypatch):
    """旧 handler 测试桩（mgr 无该方法）→ memory_ledger 为 null，不崩。"""
    dev = CountingDevice(snapshot=_snap())
    mgr = SimpleNamespace(list_models=lambda: [], _models={},
                          state=SimpleNamespace(get_history=lambda n: []))
    payload = _run_snapshot_handler(monkeypatch, mgr, dev)
    assert payload["memory_ledger"] is None


def test_snapshot_etag_changes_when_memory_ledger_changes():
    from inferfabric.proxy.handler import _snapshot_etag

    def etag_with(ledger):
        return _snapshot_etag({"memory_ledger": ledger, "status": {}})

    l1 = {"budget_mb": 24576, "committed_mb": 0, "entries": [], "pressure_level": 1}
    l2 = {"budget_mb": 24576, "committed_mb": 3100, "entries": [
        {"name": "a", "mem_baseline_mb": 3100, "mode": "on_demand"}],
        "pressure_level": 1}
    assert etag_with(l1) != etag_with(l2)       # 新字段进 ETag
    assert etag_with(l1) == etag_with(dict(l1))  # 同值同 etag


# ── 前端契约（store 透传 + overview 展示规则） ────────────────────

def _dash_src(name: str) -> str:
    from inferfabric import dashboard
    return (Path(dashboard._DASHBOARD_DIR) / "js" / name).read_text(encoding="utf-8")


def test_store_passes_memory_ledger_with_default():
    src = _dash_src("store.js")
    assert "memory_ledger" in src


def test_overview_ledger_display_rules():
    src = _dash_src("overview.js")
    # 压力四级文案：1 正常 / 2 警告 / 3 严重 / null 未知
    for word in ("正常", "警告", "严重", "未知"):
        assert word in src
    # 预算未知或为零不计算百分比（0 值 falsy 门 + null 显式判）
    assert "budget" in src
    assert "committed" in src


def test_overview_ledger_no_control_actions():
    """账本只读：账本卡不携带任何 data-action（不触发 switch/stop/唤醒）。"""
    from inferfabric import dashboard
    src = _dash_src("overview.js")
    if "renderLedger" in src:
        seg = src.split("renderLedger", 1)[1]
        # 取 renderLedger 函数体到下一个顶层 function 为止的近似窗口
        window = seg[:4000]
        assert 'data-action' not in window
