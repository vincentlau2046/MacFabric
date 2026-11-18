"""Upstreamable platform units: VRAM ledger backend, procguard, engine matrix.

VramThreeStateLedger must work on any box (Review Focus 1) — the gpu module
is injected, never imported at module scope; unit tests use fakes.
"""
import subprocess
import sys

from inferfabric.platform.resource import Lifecycle, Mode


# ── VRAM backend ───────────────────────────────────────────────

class _FakeGpu:
    def __init__(self, blocks=False):
        self.blocks = blocks
        self.asked = None

    def would_block(self, name, needed_mb, exclusive):
        self.asked = (name, needed_mb, exclusive)
        return self.blocks


def _vram(budget=8000, gpu=None):
    from inferfabric.platform.resource_vram import VramThreeStateLedger
    return VramThreeStateLedger(budget_mb=budget, gpu=gpu)


def test_vram_admit_within_budget():
    led = _vram(budget=8000)
    led.register("m", 4000, Mode.ON_DEMAND)
    d = led.admit("m")
    assert d.ok and d.needed_mb == 4000


def test_vram_admit_rejects_over_budget_english_reason():
    led = _vram(budget=8000)
    led.register("big", 9000, Mode.ON_DEMAND)
    d = led.admit("big")
    assert not d.ok and "VRAM" in d.reason


def test_vram_gpu_gate_blocks_and_force_overrides():
    gpu = _FakeGpu(blocks=True)
    led = _vram(budget=8000, gpu=gpu)
    led.register("b", 1000, Mode.ON_DEMAND)
    d = led.admit("b")
    assert not d.ok and gpu.asked == ("b", 1000, True)
    assert led.admit("b", force=True).ok


def test_vram_reuses_lifecycle_and_sleep_semantics():
    led = _vram(budget=8000)
    e = led.register("od", 1000, Mode.ON_DEMAND, idle_timeout_min=5)
    led.mark_ready("od")
    e.last_used_ts -= 6 * 60
    assert led.idle_sleep_candidates() == ["od"]
    led.mark_sleeping("od")
    assert led.registered("od").state is Lifecycle.SLEEPING


def test_vram_resident_total_counts_ready_not_stopped():
    led = _vram(budget=8000)
    a = led.register("a", 1000, Mode.RESIDENT)
    led.register("b", 1000, Mode.RESIDENT)
    led.mark_ready("a")
    assert led.resident_total_mb() == 1000  # stopped entries don't count


# ── ProcGuard ──────────────────────────────────────────────────

def test_launchd_plist_render_contains_essentials():
    from inferfabric.platform.procguard import render_launchd_plist
    plist = render_launchd_plist(
        label="com.macfabric.gateway",
        program_args=["/bin/sh", "-lc", "exec gateway"],
        keep_alive=True,
    )
    assert "com.macfabric.gateway" in plist
    assert "KeepAlive" in plist and "true" in plist
    assert "/bin/sh" in plist


def test_null_guard_is_foreground_noop():
    from inferfabric.platform.procguard import NullProcGuard
    g = NullProcGuard()
    assert g.install() is True and g.uninstall() is True
    assert g.status() == "foreground"


def test_procguard_protocol_selected_by_profile():
    from inferfabric.platform import detect
    from inferfabric.platform.procguard import guard_for_profile
    assert guard_for_profile(detect()) is not None


# ── Engine matrix ──────────────────────────────────────────────

def test_engine_matrix_split_by_platform():
    from inferfabric.platform.engines import ENGINES
    assert "llama_cpp" in ENGINES["darwin"] and "vllm" not in ENGINES["darwin"]
    assert "vllm" in ENGINES["linux"] and "ocr_helper" not in ENGINES["linux"]


def test_engines_module_import_isolation():
    code = (
        "import sys, inferfabric.platform.engines;"
        "bad=[m for m in ('inferfabric.manager','inferfabric.process_manager') if m in sys.modules];"
        "print('PULLED' if bad else 'ISOLATED')"
    )
    out = subprocess.run(
        [sys.executable, "-c", code], capture_output=True, text=True, check=True)
    assert "ISOLATED" in out.stdout
