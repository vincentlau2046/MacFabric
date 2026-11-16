"""Manifest → ModelConfig 生成 — PK3（Task 7）。

契约（计划 Interfaces）：
- build_model_config(manifest, pack_dir, port) -> ModelConfig — 模板
  llama_cpp_chat_v1：引擎二进制/模型路径全部指向包内绝对路径（严格一模型
  一环境），ledger_mode 沿 lifecycle.mode 现有语义，autostart=False（安装
  不启动），mem_baseline_mb=peak_memory_mb。
- write_managed_yaml(cfg, models_d, manifest) -> Path — 写受控 YAML，内嵌
  managed_by_pack 标记；同名已存在 → ConfigExistsError。
- name 规则：pack-<capability 后短名>-<version，'.'→'-'。
"""

import pytest
import yaml

from inferfabric.packs.config_gen import (
    ConfigExistsError,
    build_model_config,
    managed_yaml_path,
    pack_model_name,
    write_managed_yaml,
)
from inferfabric.packs.schema import parse_manifest
from tests_fixtures_packs import MINIMAL_MANIFEST_YAML

MANIFEST = parse_manifest(MINIMAL_MANIFEST_YAML)
PACK_DIR = "/Users/x/.inferfabric/packs/llm.qwen3-4b-instruct-2507/1.0.0"


def test_pack_model_name_rule():
    assert pack_model_name(MANIFEST) == "pack-qwen3-4b-instruct-2507-1-0-0"


def test_managed_yaml_path_rule(tmp_path):
    p = managed_yaml_path(tmp_path, MANIFEST)
    assert p.name == "pack-qwen3-4b-instruct-2507-1-0-0.yaml"


def test_llm_template_maps_fields():
    cfg = build_model_config(MANIFEST, PACK_DIR, port=8123)
    assert cfg.type == "llama_cpp"
    assert cfg.model_type == "llm"
    assert cfg.gpu_role == "shared"
    assert cfg.ledger_mode == "on_demand"
    assert cfg.autostart is False                      # 安装不启动（spec §2.1）
    assert cfg.mem_baseline_mb == MANIFEST.peak_memory_mb == 4800
    assert cfg.name == "pack-qwen3-4b-instruct-2507-1-0-0"
    # 模型名规范化走 --alias（ModelConfig 无 served_name 字段，与 qwen3-4b.yaml 同款）
    assert f"--alias {MANIFEST.model_id}" in cfg.llama_cpp.extra_flags
    # 严格一模型一环境：引擎与模型都在包内
    assert PACK_DIR in cfg.llama_cpp.binary_path
    assert PACK_DIR in cfg.llama_cpp.model_path
    assert cfg.llama_cpp.port == 8123
    assert cfg.anthropic_native is True  # llama-server b12361 原生 /v1/messages


def test_capability_identity_mapping():
    text = MINIMAL_MANIFEST_YAML.replace(
        "capability: llm", "capability: embedding").replace(
        "pack_id: llm.", "pack_id: embedding.")
    assert build_model_config(parse_manifest(text), PACK_DIR,
                              port=1).model_type == "embedding"


def test_managed_yaml_markers_and_schema_compat(tmp_path):
    cfg = build_model_config(MANIFEST, PACK_DIR, port=8123)
    path = write_managed_yaml(cfg, models_d=tmp_path, manifest=MANIFEST)
    loaded = yaml.safe_load(path.read_text())
    assert loaded["managed_by_pack"]["pack_id"] == MANIFEST.pack_id
    assert loaded["managed_by_pack"]["pack_version"] == MANIFEST.pack_version
    assert loaded["name"] == cfg.name
    assert loaded["mode"] == "on_demand"          # 现有 loader 消歧 → ledger_mode
    assert loaded["llama_cpp"]["binary_path"].startswith(PACK_DIR)
    # 经现有 load_models 可反序列化（D6 schema 兼容）
    from inferfabric.config import load_models
    models = load_models(models_dir=tmp_path, include_applied=False)
    assert cfg.name in models
    assert models[cfg.name].ledger_mode == "on_demand"


