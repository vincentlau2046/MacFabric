"""JobRegistry 单测 — 批 4 TOP3b（spec 2026-11-17-batch4-jobs-infra.md）。

钉住：状态机迁移 / 协作式取消语义 / 竞态保护（完成优先于取消标记）/
完结裁剪上限 / run_async 异常归一 failed。
"""
import time

import pytest

from inferfabric.jobs import JobRegistry
from inferfabric.proxy import handler as proxy_handler


class _FakeHandler(proxy_handler.ProxyHandler):
    """HTTP 层测试替身：继承 ProxyHandler 拿到全部真实方法，
    跳过 BaseHTTPRequestHandler.__init__（不绑 socket），只注入行为。"""

    def __init__(self, admin_ok=True):  # noqa: D107 - 故意不调 super().__init__
        self.admin_ok = admin_ok
        self.admin_checked = False

    def _check_admin(self):
        self.admin_checked = True
        return self.admin_ok


def test_create_returns_queued():
    reg = JobRegistry()
    job = reg.create("discover", "全量发现")
    assert job["status"] == "queued"
    got = reg.get(job["job_id"])
    assert got["kind"] == "discover" and got["status"] == "queued"
    assert "cancel_requested" not in got  # 内部协控位不外露


def test_start_and_finish_done():
    reg = JobRegistry()
    job = reg.create("switch")
    reg.start(job["job_id"])
    reg.finish(job["job_id"], "done", {"ok": True})
    got = reg.get(job["job_id"])
    assert got["status"] == "done" and got["result"] == {"ok": True}
    assert got["finished_at"] is not None


def test_finish_invalid_status_raises():
    reg = JobRegistry()
    job = reg.create("switch")
    with pytest.raises(ValueError):
        reg.finish(job["job_id"], "running")


def test_finish_idempotent_terminal_wins():
    """已完成 job 再 finish 是 no-op（不覆盖已有结果）。"""
    reg = JobRegistry()
    job = reg.create("switch")
    reg.finish(job["job_id"], "done", {"n": 1})
    reg.finish(job["job_id"], "failed", {"n": 2})
    assert reg.get(job["job_id"])["result"] == {"n": 1}


def test_cancel_then_checkpoint_sees_requested():
    reg = JobRegistry()
    job = reg.create("discover")
    reg.start(job["job_id"])
    payload, code = reg.request_cancel(job["job_id"])
    assert code == 200 and payload["status"] == "cancelling"
    assert reg.cancel_requested(job["job_id"]) is True
    # 任务体在检查点收尾为 cancelled
    reg.finish(job["job_id"], "cancelled", {"providers_done": 2})
    got = reg.get(job["job_id"])
    assert got["status"] == "cancelled"
    # 完结后重复取消 → 409
    _, code2 = reg.request_cancel(job["job_id"])
    assert code2 == 409


def test_finish_natural_done_beats_cancel_flag():
    """竞态：用户置了取消位，但任务体已产出结果 → 完成态如实落账。
    假装取消是撒谎（结果已存在）。
    """
    reg = JobRegistry()
    job = reg.create("discover")
    reg.start(job["job_id"])
    reg.request_cancel(job["job_id"])
    reg.finish(job["job_id"], "done", {"cloud_models": 7})
    got = reg.get(job["job_id"])
    assert got["status"] == "done" and got["result"] == {"cloud_models": 7}


def test_cancel_unknown_job_404():
    reg = JobRegistry()
    _, code = reg.request_cancel("nope")
    assert code == 404


def test_prune_keeps_max_finished():
    reg = JobRegistry(max_finished=3)
    ids = [reg.create("x")["job_id"] for _ in range(5)]
    for i, jid in enumerate(ids):
        reg.start(jid)
        reg.finish(jid, "done", {"i": i})
        time.sleep(0.001)  # finished_at 单调
    alive = [j for j in reg._jobs.values() if j["status"] == "done"]
    assert len(alive) == 3
    # 最旧的被裁掉
    assert all(j["result"]["i"] >= 2 for j in alive)


def test_run_async_normal_path():
    reg = JobRegistry()
    job = reg.create("discover")
    reg.run_async(
        job,
        lambda should_cancel: ("done", {"n": 5}) if not should_cancel() else ("cancelled", None),
        on_error_result=lambda exc: {"error": str(exc)},
    )
    deadline = time.time() + 2
    while time.time() < deadline:
        got = reg.get(job["job_id"])
        if got["status"] in JobRegistry.TERMINAL:
            break
        time.sleep(0.01)
    assert got["status"] == "done" and got["result"] == {"n": 5}


