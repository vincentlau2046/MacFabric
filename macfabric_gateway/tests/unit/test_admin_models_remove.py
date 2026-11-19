"""POST /admin/models/remove — dashboard iff remove 入口的 handler 薄封装。

契约（与 peer 对齐的 schema + 映射细化，上游 issue #8 item 1）：
- 请求 {name, confirmed?, purge_pools?}；预览与执行各调一次 remove_model
  （服务端重算，绝不缓存预览报告）。
- 预览态（无 confirmed）永远 200：报告原样透传，would-remove/blocked/error
  由 body 区分——blocked 是预览结果不是 HTTP 错误。
- 执行态（confirmed:true）：
  - status "removed" → 200 + mgr.reload_models()；
  - status "blocked"（预览后池引用变化的竞态）→ 409 + pool_refs，客户端
    回预览重走，不自动重试；
  - unknown model → 404；PoolsConfigError（fail-closed）→ 400；
  - 其余执行失败（stop 失败/purge 失败，status "error" 带 actions）→ 500 带报告；
- purge_pools 布尔透传（预览报告出现 would-purge-pool-candidates 动作）。

repo 无 aiohttp 测试夹具（Ruling，同 test_packs_api.py）：handler 方法只依赖
self._read_body/_send_json —— 假 self 函数级直测接线 + 路由表注册断言。
remove_model 本体语义由 test_uninstaller.py 钉住，此处只测接线。
"""

import types

import yaml

from inferfabric.proxy.handler import _POST_ROUTES, ProxyHandler


# ── 构造替身（镜像 test_uninstaller.py 的 _NS/_model_env）────────

class _NS:
    def __init__(self, **kw):
        self.__dict__.update(kw)


def _model_env(tmp_path):
    models = {"m1": _NS(served_name="fabric-m1",
                        vllm=_NS(conda_env="v-1", model_dir="Qwen3"))}
    mdir = tmp_path / "models.d"
    mdir.mkdir()
    (mdir / "m1.yaml").write_text("name: m1\ntype: vllm\n")
    return models, mdir


def _write_pools(path):
    path.write_text(yaml.safe_dump({
        "schema_version": 1, "revision": 4,
        "pools": {
            "fast": {"allowed_locations": ["local"], "candidates": [
                {"id": "a", "priority": 10, "kind": "local", "model_name": "m1"},
            ]},
        }}))
    return path


class _FakeMgr:
    """只暴露 handler 接线用到的面：_models/stop_service/active_services/reload_models。"""

    def __init__(self, models, active=(), stop_result=None):
        self._models = models
        self.active_services = list(active)     # handler 只做 `name in ...`
        self._stop_result = stop_result or {"status": "stopped"}
        self.stop_calls = []
        self.reload_calls = 0

    def stop_service(self, name):
        self.stop_calls.append(name)
        return dict(self._stop_result)

    def reload_models(self):
        self.reload_calls += 1


def _call(body, mgr):
    """以假 self 直调 _handle_models_remove；返回 [(obj, code)]。"""
    sent = []

    h = types.SimpleNamespace()
    h._read_body = lambda: body
    h._send_json = lambda obj, code=200: sent.append((obj, code))
    pm = types.SimpleNamespace(mgr=mgr)
    ProxyHandler._handle_models_remove(h, pm)
    return sent


# ── 路由注册 ─────────────────────────────────────────────────────

def test_route_registered():
    assert "/admin/models/remove" in _POST_ROUTES


# ── 接线行为 ─────────────────────────────────────────────────────

def test_missing_name_400(tmp_path, monkeypatch):
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    sent = _call({}, _FakeMgr({}))
    assert sent[0][1] == 400
    assert "name" in sent[0][0]["error"]


def test_preview_unknown_model_200_passthrough(tmp_path, monkeypatch):
    """预览态永远 200：未知模型也是 body 区分，不是 HTTP 错误。"""
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    sent = _call({"name": "ghost"}, _FakeMgr({}))
    obj, code = sent[0]
    assert code == 200
    assert obj["status"] == "error"
    assert "unknown model" in obj["message"]


def test_confirmed_unknown_model_404(tmp_path, monkeypatch):
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    sent = _call({"name": "ghost", "confirmed": True}, _FakeMgr({}))
    assert sent[0][1] == 404
    assert "unknown model" in sent[0][0]["error"]


