"""用户扩展能力包（custom packs）— 统一架构裁决 2026-11-16。

用户只提交 下载链接 + 名称 + 能力类型；网关校验链：
https URL → 下载（断点续传 fetcher）→ sha256（可选）→ GGUF 魔数 →
磁盘门禁 → 真引擎隔离试加载 → 注册 custom.<name>（真 Manifest：
catalog 合并/卸载/重试全走既有链路）。
"""
import hashlib
import threading
import time
from pathlib import Path

import pytest
import yaml

from inferfabric.packs.custom import (
    validate_gguf, validate_custom_body, build_custom_manifest)
from inferfabric.packs.schema import parse_manifest
from inferfabric.proxy import pack_handlers

GGUF = b"GGUF" + b"\x00" * 1024
GGUF_SHA = hashlib.sha256(GGUF).hexdigest()


class UrlFetcher:
    """假 fetcher：把预置内容写入 dest（模拟下载）。"""

    def __init__(self, content=GGUF):
        self.content = content
        self.calls = []

    def fetch(self, artifact, dest):
        self.calls.append(artifact.source)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(self.content)


def make_mgr(tmp_path, fetcher):
    cat = tmp_path / "catalog.yaml"
    cat.write_text(yaml.safe_dump({"packs": []}, sort_keys=False))
    mgr = pack_handlers.PackManager(
        root=tmp_path / "packs", models_d=tmp_path / "models.d",
        catalog_path=cat, fetcher=fetcher, reload_gateway=lambda: None,
        prepare_runtime=lambda pd, m: None,
        run_healthcheck=lambda pd, m: None)
    # 预置一个已装的 llama.cpp 引擎（自定义包复用真引擎试加载）
    eng = mgr.root / "llm.qwen3" / "1.0.0" / "runtime" / "engine"
    eng.parent.mkdir(parents=True)
    eng.write_bytes(b"#!/bin/sh\n")
    eng.chmod(0o755)
    return mgr


def wait_status(mgr, pack_id, want="installed", timeout=5.0):
    deadline = time.time() + timeout
    rec = None
    while time.time() < deadline:
        rec = next((r for r in mgr.status_payload()["packs"]
                    if r["pack_id"] == pack_id), None)
        if rec is not None and rec["status"] == want:
            return rec
        time.sleep(0.02)
    return rec


# ── 校验原语 ──

def test_validate_gguf_magic(tmp_path):
    ok = tmp_path / "a.gguf"
    ok.write_bytes(GGUF)
    validate_gguf(ok)                      # 不抛
    bad = tmp_path / "b.gguf"
    bad.write_bytes(b"NOTG" + b"\x00" * 16)
    with pytest.raises(ValueError, match="not_gguf_format"):
        validate_gguf(bad)


def test_validate_custom_body_rules():
    n, url, cap, sha = validate_custom_body(
        {"name": "my-model", "url": "https://x.cn/a.gguf",
         "capability": "llm"})
    assert (n, cap) == ("my-model", "llm")
    for body in (
        {"name": "AB", "url": "https://x.cn/a.gguf", "capability": "llm"},
        {"name": "ok-name", "url": "http://x.cn/a.gguf", "capability": "llm"},
        {"name": "ok-name", "url": "https://x.cn/a.gguf", "capability": "tts"},
        {"url": "https://x.cn/a.gguf", "capability": "llm"},
        {"name": "ok-name", "capability": "llm"},
    ):
        with pytest.raises(ValueError):
            validate_custom_body(body)


def test_build_custom_manifest_is_real_manifest():
    m = build_custom_manifest("my-model", "embedding",
                              "https://x.cn/a.gguf", GGUF_SHA, 1)
    assert isinstance(m, parse_manifest(m.to_dict()).__class__)
    assert m.pack_id == "embedding.my-model"
    assert m.model_config_template == "llama_cpp_chat_v1"
    assert m.artifacts[0].source == "https://x.cn/a.gguf"


# ── 安装链路 ──

def test_custom_install_happy_path(tmp_path):
    f = UrlFetcher()
    mgr = make_mgr(tmp_path, f)
    code, payload = mgr.start_custom_install(
        {"name": "my-model", "url": "https://x.cn/a.gguf",
         "capability": "embedding", "sha256": GGUF_SHA})
    assert code == 202, payload
    rec = wait_status(mgr, "embedding.my-model")
    assert rec is not None and rec["status"] == "installed", rec

    # 受控 YAML（managed_by_pack + embedding 配置）
    y = mgr.models_d / "pack-my-model-1-0-0.yaml"
    d = yaml.safe_load(y.read_text())
    assert d["managed_by_pack"]["pack_id"] == "embedding.my-model"
    assert d["model_type"] == "embedding"

    # 注册表持久化 + catalog 合并 + manifest 可解析
    reg = mgr._custom.get("embedding.my-model")
    assert reg["url"] == "https://x.cn/a.gguf"
    assert reg["sha256"] == GGUF_SHA
    assert any(p["pack_id"] == "embedding.my-model" and p.get("user_custom")
               for p in mgr.catalog_payload()["packs"])
    assert mgr._manifest_for("embedding.my-model") is not None
    # 下载走了用户 URL
    assert f.calls == ["https://x.cn/a.gguf"]


