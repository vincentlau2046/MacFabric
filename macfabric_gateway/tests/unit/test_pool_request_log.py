"""池终态日志持久化与尝试摘要 — PLAN-2026-11-15 v2 Task 2（P1）。

契约（计划 Interfaces）：
- 五类错误路径（未知池/鉴权拒绝/无候选/gate拒绝/预算耗尽）各恰一条
  SQLite 终态记录；route 非空且保持 pool 前缀；只认 SQLite，不认内存/JSONL。
- metadata.pool_summary v1：attempt_count/retry_count/fallback_count 可从
  SQLite 回读；准入拒绝不计 attempt；旧 metadata 缺失保持未知。
- 一次逻辑请求恰一条终态行（attempt 不单独成行）。
"""

import time
from pathlib import Path
from types import SimpleNamespace

import pytest

from inferfabric.model_pool import dispatch
from inferfabric.model_pool.config import CandidateConfig, PoolConfig
from inferfabric.model_pool.pool_forward import AttemptResult
from inferfabric.model_pool.registry import (
    PoolSnapshot,
    RegistrySnapshot,
    ResolvedCandidate,
)
from inferfabric.proxy.request_logger import RequestLogger
from inferfabric.request_log_db import RequestLogDB


# ── 夹具 ──

class FakeAuth:
    enabled = False

    def key_name(self, header):
        return "k1"

    def check(self, header, model):
        return True, "ok"


class FailingAuth(FakeAuth):
    enabled = True

    def check(self, header, model):
        return False, "bad key"


class FakeGate:
    def __init__(self, ok=True):
        self.ok = ok
        self.reason = "concurrency limit"

    def release(self):
        pass


class FakeHandler:
    def __init__(self):
        self.headers = {"Authorization": "Bearer x"}
        self.sent = []
        self._req_start = time.monotonic()

    def _send_json(self, obj, status, extra_headers=None):
        self.sent.append((status, obj))


def make_pm(tmp_path, *, pools=None, auth=None, gate=None):
    logger = RequestLogger(
        log_dir=tmp_path / "logs", enabled=True,
        db=RequestLogDB(db_path=tmp_path / "request_log.db"),
        jsonl_enabled=False, batch_size=100, flush_interval=3600)
    registry = None
    if pools:
        registry = SimpleNamespace(
            snapshot=lambda: RegistrySnapshot(
                revision=7, pools={p.pool.name: p for p in pools}))
    return SimpleNamespace(
        logger=logger, auth=auth or FakeAuth(), pool_registry=registry,
        mgr=SimpleNamespace(active_services={"qwen3-4b"}, get_model=None,
                            list_models=None),
        cloud=SimpleNamespace(cloud_models={}),
        dual_gate=SimpleNamespace(
            acquire=lambda model, timeout=None: gate or FakeGate()),
        _n=0,
        new_request_id=lambda: "req-t2",
    )


def resolved(cand: CandidateConfig) -> ResolvedCandidate:
    # 对齐真实 registry._evidence_for：声明协议注入 DECLARED 证据
    from inferfabric.model_pool.evidence import Evidence, EvidenceState
    ev = {p: Evidence(state=EvidenceState.DECLARED, protocol=p,
                      features=(), fingerprint=f"fp-{cand.id}",
                      recorded_at="", source="admin-declare")
          for p in (cand.declared_protocols or ())}
    return ResolvedCandidate(
        candidate=cand, endpoint_fingerprint=f"fp-{cand.id}",
        evidence=ev, route={"openai_base": "http://x", "anthropic_base": "http://x"})


def local_pool(name="flash", cands=None):
    if cands is None:
        cands = [CandidateConfig(
            id="c1", priority=10, kind="local", model_name="qwen3-4b",
            declared_protocols=("openai",))]
    pool = PoolConfig(name=name, enabled=True, allowed_locations=("local",),
                      accept_declared=True, max_attempts=3, deadline_ms=5000,
                      candidates=tuple(cands))
    return PoolSnapshot(revision=7, pool=pool,
                        candidates=tuple(resolved(c) for c in cands), issues=())