def test_overwrite_rejected(tmp_path):
    cfg = build_model_config(MANIFEST, PACK_DIR, port=8123)
    write_managed_yaml(cfg, tmp_path, MANIFEST)
    with pytest.raises(ConfigExistsError):
        write_managed_yaml(cfg, tmp_path, MANIFEST)


def test_write_managed_yaml_atomic_no_partial_target(tmp_path, monkeypatch):
    # 终审 F2：目标 YAML 只经 .part + os.replace 产生；replace 失败不留半成品
    import inferfabric.packs.config_gen as cg
    cfg = build_model_config(MANIFEST, PACK_DIR, port=8123)

    def boom(a, b):
        raise OSError("disk full")

    monkeypatch.setattr(cg.os, "replace", boom)
    with pytest.raises(OSError):
        write_managed_yaml(cfg, tmp_path, MANIFEST)
    assert not managed_yaml_path(tmp_path, MANIFEST).exists()


def test_unknown_template_rejected():
    d = MANIFEST.to_dict()
    d["execution"]["model_config_template"] = "unknown_v9"
    import pytest as _pytest
    with _pytest.raises(ValueError):
        build_model_config(parse_manifest(d), PACK_DIR, port=1)


def test_pack_model_served_name_routes_by_model_id(tmp_path):
    # 生产取证（2026-11-16 沙箱）：chat qwen3-4b-instruct-2507 → 404
    # unknown_model — ModelConfig.served_name 对 llama_cpp 返回长配置名
    # （pack-…-1-0-0），顶层 served_name 键是装饰性的，--alias 只规范引擎
    # 回显不参与路由。契约：生成的受控 YAML 经 load_models 反序列化后，
    # served_name 必须 == manifest.model_id（proxy 路由名）。
    import yaml as yaml_mod
    from inferfabric.config import load_models
    from inferfabric.packs.config_gen import (
        build_model_config, managed_yaml_path, write_managed_yaml)

    manifest = MANIFEST   # 模块级合法 manifest
    cfg = build_model_config(manifest, tmp_path / "pack" / "1.0.0", 58401)
    write_managed_yaml(cfg, tmp_path / "models.d", manifest)
    y = managed_yaml_path(tmp_path / "models.d", manifest)
    d = yaml_mod.safe_load(y.read_text())
    assert d["llama_cpp"]["served_name"] == manifest.model_id

    models = load_models(models_dir=tmp_path / "models.d",
                         include_applied=False)
    loaded = models[cfg.name]
    assert loaded.served_name == manifest.model_id, \
        f"路由名错误: {loaded.served_name!r} != {manifest.model_id!r}"


def test_managed_pack_config_exposes_pack_origin(tmp_path):
    # 统一架构（2026-11-16 用户裁决）：本地推理 = 已安装能力的运行视图，
    # /models 需暴露 managed_by_pack 让 App 标注"来自能力包 xxx"。
    from inferfabric.config import load_models
    from inferfabric.packs.config_gen import (
        build_model_config, write_managed_yaml)

    manifest = MANIFEST
    cfg = build_model_config(manifest, tmp_path / "pack" / "1.0.0", 58401)
    write_managed_yaml(cfg, tmp_path / "models.d", manifest)
    models = load_models(models_dir=tmp_path / "models.d",
                         include_applied=False)
    loaded = models[cfg.name]
    assert loaded.managed_by_pack == {
        "pack_id": manifest.pack_id, "pack_version": manifest.pack_version}


def test_llama_cpp_served_name_falls_back_to_name(tmp_path):
    # 存量静态配置（无 llama_cpp.served_name）行为不变：回退配置名
    from inferfabric.config import ModelConfig, LlamaCppConfig
    c = ModelConfig(name="qwen3-4b", description="d", type="llama_cpp",
                    llama_cpp=LlamaCppConfig(model_path="/x.gguf"))
    assert c.served_name == "qwen3-4b"
    c2 = ModelConfig(name="pack-x", description="d", type="llama_cpp",
                     llama_cpp=LlamaCppConfig(model_path="/x.gguf",
                                              served_name="x-4b"))
    assert c2.served_name == "x-4b"
