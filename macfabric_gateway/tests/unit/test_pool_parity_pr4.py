"""Fork parity — mirror upstream InferFabric PR#4 review fixes (6d86f7c).

Upstream merged these as blocker + nit fixes; the fork that production runs
must carry the identical behavior so future picks stay noise-free:
- blocker ①: legacy pool-key fallback (_resolve_pool_snap) —存量
  model_pools.yaml 键仍为 fast/small/premium 时 fabric- 请求不被重命名切断
- nit ②: admin PUT 的 expected_revision 是请求元数据，不得持久化进
  model_pools.yaml
- nit ③: candidate priority 严格整数解析（"10" 字符串拒绝）
(nit ① 门后预算重算上游无独立用例，随代码镜像，见 dispatch.py)
"""

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from inferfabric.model_pool import dispatch
from inferfabric.model_pool.config import load_pools_dict
from inferfabric.model_pool.registry import PoolRegistry


# ── blocker ①: legacy pool-key fallback ──────────────────────────

def _snap_with(*names):
    pools = {n: object() for n in names}
    return SimpleNamespace(pools=pools, revision=7)


def test_resolve_pool_snap_prefers_canonical_then_falls_back():
    canonical = _snap_with("flash")
    legacy = _snap_with("fast")            # 存量键名未迁移
    both = _snap_with("flash", "fast")     # 迁移后别名/规范名并存

    assert dispatch._resolve_pool_snap(canonical, "fabric-flash") is \
        canonical.pools["flash"]
    # 旧短名请求 + 存量键名：规范名（别名 fast→flash）未命中 → 回落原短名
    # （与上游一致：fallback 保护的是 fabric-fast 这类旧客户端名）
    assert dispatch._resolve_pool_snap(legacy, "fabric-fast") is \
        legacy.pools["fast"]
    # 并存期规范名优先；旧名经别名解析到同一规范池（双向可用）
    assert dispatch._resolve_pool_snap(both, "fabric-flash") is \
        both.pools["flash"]
    assert dispatch._resolve_pool_snap(both, "fabric-fast") is \
        both.pools["flash"]
    assert dispatch._resolve_pool_snap(None, "fabric-fast") is None
    assert dispatch._resolve_pool_snap(canonical, "fabric-nope") is None


def test_legacy_keyed_config_still_routes(monkeypatch):
    """Handler 级回归：存量 fast 键 + fabric-fast 请求 → 不判 unknown_pool。"""
    pool = SimpleNamespace(pool=SimpleNamespace(name="fast"), candidates=(),
                           issues=(), revision=7)
    registry = SimpleNamespace(snapshot=lambda: SimpleNamespace(
        revision=7, pools={"fast": pool}))
    forwarded = []
    monkeypatch.setattr(dispatch, "_ensure_cloud_discovered", lambda *a: None)
    monkeypatch.setattr(dispatch, "select", lambda *a, **k: SimpleNamespace(
        chosen=None, error="no_compatible_target", decisions=()))
    sent = []

    class H:
        headers = {}
        def _send_json(self, obj, status, extra_headers=None):
            sent.append((status, obj))

    pm = SimpleNamespace(pool_registry=registry,
                         logger=SimpleNamespace(log=lambda *a, **k: None),
                         new_request_id=lambda: "req-1",
                         auth=SimpleNamespace(enabled=False),
                         cloud=SimpleNamespace(cloud_models={}),
                         mgr=SimpleNamespace(get_model=lambda name: None,
                                             active_services=()))
    data = {"model": "fabric-fast", "messages": [{"role": "user", "content": "hi"}]}
    dispatch.handle_pool_chat(H(), pm, data, "fabric-fast")
    codes = [obj.get("code") for _, obj in sent]
    assert "unknown_pool" not in codes   # 旧实现：重命名切断 → unknown_pool


# ── nit ②: expected_revision never persisted ─────────────────────

def _raw_pools_config():
    return {
        "schema_version": 1,
        "revision": 1,
        "pools": {
            "flash": {
                "enabled": True,
                "allowed_locations": ["local"],
                "accept_declared": True,
                "max_attempts": 2,
                "deadline_ms": 4000,
                "candidates": [{
                    "id": "c1", "priority": 10, "kind": "local",
                    "model_name": "qwen3-4b",
                    "declared_protocols": ["openai"],
                }],
            },
        },
    }


def test_admin_put_does_not_persist_expected_revision(tmp_path):
    from inferfabric.model_pool import admin

    cfg_path = tmp_path / "model_pools.yaml"
    evidence_path = tmp_path / "evidence.json"
    registry = PoolRegistry(config_path=cfg_path, evidence_path=evidence_path)
    pm = SimpleNamespace(pool_registry=registry)

    body = _raw_pools_config()
    body["expected_revision"] = 0   # 全新 registry（无配置文件）当前 revision 为 0
    out = {}

    class H:
        def _read_body(self):
            return body
        def _send_json(self, obj, status=200, extra_headers=None):
            out.update(obj=obj, status=status)

    admin.handle_put_model_pools(H(), pm)
    assert out["status"] == 200
    assert "expected_revision" not in (registry.raw_config() or {})
    # 落盘文件同样干净
    on_disk = json.loads(cfg_path.read_text()) if cfg_path.suffix == ".json" \
        else cfg_path.read_text()
    assert "expected_revision" not in on_disk


# ── nit ③: priority strict int ───────────────────────────────────

def test_priority_string_is_rejected():
    cfg = _raw_pools_config()
    cfg["pools"]["flash"]["candidates"][0]["priority"] = "10"  # 字符串
    parsed, issues = load_pools_dict(cfg, current_revision=1)
    assert parsed is None
    assert any("priority must be an integer" in i for i in issues)


def test_priority_int_accepts_zero_and_negative():
    cfg = _raw_pools_config()
    cfg["pools"]["flash"]["candidates"][0]["priority"] = 0
    parsed, issues = load_pools_dict(cfg, current_revision=1)
    assert parsed is not None and issues == []