def rows(tmp_path, pm):
    pm.logger.flush_blocking(5)
    db = pm.logger._db
    return db.query_request_log(since=0.0, limit=100)


@pytest.fixture()
def tmp_env(tmp_path):
    return tmp_path


# ── 五类错误路径持久化 ──

class TestPoolErrorsPersist:

    def test_unknown_pool(self, tmp_env):
        pm = make_pm(tmp_env, pools=[local_pool("flash")])
        h = FakeHandler()
        assert dispatch.handle_pool_chat(h, pm, {}, "fabric-nope") is True
        rs = rows(tmp_env, pm)
        assert len(rs) == 1
        r = rs[0]
        assert r["status"] == 404 and r["error"] == "unknown_pool"
        assert r["route"] == "pool:nope"
        assert (r.get("metadata") or {}).get("pool_summary", {}).get("outcome") == "unknown_pool"

    def test_auth_rejected(self, tmp_env):
        pm = make_pm(tmp_env, pools=[local_pool("flash")], auth=FailingAuth())
        h = FakeHandler()
        assert dispatch.handle_pool_chat(h, pm, {}, "fabric-flash") is True
        rs = rows(tmp_env, pm)
        assert len(rs) == 1
        r = rs[0]
        assert r["status"] == 401
        assert r["route"] == "pool:flash"
        assert (r.get("metadata") or {}).get("pool_summary", {}).get("outcome") == "auth_rejected"

    def test_no_candidates(self, tmp_env):
        pm = make_pm(tmp_env, pools=[local_pool("empty", cands=[])])
        h = FakeHandler()
        assert dispatch.handle_pool_chat(h, pm, {}, "fabric-empty") is True
        rs = rows(tmp_env, pm)
        assert len(rs) == 1
        r = rs[0]
        assert r["route"] == "pool:empty"
        assert r["error"] in ("no_compatible_target", "no_ready_target")
        assert (r.get("metadata") or {}).get("pool_summary", {}).get("outcome") == r["error"]

    def test_gate_rejected(self, tmp_env):
        pm = make_pm(tmp_env, pools=[local_pool("flash")],
                     gate=FakeGate(ok=False))
        h = FakeHandler()
        assert dispatch.handle_pool_chat(h, pm, {}, "fabric-flash") is True
        rs = rows(tmp_env, pm)
        assert len(rs) == 1
        r = rs[0]
        assert r["status"] == 429 and r["route"] == "pool:flash"
        assert (r.get("metadata") or {}).get("pool_summary", {}).get("outcome") == "rate_limited"

    def test_budget_exhausted(self, tmp_env, monkeypatch):
        pm = make_pm(tmp_env, pools=[local_pool("flash")])
        calls = []

        def fake_transport(handler, pm_, data, *, model, pool, cand, remaining=None):
            calls.append(cand.candidate.id)
            return AttemptResult(ok=False, committed=False, status=None,
                                 error="conn_fail",
                                 route=f"pool:{pool}/local:{cand.candidate.model_name}")

        monkeypatch.setattr(dispatch, "_attempt_local_openai", fake_transport)
        h = FakeHandler()
        assert dispatch.handle_pool_chat(h, pm, {}, "fabric-flash") is True
        rs = rows(tmp_env, pm)
        assert len(rs) == 1  # 终态一行，attempt 不单独成行
        r = rs[0]
        assert r["status"] == 503 and r["error"] == "pool_unavailable"
        assert r["route"] == "pool:flash"
        meta = r.get("metadata") or {}
        ps = meta.get("pool_summary") or {}
        assert ps.get("attempt_count") == len(calls) and ps["attempt_count"] >= 1
        assert ps.get("outcome") == "pool_unavailable"


# ── 尝试摘要回读 ──

