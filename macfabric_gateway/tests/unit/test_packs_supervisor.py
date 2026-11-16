"""PackSupervisor drain/强杀进程组/rlimit — PK2（Task 9）。

契约（计划 Interfaces）：
- drain_and_stop(name, stop_fn, is_alive_fn) -> DrainResult(stopped,
  forced_kill, elapsed_s)：调 stop_fn 后轮询 is_alive，最长 drain_timeout_s
  （默认 10s）；超时对进程组 SIGKILL（os.killpg）。
- pack_rlimits(manifest) -> {RLIMIT_NOFILE:256, RLIMIT_NPROC:64,
  RLIMIT_CPU:3600}；内存不做 rlimit（macOS no-op，spec §8.4 事实）。
- 崩溃标记：包进程异常退出 → 该包 degraded，其他包不动。
"""

import os
import signal

import pytest

from inferfabric.packs.schema import parse_manifest
from inferfabric.packs.store import PackRecord, PackStore
from inferfabric.packs.supervisor import DrainResult, PackSupervisor, pack_rlimits
from tests_fixtures_packs import MINIMAL_MANIFEST_YAML


def test_drain_stops_within_timeout():
    state = {"alive": True}

    def stop():
        state["alive"] = False

    sup = PackSupervisor(drain_timeout_s=10.0)
    r = sup.drain_and_stop("pack-a", stop_fn=stop,
                           is_alive_fn=lambda: state["alive"])
    assert isinstance(r, DrainResult)
    assert r.stopped and not r.forced_kill
    assert r.elapsed_s < 10.0


def test_drain_timeout_force_kills_process_group(monkeypatch):
    killed = []

    def fake_killpg(pg, sig):
        killed.append((pg, sig))

    monkeypatch.setattr(os, "killpg", fake_killpg)
    sup = PackSupervisor(drain_timeout_s=0.2, poll_interval_s=0.05)
    r = sup.drain_and_stop("pack-a", stop_fn=lambda: None,
                           is_alive_fn=lambda: True, pgid_fn=lambda: 424242)
    assert r.stopped is True and r.forced_kill is True   # 强杀后视为终止
    assert killed and killed[0] == (424242, signal.SIGKILL)


def test_drain_without_pgid_never_blind_kills(monkeypatch):
    # pgid_fn 缺失 → 不得对任何进程组发信号（防误杀网关自身组）
    def boom(pg, sig):
        raise AssertionError(f"killpg called with {pg}, {sig}")

    monkeypatch.setattr(os, "killpg", boom)
    sup = PackSupervisor(drain_timeout_s=0.1, poll_interval_s=0.05)
    r = sup.drain_and_stop("pack-a", stop_fn=lambda: None,
                           is_alive_fn=lambda: True)
    assert r.stopped is False and r.forced_kill is False


def test_pack_rlimits_frozen_values():
    import resource
    m = parse_manifest(MINIMAL_MANIFEST_YAML)
    rl = pack_rlimits(m)
    assert rl[resource.RLIMIT_NOFILE] == 256
    assert rl[resource.RLIMIT_NPROC] == 64
    assert rl[resource.RLIMIT_CPU] == 3600
    # macOS 内存 rlimit 不可靠 — 不得出现在包限制里（spec §8.4）
    assert resource.RLIMIT_AS not in rl and resource.RLIMIT_RSS not in rl


def test_rlimits_applicable_via_preexec():
    # preexec_fn 可执行性冒烟：真实 setrlimit 接受这些值
    import resource
    m = parse_manifest(MINIMAL_MANIFEST_YAML)
    rl = pack_rlimits(m)
    old = resource.getrlimit(resource.RLIMIT_NOFILE)
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE,
                           (min(rl[resource.RLIMIT_NOFILE], old[0]), old[1]))
    finally:
        resource.setrlimit(resource.RLIMIT_NOFILE, old)


def test_crash_marks_degraded_only_this_pack(tmp_path):
    st = PackStore(tmp_path / "state.json")
    st.set(PackRecord(pack_id="llm.a", pack_version="1.0.0",
                      status="installed", stage="installed", error=None,
                      sandbox_degraded=False, installed_at=1))
    st.set(PackRecord(pack_id="llm.b", pack_version="1.0.0",
                      status="installed", stage="installed", error=None,
                      sandbox_degraded=False, installed_at=1))
    sup = PackSupervisor(store=st)
    sup.mark_crashed("llm.a", reason="exit_code_137")
    assert st.get("llm.a").status == "degraded"
    assert "exit_code_137" in st.get("llm.a").error
    assert st.get("llm.b").status == "installed"   # 不污染其他包


def test_drain_timeout_killpg_eperm_honest(monkeypatch):
    # 终审 deferred #1：killpg EPERM 等失败不得谎报 stopped=True
    from inferfabric.packs import supervisor as sup

    def fake_killpg(pg, sig):
        raise PermissionError(1, "Operation not permitted")

    monkeypatch.setattr(sup.os, "killpg", fake_killpg)
    s = PackSupervisor(drain_timeout_s=0.05, poll_interval_s=0.01)
    res = s.drain_and_stop("p", stop_fn=lambda: None,
                           is_alive_fn=lambda: True, pgid_fn=lambda: 999)
    assert res.stopped is False
    assert res.forced_kill is True


def test_drain_timeout_killpg_group_gone_is_stopped(monkeypatch):
    # 组已不存在（ESRCH）→ 视为终止，仍报 stopped
    from inferfabric.packs import supervisor as sup

    def fake_killpg(pg, sig):
        raise ProcessLookupError()

    monkeypatch.setattr(sup.os, "killpg", fake_killpg)
    s = PackSupervisor(drain_timeout_s=0.05, poll_interval_s=0.01)
    res = s.drain_and_stop("p", stop_fn=lambda: None,
                           is_alive_fn=lambda: True, pgid_fn=lambda: 999)
    assert res.stopped is True
    assert res.forced_kill is True
