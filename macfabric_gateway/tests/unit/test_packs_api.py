"""admin API — catalog/status/install/policy — PK1（Task 8）。

契约（计划 Interfaces）：
- PackManager 门面（pack_handlers.py）：catalog_payload/status_payload/
  start_install/policy_get/policy_put。
- HTTP 契约（handler 薄委托）：
  GET  /admin/packs/catalog → {"packs":[...]}
  GET  /admin/packs/status  → {"packs":[PackRecord...]}（含进行中事务）
  POST /admin/packs/install {"pack_id"} → 202 进行中 / 409 互斥 / 404 未知
  GET/PUT /admin/packs/policy（越界 400：参数 <1，保留内存出 [1024,65536]）
- 旧 /admin/packs/download 原样保留（用户导入模型路径）。
- repo 无 aiohttp 测试夹具（Ruling）：门面层函数级测试 + 路由表注册断言。
"""

import threading
import time
from pathlib import Path

import pytest

from inferfabric.packs.catalog import load_catalog
from inferfabric.proxy import pack_handlers

REPO = Path(__file__).resolve().parents[3]


class SlowFetcher:
    """慢速 fetcher：制造进行中事务窗口。"""

    def __init__(self, files, delay=0.3):
        self.files = files
        self.delay = delay

    def fetch(self, artifact, dest):
        time.sleep(self.delay)
        dest.write_bytes(self.files[artifact.id])


@pytest.fixture()
def mgr(tmp_path):
    from tests_fixtures_packs import MINIMAL_MANIFEST_YAML
    from inferfabric.packs.schema import parse_manifest
    import hashlib
    m = parse_manifest(MINIMAL_MANIFEST_YAML).to_dict()
    m["resources"]["download_mb"] = 1
    m["resources"]["disk_mb"] = 1
    files = {"model": b"M" * 128, "engine": b"E" * 64}
    arts = []
    for i, aid in enumerate(files):
        a = parse_manifest(MINIMAL_MANIFEST_YAML).artifacts[i]
        arts.append({"id": aid, "kind": a.kind, "source": f"https://x/{aid}",
                     "sha256": hashlib.sha256(files[aid]).hexdigest()})
    m["artifacts"] = arts
    from inferfabric.packs.catalog import Catalog, CatalogEntry
    manifest = parse_manifest(m)
    cat_path = tmp_path / "catalog.yaml"
    import yaml
    cat_path.write_text(yaml.safe_dump({"packs": [{
        "pack_id": manifest.pack_id, "display_name": "T", "summary": "s",
        "tags": [], "risk_level": "verified", "builtin": False,
        "manifest": m}]}, sort_keys=False))
    pmgr = pack_handlers.PackManager(
        root=tmp_path / "packs", models_d=tmp_path / "models.d",
        catalog_path=cat_path, fetcher=SlowFetcher(files),
        reload_gateway=lambda: None)
    return pmgr


def test_catalog_payload_shape(mgr):
    p = mgr.catalog_payload()
    assert p["packs"][0]["pack_id"] == "llm.qwen3-4b-instruct-2507"
    assert {"pack_id", "display_name", "summary", "tags", "capability",
            "builtin", "risk_level", "manifest"} <= set(p["packs"][0])


def test_install_unknown_pack_404(mgr):
    code, payload = mgr.start_install("nope")
    assert code == 404


def test_install_happy_path_reaches_installed(mgr):
    code, payload = mgr.start_install("llm.qwen3-4b-instruct-2507")
    assert code == 202
    deadline = time.time() + 5
    while time.time() < deadline:
        st = mgr.status_payload()
        rec = next(r for r in st["packs"]
                   if r["pack_id"] == "llm.qwen3-4b-instruct-2507")
        if rec["status"] == "installed":
            break
        time.sleep(0.05)
    assert rec["status"] == "installed"
    # 受控 YAML 已生成
    y = (mgr.models_d / "pack-qwen3-4b-instruct-2507-1-0-0.yaml")
    assert y.exists()


