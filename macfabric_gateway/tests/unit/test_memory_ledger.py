"""MacFabric P1 单测 — 内存账本三规则（D2/D3 裁决）。"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from inferfabric.memory_ledger import (
    AdmitDecision, Lifecycle, MemoryLedger, Mode,
)


def make_ledger(budget=16384, probe=None):
    return MemoryLedger(budget_mb=budget, probe_available_mb=probe)


# ── R1 准入 ──────────────────────────────────────────────────────

def test_r1_admit_within_budget():
    led = make_ledger(budget=16384)
    led.register("a", mem_baseline_mb=3100, mode=Mode.ON_DEMAND)
    d = led.admit("a")
    assert d.ok
    assert led.registered("a").state == Lifecycle.LOADING


def test_r1_refuse_when_over_budget():
    led = make_ledger(budget=4096)
    led.register("a", 3100, Mode.ON_DEMAND)
    led.register("b", 2000, Mode.ON_DEMAND)
    assert led.admit("a").ok
    led.mark_ready("a")
    d = led.admit("b")
    assert not d.ok
    assert "内存不足" in d.reason
    assert d.needed_mb == 2000 and d.available_mb == 996


def test_r1_force_oversell_after_human_confirm():
    """用户在弹窗点『仍然加载』→ force=True 放行，语义为责任转移。"""
    led = make_ledger(budget=4096)
    led.register("a", 3100, Mode.ON_DEMAND)
    led.register("b", 2000, Mode.ON_DEMAND)
    led.admit("a"); led.mark_ready("a")
    d = led.admit("b", force=True)
    assert d.ok
    assert "用户确认" in d.reason


def test_r1_probe_tightens_constraint():
    """实测水位比账面更紧时取更紧约束。"""
    led = make_ledger(budget=16384, probe=lambda: 2000)  # 实测仅剩 2GB
    led.register("a", 3100, Mode.ON_DEMAND)
    d = led.admit("a")
    assert not d.ok


def test_r1_sleeping_entry_occupies_quarter():
    """sleeping 只按基线 25% 记账（KV 归零后驻留估计）。"""
    led = make_ledger(budget=4096)
    led.register("a", 3100, Mode.ON_DEMAND)
    led.admit("a"); led.mark_ready("a"); led.mark_sleeping("a")
    assert led.resident_total_mb() == 775
    led.register("b", 2000, Mode.ON_DEMAND)
    assert led.admit("b").ok


def test_r1_unregistered_model_refused():
    led = make_ledger()
    assert not led.admit("ghost").ok


# ── 生命周期 ─────────────────────────────────────────────────────

def test_lifecycle_full_path():
    led = make_ledger()
    led.register("a", 3100, Mode.ON_DEMAND)
    e = led.registered("a")
    assert e.state == Lifecycle.STOPPED
    led.admit("a"); assert e.state == Lifecycle.LOADING
    led.mark_ready("a"); assert e.state == Lifecycle.READY
    led.mark_sleeping("a"); assert e.state == Lifecycle.SLEEPING
    led.mark_stopped("a"); assert e.state == Lifecycle.STOPPED
    assert led.resident_total_mb() == 0


def test_touch_refreshes_last_used():
    led = make_ledger()
    led.register("a", 100, Mode.ON_DEMAND, idle_timeout_min=1)
    e = led.registered("a")
    e.last_used_ts -= 3600
    led.touch("a")
    assert e.idle_seconds < 5


# ── R2 空闲休眠 ─────────────────────────────────────────────────

def test_r2_on_demand_idle_candidates():
    led = make_ledger()
    led.register("old", 100, Mode.ON_DEMAND, idle_timeout_min=30)
    led.register("young", 100, Mode.ON_DEMAND, idle_timeout_min=30)
    led.register("keep", 100, Mode.RESIDENT)
    for n in ("old", "young", "keep"):
        led.admit(n); led.mark_ready(n)
    led.registered("old").last_used_ts -= 3600        # 空闲 60min
    led.registered("young").last_used_ts -= 60        # 空闲 1min
    cands = led.idle_sleep_candidates()
    assert cands == ["old"]                            # resident 永不候选


def test_r2_resident_never_sleeps():
    led = make_ledger()
    led.register("r", 100, Mode.RESIDENT)
    led.admit("r"); led.mark_ready("r")
    led.registered("r").last_used_ts -= 86400
    assert led.idle_sleep_candidates() == []


# ── R3 压力安全网 ────────────────────────────────────────────────

def test_r3_no_eviction_below_pressure_3():
    led = make_ledger()
    led.register("a", 100, Mode.ON_DEMAND)
    led.admit("a"); led.mark_ready("a")
    assert led.pressure_eviction_plan(2) == []


def test_r3_on_demand_before_resident():
    led = make_ledger()
    led.register("res", 100, Mode.RESIDENT)
    led.register("od1", 100, Mode.ON_DEMAND)
    led.register("od2", 100, Mode.ON_DEMAND)
    for n in ("res", "od1", "od2"):
        led.admit(n); led.mark_ready(n)
    led.registered("od1").last_used_ts -= 7200
    led.registered("od2").last_used_ts -= 60
    plan = led.pressure_eviction_plan(3)
    assert plan == ["od1", "od2", "res"]               # 按空闲时长排序


def test_r3_sleeping_and_stopped_excluded():
    led = make_ledger()
    led.register("slept", 100, Mode.ON_DEMAND)
    led.register("dead", 100, Mode.ON_DEMAND)
    led.admit("slept"); led.mark_ready("slept"); led.mark_sleeping("slept")
    led.admit("dead"); led.mark_stopped("dead")
    assert led.pressure_eviction_plan(4) == []
