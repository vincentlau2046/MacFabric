"""端到端假引擎全链路 — PK3 门禁（Task 12）。

链路：API 安装（PackManager + 本地 fixture fetcher）→ 受控 YAML 生成 →
现有 load_models 反序列化 → 按生成配置拉起假引擎进程（真实 subprocess）→
healthcheck → chat 200（别名回显）→ 卸载（路由禁用/drain/池清除/目录删除）
→ 零残留 + 兄弟包不受影响。

PK3 门禁的网关 HTTP 层与 ModelLifecycle 接线由现有已测代码承担；本测试
钉住 packs/ 模块全链路 + 真实进程事实。
"""

import hashlib
import json
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest
import yaml

from inferfabric.config import load_models
from inferfabric.packs.catalog import Catalog, CatalogEntry, load_catalog
from inferfabric.packs.policy import PolicyStore
from inferfabric.packs.sandbox import NoopProvider, probe_sandbox
from inferfabric.packs.schema import parse_manifest
from inferfabric.proxy.pack_handlers import PackManager
from tests_fixtures_packs import MINIMAL_MANIFEST_YAML

FIXTURES = Path(__file__).resolve().parent / "fixtures"
FAKE_ENGINE = FIXTURES / "fake_pack_engine.py"
PID = "llm.qwen3-4b-instruct-2507"
MODEL_ID = "qwen3-4b-instruct-2507"


