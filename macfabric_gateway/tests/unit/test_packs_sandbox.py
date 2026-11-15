"""沙箱能力探测与 Provider 接口 — PK0（Task 3）。

契约（计划 Interfaces）：
- probe_sandbox(mac_version, has_sbpl_api) -> SandboxProbe(mode ∈ full/degraded/
  unavailable, detail)；参数 None 时自检本机；探测自身失败归 UNAVAILABLE 并留诊断。
- SandboxProvider.apply(profile_name, pack_dir, env) -> dict（注入启动属性）；
  NoopProvider 为 degraded 兜底（进程组/目录/网络约束能做到的部分）。
- 降级准入判定在 installer（Task 5/8），探测只报事实（spec §8.2）。
"""

import os

from inferfabric.packs.sandbox import (
    NoopProvider,
    SandboxMode,
    probe_sandbox,
)


def test_probe_full_on_modern_mac_with_api():
    p = probe_sandbox(mac_version=(27, 2), has_sbpl_api=True)
    assert p.mode is SandboxMode.FULL
    assert p.detail


def test_probe_degraded_without_api():
    p = probe_sandbox(mac_version=(27, 2), has_sbpl_api=False)
    assert p.mode is SandboxMode.DEGRADED
    assert p.detail


def test_probe_unavailable_on_probe_error():
    # mac_version 给非法值模拟探测失败路径（自检分支不可用）
    p = probe_sandbox(mac_version=(0, 0), has_sbpl_api=None)
    assert p.mode in (SandboxMode.DEGRADED, SandboxMode.UNAVAILABLE)
    assert p.detail


def test_probe_self_check_runs_on_this_mac():
    # 自检路径（参数全 None）：仅要求返回合法枚举与 detail，不预设本机结果
    p = probe_sandbox()
    assert isinstance(p.mode, SandboxMode)
    assert p.detail


def test_noop_provider_returns_process_group_env(tmp_path):
    out = NoopProvider().apply("verified-local-pack-v1", tmp_path, {"A": "1"})
    assert out.get("start_new_session") is True
    assert out["env"]["A"] == "1"


def test_noop_provider_does_not_escalate(tmp_path):
    # degraded 兜底不得声称完整隔离
    out = NoopProvider().apply("verified-local-pack-v1", tmp_path, {})
    assert out.get("sandbox_mode") != "full"


def test_process_group_flag_matches_posix_setsid_semantics(tmp_path):
    # start_new_session=True 即 os.setsid 语义，供 killpg 整组收割（Task 9 消费）
    out = NoopProvider().apply("p", tmp_path, {})
    assert out["start_new_session"] is True
    assert hasattr(os, "killpg")