def test_run_async_exception_becomes_failed():
    reg = JobRegistry()
    job = reg.create("switch")

    def boom(should_cancel):
        raise RuntimeError("gpu exploded")

    reg.run_async(job, boom, on_error_result=lambda exc: {"error": str(exc)})
    deadline = time.time() + 2
    while time.time() < deadline:
        got = reg.get(job["job_id"])
        if got["status"] in JobRegistry.TERMINAL:
            break
        time.sleep(0.01)
    assert got["status"] == "failed"
    assert got["result"] == {"error": "gpu exploded"}


def test_run_async_cancel_checkpoint_honored():
    reg = JobRegistry()
    job = reg.create("discover")
    reg.request_cancel(job["job_id"])  # 创建即请求取消

    def body(should_cancel):
        return ("cancelled", {"providers_done": 0}) if should_cancel() else ("done", None)

    reg.run_async(job, body, on_error_result=lambda exc: {"error": str(exc)})
    deadline = time.time() + 2
    while time.time() < deadline:
        got = reg.get(job["job_id"])
        if got["status"] in JobRegistry.TERMINAL:
            break
        time.sleep(0.01)
    assert got["status"] == "cancelled"


# ── HTTP 层契约：动态段门禁 + discover/switch 任务化语义 ──────────


def test_dynamic_job_routes_go_through_admin_gate():
    """P0 鉴权缺口回归：do_GET/do_POST 动态分支必须先过 _admin 门禁。"""
    wrapped = proxy_handler._admin(proxy_handler._job_route)
    h = _FakeHandler(admin_ok=False)
    wrapped(h, object())
    assert h.admin_checked, "_job_route must be invoked via _admin wrapper"


def test_discover_endpoint_creates_job_202():
    """POST /admin/cloud/discover 默认 202 + job_id（sync=true 保留同步）。"""
    class _PM:
        class cloud:  # noqa: N801 - 简单命名空间替身
            @staticmethod
            def discover_all(should_cancel=None):
                if should_cancel is not None and should_cancel():
                    return {}
                return {"p/m": object()}
            _cloud_discovered = False

    pm = _PM()
    h = _FakeHandler(admin_ok=True)
    h._read_body = lambda: {}
    sent = {}
    h._send_json = lambda payload, code=200: sent.update(payload=payload, code=code)
    proxy_handler.ProxyHandler._handle_cloud_discover(h, pm)
    assert sent["code"] == 202
    job_id = sent["payload"]["job_id"]
    job = proxy_handler._JOB_REGISTRY.get(job_id)
    assert job["kind"] == "discover"
    deadline = time.time() + 3
    while time.time() < deadline and job["status"] not in JobRegistry.TERMINAL:
        time.sleep(0.02)
        job = proxy_handler._JOB_REGISTRY.get(job_id)
    assert job["status"] == "done"
    assert job["result"]["status"] == "discovered"


def test_switch_endpoint_creates_job_202_gate_409_sync():
    """/switch 默认 202；409 gate 同步；sync=true 保留旧同步语义。"""
    class _State:
        def get(self, key):
            return ""

        def clear_manual_stop(self, target):
            pass

    class _Mgr:
        state = _State()

        def switch(self, target, force=False):
            return {"status": "switched", "model": target}

    class _PM:
        mgr = _Mgr()

    pm = _PM()
    h = _FakeHandler(admin_ok=True)
    h._read_body = lambda: {"model": "m1"}
    sent = {}
    h._send_json = lambda payload, code=200: sent.update(payload=payload, code=code)
    proxy_handler.ProxyHandler._handle_switch(h, pm)
    assert sent["code"] == 202
    job_id = sent["payload"]["job_id"]
    deadline = time.time() + 3
    job = proxy_handler._JOB_REGISTRY.get(job_id)
    while time.time() < deadline and job["status"] not in JobRegistry.TERMINAL:
        time.sleep(0.02)
        job = proxy_handler._JOB_REGISTRY.get(job_id)
    assert job["status"] == "done"
    assert job["result"]["status"] == "switched"

    # 409 gate：切换进行中 → 同步立即 409，不开 job
    class _BusyState:
        def get(self, key):
            return "other-model"

    class _BusyMgr:
        state = _BusyState()

    pm_busy = _PM.__new__(_PM)
    pm_busy.mgr = _BusyMgr()
    sent.clear()
    proxy_handler.ProxyHandler._handle_switch(h, pm_busy)
    assert sent["code"] == 409
    assert "job_id" not in sent["payload"]

    # sync=true 保留旧同步语义
    class _SyncPM:
        mgr = _Mgr()

    sent.clear()
    h._read_body = lambda: {"model": "m1", "sync": True}
    proxy_handler.ProxyHandler._handle_switch(h, _SyncPM())
    assert sent["code"] == 200 and sent["payload"]["status"] == "switched"