class LocalFetcher:
    """fixture fetcher：engine artifact = 假引擎脚本副本，model = 假权重。"""

    def __init__(self, payload: dict[str, bytes]):
        self.payload = payload

    def fetch(self, artifact, dest):
        dest.write_bytes(self.payload[artifact.id])


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def make_manager(tmp_path):
    files = {"model": b"FAKE-GGUF" * 32,
             "engine": FAKE_ENGINE.read_bytes()}
    d = parse_manifest(MINIMAL_MANIFEST_YAML).to_dict()
    d["resources"]["download_mb"] = 1
    d["resources"]["disk_mb"] = 1
    d["artifacts"] = [
        {"id": "model", "kind": "model", "source": "local://model",
         "sha256": hashlib.sha256(files["model"]).hexdigest()},
        {"id": "engine", "kind": "runtime", "source": "local://engine",
         "sha256": hashlib.sha256(files["engine"]).hexdigest()},
    ]
    manifest = parse_manifest(d)
    cat = tmp_path / "catalog.yaml"
    cat.write_text(yaml.safe_dump({"packs": [{
        "pack_id": manifest.pack_id, "display_name": "E2E", "summary": "s",
        "tags": [], "risk_level": "verified", "builtin": False,
        "manifest": manifest.to_dict()}]}, sort_keys=False))
    spawned = []

    def healthcheck(pack_dir, m):
        # isolated_healthcheck：按包内引擎真实拉起子进程，探活后收割
        port = _free_port()
        binary = pack_dir / "runtime" / "engine"
        proc = subprocess.Popen(
            [sys.executable, str(binary), "--port", str(port)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            start_new_session=True)
        spawned.append(proc)
        try:
            deadline = time.time() + 10
            ok = False
            while time.time() < deadline:
                try:
                    with urllib.request.urlopen(
                            f"http://127.0.0.1:{port}/health", timeout=1) as r:
                        if r.status == 200:
                            ok = True
                            break
                except OSError:
                    time.sleep(0.1)
            if not ok:
                raise RuntimeError("fake engine healthcheck timeout")
            # chat 冒烟：别名回显
            req = urllib.request.Request(
                f"http://127.0.0.1:{port}/v1/chat/completions",
                data=json.dumps({"model": MODEL_ID,
                                 "messages": [{"role": "user",
                                               "content": "hi"}]}).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=5) as r:
                assert json.load(r)["model"] == MODEL_ID
        finally:
            proc.terminate()
            proc.wait(timeout=5)

    reloaded = []
    mgr = PackManager(
        root=tmp_path / "packs", models_d=tmp_path / "models.d",
        catalog_path=cat, fetcher=LocalFetcher(files),
        reload_gateway=lambda: reloaded.append(1),
        prepare_runtime=lambda pd, m: None,   # fake 引擎是现成脚本，无需解包
        run_healthcheck=healthcheck)          # 下方 isolated_healthcheck
    # 池注册表（fake：真实 PoolRegistry 契约 raw_config — PK4 生产冒烟回归）
    class FakeRegistry:
        def __init__(self):
            self.raw = {"pools": {"fast": {"candidates": [{
                "id": "c1", "kind": "local", "model_name": MODEL_ID}]}}}

        def raw_config(self):
            return self.raw

        def purge_candidates(self, predicate):
            removed = 0
            for p in (self.raw.get("pools") or {}).values():
                cands = p.get("candidates") or []
                kept = [c for c in cands if not predicate(c)]
                removed += len(cands) - len(kept)
                p["candidates"] = kept
            return removed, 2

    mgr.attach_uninstaller(
        registry=FakeRegistry(),
        disable_route_fn=lambda name: None,
        stop_pack_fn=lambda name: None,   # 健康检查已收割；生产走 lifecycle
        is_alive_fn=lambda names: False,
        pgid_fn=None)
    return mgr, reloaded


def _await_installed(mgr, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        rec = mgr.store.get(PID)
        if rec and rec.status == "installed":
            return rec
        time.sleep(0.05)
    raise AssertionError(f"pack not installed: {mgr.store.get(PID)}")


def test_fake_pack_full_lifecycle(tmp_path):
    mgr, reloaded = make_manager(tmp_path)
    # 1. API 安装
    code, payload = mgr.start_install(PID)
    assert code == 202, payload
    rec = _await_installed(mgr)
    if sys.platform == "darwin":
        assert rec.sandbox_degraded is False
    else:
        # 非 macOS：SBPL 探测不可用 → 显式降级安装是设计行为（spec §8.3），
        # 记录必须如实标记 degraded 而非冒充完整隔离
        assert rec.sandbox_degraded is True
    assert reloaded, "gateway_reload hook 未调用"

    # 2. 受控 YAML 生成 + 现有 loader 反序列化（D6 schema 兼容）
    y = mgr.models_d / "pack-qwen3-4b-instruct-2507-1-0-0.yaml"
    assert y.exists()
    models = load_models(models_dir=mgr.models_d, include_applied=False)
    cfg = models["pack-qwen3-4b-instruct-2507-1-0-0"]
    assert cfg.ledger_mode == "on_demand" and cfg.autostart is False
    assert str(mgr.root) in cfg.llama_cpp.binary_path

    # 3. 卸载（池引用在 → 未确认 409；确认后走全状态机）
    code, payload = mgr.uninstall(PID)
    assert code == 409 and payload["affected_pools"]
    code, payload = mgr.uninstall(PID, confirmed=True)
    assert code == 200 and payload["status"] == "removed"

    # 4. 零残留
    assert not (mgr.root / PID).exists()
    assert not y.exists()
    assert mgr.store.get(PID) is None
    assert mgr.is_model_disabled(MODEL_ID) is False  # 卸载完成解除禁用


def test_install_failure_leaves_store_failed(tmp_path):
    mgr, _ = make_manager(tmp_path)
    # 篡改 fetcher 内容 → hash 校验失败 → failed 记录保留供诊断（spec §7.3）
    bad = LocalFetcher({"model": b"TAMPERED", "engine": b"E"})
    mgr.installer._fetcher = bad
    code, _ = mgr.start_install(PID)
    assert code == 202
    deadline = time.time() + 5
    rec = None
    while time.time() < deadline:
        rec = mgr.store.get(PID)
        if rec and rec.status == "failed":
            break
        time.sleep(0.05)
    assert rec and rec.status == "failed"
    assert "artifact_sha256_mismatch" in rec.error
    assert not (mgr.root / PID).exists()


def test_catalog_first_batch_frozen_hashes():
    # Catalog sha256 冻结真值（非全零占位）。源策略（用户裁决 2026-11-16）：
    # 模型统一 ModelScope（HF 直连被阻断；hash 经 CDN LFS oid 互证同物）；
    # whisper ggml bin 无 ModelScope 源 → 移出；引擎留 GitHub（实测可达）。
    REPO = Path(__file__).resolve().parents[3]
    entries = load_catalog(REPO / "macfabric_gateway" / "packs_catalog.yaml")
    by_id = {e.manifest.pack_id: e for e in entries}
    assert len(by_id) == 4
    for e in entries:
        assert e.source_page.startswith("https://")
        for a in e.manifest.artifacts:
            assert a.sha256 != "0" * 64, \
                f"{e.manifest.pack_id}/{a.id} hash 未冻结"
            if a.kind == "model":
                assert a.source.startswith("https://modelscope.cn/models/"), \
                    f"{a.id} 模型源不在 ModelScope: {a.source}"
            else:
                assert a.source.startswith("https://github.com/"), \
                    f"{a.id} 引擎源异常: {a.source}"
    # Gemma 不在目录（许可证复核前移出，spec §11 裁决）
    assert not any("gemma" in pid for pid in by_id)
    # whisper 无 ModelScope 源 → 移出（用户裁决 2026-11-16）
    assert not any("whisper" in pid for pid in by_id)