def test_confirmed_pools_config_error_400(tmp_path, monkeypatch, ):
    """执行态 PoolsConfigError（fail-closed）→ 400；remove_model 通常内化，
    这里 monkeypatch 抛出以钉住防御映射。"""
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    from inferfabric.uninstaller import PoolsConfigError

    def _boom(*a, **k):
        raise PoolsConfigError("pool config unreadable: boom")
    monkeypatch.setattr("inferfabric.uninstaller.remove_model", _boom)
    sent = _call({"name": "m1", "confirmed": True}, _FakeMgr(models))
    obj, code = sent[0]
    assert code == 400
    assert "boom" in obj["error"]


def test_preview_without_confirmed(tmp_path, monkeypatch):
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    mgr = _FakeMgr(models, active=["m1"])
    sent = _call({"name": "m1"}, mgr)          # 无 confirmed → 预览
    obj, code = sent[0]
    assert code == 200
    assert obj["status"] == "would-remove"
    assert mgr.stop_calls == []                # 预览零副作用
    assert mgr.reload_calls == 0
    assert (mdir / "m1.yaml").exists()
    assert any(a["action"] == "would-stop" for a in obj["actions"])


def test_confirmed_removes_and_reloads(tmp_path, monkeypatch):
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    mgr = _FakeMgr(models, active=["m1"])
    sent = _call({"name": "m1", "confirmed": True}, mgr)
    obj, code = sent[0]
    assert code == 200
    assert obj["status"] == "removed"
    assert mgr.stop_calls == ["m1"]
    assert mgr.reload_calls == 1               # YAML 删除后热重载
    assert not (mdir / "m1.yaml").exists()
    assert obj["weights_kept"]                 # 权重只报告不删


def test_served_name_resolved_to_config_name(tmp_path, monkeypatch):
    """请求用 served-name 时，stop_fn/is_running_fn 收解析后的 config 名
    （peer 交叉评审 nit 2：lambda 捕获解析名，不捕获原始输入）。"""
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    mgr = _FakeMgr(models, active=["m1"])
    sent = _call({"name": "fabric-m1", "confirmed": True}, mgr)
    obj, code = sent[0]
    assert code == 200
    assert obj["status"] == "removed"
    assert obj["model"] == "m1"                # 报告用 config 名
    assert mgr.stop_calls == ["m1"]


def test_confirmed_blocked_409_no_side_effect(tmp_path, monkeypatch):
    """执行态 blocked（预览后池引用变化的竞态）→ 409 + pool_refs，不自动重试。"""
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    _write_pools(tmp_path / "model_pools.yaml")
    mgr = _FakeMgr(models)
    sent = _call({"name": "m1", "confirmed": True}, mgr)
    obj, code = sent[0]
    assert code == 409
    assert obj["status"] == "blocked"
    assert obj["pool_refs"]
    assert (mdir / "m1.yaml").exists()         # blocked 不动配置
    assert mgr.reload_calls == 0


def test_purge_pools_flag_passthrough(tmp_path, monkeypatch):
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    _write_pools(tmp_path / "model_pools.yaml")
    mgr = _FakeMgr(models)
    sent = _call({"name": "m1", "purge_pools": True}, mgr)   # 预览 + purge 意图
    obj, code = sent[0]
    assert obj["status"] == "would-remove"
    assert any(a["action"] == "would-purge-pool-candidates" for a in obj["actions"])


def test_confirmed_stop_failure_500_with_report(tmp_path, monkeypatch):
    """执行失败（stop 失败，status error 带 actions）→ 500 带报告。"""
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    mgr = _FakeMgr(models, active=["m1"],
                   stop_result={"status": "error", "message": "boom"})
    sent = _call({"name": "m1", "confirmed": True}, mgr)
    obj, code = sent[0]
    assert code == 500
    assert obj["status"] == "error"
    assert "stop failed" in obj["message"]
    assert mgr.reload_calls == 0
    assert (mdir / "m1.yaml").exists()         # 停止失败不删配置


def test_preview_pool_gate_error_200_passthrough(tmp_path, monkeypatch):
    """预览态池引用门不可用（status error）→ 200 透传，由 body 区分。"""
    monkeypatch.setattr("inferfabric.config.IFF_DATA_DIR", tmp_path)
    monkeypatch.setattr("inferfabric.config.MODELS_DIR", tmp_path / "models.d")
    models, mdir = _model_env(tmp_path)
    (tmp_path / "model_pools.yaml").write_text("- a\n- b\n", encoding="utf-8")
    sent = _call({"name": "m1"}, _FakeMgr(models))
    obj, code = sent[0]
    assert code == 200
    assert obj["status"] == "error"