def test_custom_install_rejects_non_gguf(tmp_path):
    mgr = make_mgr(tmp_path, UrlFetcher(b"JUNKJUNKJUNK"))
    mgr.start_custom_install({"name": "bad", "url": "https://x.cn/a.bin",
                              "capability": "llm"})
    rec = wait_status(mgr, "llm.bad", want="failed")
    assert rec is not None and "not_gguf_format" in (rec["error"] or "")
    # 零残留：包目录不落盘
    assert not (mgr.root / "llm.bad").exists()


def test_custom_install_sha256_mismatch_fails(tmp_path):
    mgr = make_mgr(tmp_path, UrlFetcher())
    mgr.start_custom_install({"name": "mmm", "url": "https://x.cn/a.gguf",
                              "capability": "llm", "sha256": "0" * 64})
    rec = wait_status(mgr, "llm.mmm", want="failed")
    assert "sha256" in (rec["error"] or "")


def test_custom_install_duplicate_and_bad_body(tmp_path):
    mgr = make_mgr(tmp_path, UrlFetcher())
    code, _ = mgr.start_custom_install({"name": "dup", "url": "https://x.cn/a",
                                        "capability": "llm"})
    assert code == 202
    assert wait_status(mgr, "llm.dup") is not None
    code, payload = mgr.start_custom_install({"name": "dup",
                                              "url": "https://x.cn/b",
                                              "capability": "llm"})
    assert code == 409
    code, payload = mgr.start_custom_install({"name": "dup!",
                                              "url": "https://x.cn/a",
                                              "capability": "llm"})
    assert code == 400


def test_custom_failed_entry_allows_resubmit_with_fixed_url(tmp_path):
    # 沙箱取证（2026-11-16）：校验链失败的包（manifest 未建）既不能卸载也
    # 不能重装 → 死锁。契约：失败残留允许改 URL/参数后直接覆盖重装。
    mgr = make_mgr(tmp_path, UrlFetcher(b"JUNK"))
    mgr.start_custom_install({"name": "fixup", "url": "https://x.cn/bad",
                              "capability": "llm"})
    assert wait_status(mgr, "llm.fixup", want="failed") is not None
    mgr._fetcher = UrlFetcher()          # "修复下载源"：换为合法 GGUF 内容
    code, payload = mgr.start_custom_install(
        {"name": "fixup", "url": "https://x.cn/fixed.gguf",
         "capability": "llm", "sha256": GGUF_SHA})
    assert code == 202, payload
    rec = wait_status(mgr, "llm.fixup")
    assert rec is not None and rec["status"] == "installed", rec
    assert mgr._custom.get("llm.fixup")["url"] == "https://x.cn/fixed.gguf"


def test_custom_install_needs_engine(tmp_path):
    cat = tmp_path / "catalog.yaml"
    cat.write_text(yaml.safe_dump({"packs": []}))
    mgr = pack_handlers.PackManager(
        root=tmp_path / "packs2", models_d=tmp_path / "m2",
        catalog_path=cat, fetcher=UrlFetcher(), reload_gateway=lambda: None,
        prepare_runtime=lambda pd, m: None,
        run_healthcheck=lambda pd, m: None)
    code, payload = mgr.start_custom_install({"name": "noeng",
                                              "url": "https://x.cn/a",
                                              "capability": "llm"})
    assert code == 400 and "no_llama_cpp_engine" in payload["error"]


def test_custom_retry_via_start_install(tmp_path):
    # 失败后用户在能力包卡点"重试"→ start_install 从注册表重启下载
    mgr = make_mgr(tmp_path, UrlFetcher(b"JUNK"))
    mgr.start_custom_install({"name": "retry", "url": "https://x.cn/a",
                              "capability": "llm"})
    assert wait_status(mgr, "llm.retry", want="failed") is not None
    mgr._fetcher = UrlFetcher()          # 换好 fetcher 模拟网络恢复
    code, _ = mgr.start_install("llm.retry")
    assert code == 202
    assert wait_status(mgr, "llm.retry") is not None


def test_custom_uninstall_removes_registry_and_files(tmp_path):
    mgr = make_mgr(tmp_path, UrlFetcher())
    mgr.start_custom_install({"name": "gone", "url": "https://x.cn/a",
                              "capability": "llm"})
    assert wait_status(mgr, "llm.gone") is not None
    mgr.attach_uninstaller(
        registry=None, disable_route_fn=lambda n: None,
        stop_pack_fn=lambda n: None, is_alive_fn=lambda names: False,
        pgid_fn=None, reload_fn=lambda: None)
    code, payload = mgr.uninstall("llm.gone", confirmed=True)
    assert code == 200, payload
    assert mgr._custom.get("llm.gone") is None
    assert not (mgr.root / "llm.gone").exists()
    assert not (mgr.models_d / "pack-custom-gone-1-0-0.yaml").exists()
    assert mgr._manifest_for("llm.gone") is None