def test_reinstall_of_installed_pack_409(mgr):
    # 终审 F1：已安装包再次 install → 409（失败的重装不得摧毁已装工作包）
    code, _ = mgr.start_install("llm.qwen3-4b-instruct-2507")
    assert code == 202
    deadline = time.time() + 5
    rec = None
    while time.time() < deadline:
        rec = mgr.store.get("llm.qwen3-4b-instruct-2507")
        if rec and rec.status == "installed":
            break
        time.sleep(0.05)
    assert rec and rec.status == "installed"
    code2, _ = mgr.start_install("llm.qwen3-4b-instruct-2507")
    assert code2 == 409
    # 已装状态未被二次请求破坏
    assert mgr.store.get("llm.qwen3-4b-instruct-2507").status == "installed"


def test_bookkeeping_failure_releases_in_progress(mgr, monkeypatch):
    # 终审 F4：store.set 崩溃不得让 pack_id 永久 409
    def broken_set(rec):
        raise OSError("disk io error")

    monkeypatch.setattr(mgr.store, "set", broken_set)
    code, _ = mgr.start_install("llm.qwen3-4b-instruct-2507")
    assert code == 202
    deadline = time.time() + 5
    while time.time() < deadline:
        if "llm.qwen3-4b-instruct-2507" not in mgr._in_progress:
            break
        time.sleep(0.05)
    assert "llm.qwen3-4b-instruct-2507" not in mgr._in_progress
    code2, _ = mgr.start_install("llm.qwen3-4b-instruct-2507")
    assert code2 == 202


def test_concurrent_install_same_pack_409(mgr):
    # Review Focus 4：同 pack_id 事务互斥，后到者 409
    results = []
    mgr._fetcher = SlowFetcher(mgr._fetcher.files, delay=0.4)
    t = threading.Thread(
        target=lambda: results.append(
            mgr.start_install("llm.qwen3-4b-instruct-2507")))
    t.start()
    time.sleep(0.1)   # 让第一个事务进入 downloading
    code, _ = mgr.start_install("llm.qwen3-4b-instruct-2507")
    t.join()
    assert code == 409
    assert results[0][0] == 202


def test_policy_get_put_and_bounds(mgr):
    code, p = mgr.policy_get()
    assert code == 200 and p["max_model_parameters_b"] == 4
    assert p["system_reserved_memory_mb"] == 8192
    code, _ = mgr.policy_put({"max_model_parameters_b": 0})
    assert code == 400
    code, _ = mgr.policy_put({"system_reserved_memory_mb": 100})
    assert code == 400
    code, p = mgr.policy_put({"max_model_parameters_b": 8})
    assert code == 200 and p["max_model_parameters_b"] == 8


def test_policy_bounds_range():
    # 保留内存合法域 [1024, 65536] MiB
    from inferfabric.proxy.pack_handlers import POLICY_MEM_RANGE
    assert POLICY_MEM_RANGE == (1024, 65536)


def test_route_registration_contains_pack_endpoints():
    from inferfabric.proxy.handler import _GET_ROUTES, _POST_ROUTES
    for path in ("/admin/packs/catalog", "/admin/packs/status",
                 "/admin/packs/policy"):
        assert path in _GET_ROUTES, path
    for path in ("/admin/packs/install", "/admin/packs/policy"):
        assert path in _POST_ROUTES, path
    # 旧端点保留（用户导入模型路径）
    assert "/admin/packs/download" in _POST_ROUTES
    assert "/admin/packs/uninstall" in _POST_ROUTES


def test_singleton_defaults_from_env(tmp_path, monkeypatch):
    monkeypatch.setenv("MACFABRIC_STATE_DIR", str(tmp_path / "state"))
    monkeypatch.setenv("MACFABRIC_MODELS_DIR", str(tmp_path / "models.d"))
    pmgr = pack_handlers.get_pack_manager(
        catalog_path=REPO / "macfabric_gateway" / "packs_catalog.yaml")
    assert pmgr.root == tmp_path / "state" / "packs"
    assert pmgr.models_d == tmp_path / "models.d"
    pack_handlers.reset_pack_manager()
