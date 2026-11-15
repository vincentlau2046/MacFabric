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