class TestAttemptSummaryRoundtrip:

    def _run(self, tmp_env, monkeypatch, results, cands=None):
        pm = make_pm(tmp_env, pools=[local_pool("flash", cands=cands)])
        seq = list(results)

        def fake_transport(handler, pm_, data, *, model, pool, cand, remaining=None):
            res = seq.pop(0)
            if res is not None and res.route is None:
                res.route = f"pool:{pool}/local:{cand.candidate.model_name}"
            return res

        monkeypatch.setattr(dispatch, "_attempt_local_openai", fake_transport)
        h = FakeHandler()
        assert dispatch.handle_pool_chat(h, pm, {}, "fabric-flash") is True
        rs = rows(tmp_env, pm)
        assert len(rs) == 1
        return rs[0]

    def test_same_target_retry(self, tmp_env, monkeypatch):
        ok = AttemptResult(ok=True, committed=True, status=200,
                           usage={"prompt_tokens": 5, "completion_tokens": 7},
                           ttft_ms=100.0)
        fail = AttemptResult(ok=False, committed=False, status=502,
                             error="upstream 502")
        r = self._run(tmp_env, monkeypatch, [fail, ok])
        assert r["status"] == 200
        ps = r["metadata"]["pool_summary"]
        assert ps["attempt_count"] == 2
        assert ps["retry_count"] == 1
        assert ps["fallback_count"] == 0
        assert ps["final_target"]["candidate_id"] == "c1"
        assert ps["requested_model"] == "fabric-flash"
        assert ps["config_revision"] == 7
        assert len(ps["attempts"]) == 2

    def test_fallback_to_second_candidate(self, tmp_env, monkeypatch):
        c2 = CandidateConfig(id="c2", priority=20, kind="local",
                             model_name="qwen3-4b",
                             declared_protocols=("openai",))
        ok = AttemptResult(ok=True, committed=True, status=200,
                           usage={"prompt_tokens": 5, "completion_tokens": 7})
        fail = AttemptResult(ok=False, committed=False, status=401,
                             error="auth")
        r = self._run(tmp_env, monkeypatch, [fail, ok],
                      cands=[CandidateConfig(
                          id="c1", priority=10, kind="local",
                          model_name="qwen3-4b",
                          declared_protocols=("openai",)), c2])
        ps = r["metadata"]["pool_summary"]
        assert ps["attempt_count"] == 2
        assert ps["retry_count"] == 0
        assert ps["fallback_count"] == 1
        assert ps["final_target"]["candidate_id"] == "c2"
        assert ps["first_attempted"]["candidate_id"] == "c1"

    def test_admission_failure_not_counted(self, tmp_env, monkeypatch):
        c2 = CandidateConfig(id="c2", priority=20, kind="local",
                             model_name="qwen3-4b",
                             declared_protocols=("openai",))
        ok = AttemptResult(ok=True, committed=True, status=200,
                           usage={"prompt_tokens": 5, "completion_tokens": 7})
        not_admitted = AttemptResult(ok=False, committed=False,
                                     admitted=False, error="gate_timeout")
        r = self._run(tmp_env, monkeypatch, [not_admitted, ok],
                      cands=[CandidateConfig(
                          id="c1", priority=10, kind="local",
                          model_name="qwen3-4b",
                          declared_protocols=("openai",)), c2])
        ps = r["metadata"]["pool_summary"]
        assert ps["attempt_count"] == 1  # 准入拒绝不计 attempt
        assert ps["retry_count"] == 0 and ps["fallback_count"] == 0
        # 准入失败仍留痕于 attempts 列表（admitted=false）
        assert any(a["admitted"] is False for a in ps["attempts"])

    def test_legacy_row_metadata_unknown(self, tmp_env):
        # 旧调用方直接插入（无 metadata 键）→ 回读保持未知，不补造
        pm = make_pm(tmp_env, pools=[local_pool("flash")])
        pm.logger._db.insert_request_log([{
            "req_id": "legacy-1", "key_name": "k", "model": "m",
            "status": 200, "tokens_in": 1, "tokens_out": 1,
            "duration_ms": 5.0, "route": "local", "timestamp": time.time(),
            "ts": "",
        }])
        rs = rows(tmp_env, pm)
        assert len(rs) == 1
        meta = rs[0].get("metadata")
        assert not meta  # {} / None 均视为未知
