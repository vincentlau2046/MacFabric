"""platform.probe — platform probes + budget precedence (F2, Review Focus 3).

Precedence contract: MACFABRIC_RESERVE_MB env > packs policy.json
system_reserved_memory_mb > default 8192. The legacy mac_platform path must
stay patch-compatible (tests patch mac_platform.mem_total_mb).
"""
import subprocess
import sys

import pytest

from inferfabric.platform import probe


def _write_policy(tmp_path, mb):
    import json
    import os
    d = tmp_path / "packs"
    d.mkdir(parents=True, exist_ok=True)
    (d / "policy.json").write_text(json.dumps({"system_reserved_memory_mb": mb}))


def test_budget_env_beats_policy(tmp_path, monkeypatch):
    _write_policy(tmp_path, 4096)
    monkeypatch.setattr(probe, "mem_total_mb", lambda: 32768)
    monkeypatch.setenv("MACFABRIC_RESERVE_MB", "16384")
    monkeypatch.setenv("MACFABRIC_STATE_DIR", str(tmp_path))
    assert probe.budget_mb() == 32768 - 16384


def test_budget_policy_beats_default(tmp_path, monkeypatch):
    _write_policy(tmp_path, 4096)
    monkeypatch.setattr(probe, "mem_total_mb", lambda: 32768)
    monkeypatch.delenv("MACFABRIC_RESERVE_MB", raising=False)
    monkeypatch.setenv("MACFABRIC_STATE_DIR", str(tmp_path))
    assert probe.budget_mb() == 32768 - 4096


def test_budget_default_8192_when_unset(tmp_path, monkeypatch):
    monkeypatch.setattr(probe, "mem_total_mb", lambda: 32768)
    monkeypatch.delenv("MACFABRIC_RESERVE_MB", raising=False)
    monkeypatch.setenv("MACFABRIC_STATE_DIR", str(tmp_path))
    assert probe.budget_mb() == 32768 - 8192


def test_budget_zero_when_total_unknown(monkeypatch):
    monkeypatch.setattr(probe, "mem_total_mb", lambda: None)
    monkeypatch.setenv("MACFABRIC_RESERVE_MB", "1024")
    assert probe.budget_mb() == 0


def test_is_macos_follows_profile(monkeypatch):
    monkeypatch.setenv("MACFABRIC_FORCE_PLATFORM", "linux")
    from inferfabric.platform import probe as p2
    import importlib
    importlib.reload(p2)
    assert p2.IS_MACOS is False
    monkeypatch.setenv("MACFABRIC_FORCE_PLATFORM", "darwin")
    importlib.reload(p2)
    assert p2.IS_MACOS is True


def test_shim_is_patch_compatible(monkeypatch, tmp_path):
    """Existing discipline: tests patch mac_platform.mem_total_mb and call
    mac_platform.budget_mb() — the shim must honor that."""
    from inferfabric import mac_platform as mp
    monkeypatch.setattr(mp, "mem_total_mb", lambda: 32768)
    monkeypatch.setenv("MACFABRIC_RESERVE_MB", "8192")
    assert mp.budget_mb() == 32768 - 8192


def test_shim_warns_deprecation():
    out = subprocess.run(
        [sys.executable, "-W", "error::DeprecationWarning", "-c",
         "import inferfabric.mac_platform"],
        capture_output=True, text=True,
    )
    assert out.returncode != 0 and "deprecated" in (out.stderr or "").lower()
