"""能力包 4B/8GB 策略设置项与参数门禁 — PK0（Task 2）。

契约（计划 Interfaces）：
- PackPolicy 默认 max_model_parameters_b=4、system_reserved_memory_mb=8192（MiB）。
- PolicyStore 原子持久化；文件缺失/损坏回默认值，不抛。
- check_param_gate：仅 capability ∈ {llm, vl} 按参数量门禁；其余能力不设参数
  门槛（spec §9 裁决）。放宽即时生效于下一次预检，无自动重装/启动副作用。
"""

import pytest

from inferfabric.packs.policy import PackPolicy, PolicyStore, check_param_gate
from inferfabric.packs.schema import parse_manifest
from tests_fixtures_packs import MINIMAL_MANIFEST_YAML


def make_manifest(capability="llm", parameter_count_b=4):
    text = MINIMAL_MANIFEST_YAML
    text = text.replace("capability: llm", f"capability: {capability}")
    text = text.replace("pack_id: llm.", f"pack_id: {capability}.")
    text = text.replace("parameter_count_b: 4", f"parameter_count_b: {parameter_count_b}")
    return parse_manifest(text)


def test_defaults_are_4b_8192(tmp_path):
    ps = PolicyStore(tmp_path / "policy.json")
    assert ps.load() == PackPolicy(max_model_parameters_b=4,
                                   system_reserved_memory_mb=8192)


def test_save_load_roundtrip(tmp_path):
    ps = PolicyStore(tmp_path / "policy.json")
    ps.save(PackPolicy(max_model_parameters_b=8, system_reserved_memory_mb=6144))
    assert ps.load() == PackPolicy(max_model_parameters_b=8,
                                   system_reserved_memory_mb=6144)


def test_corrupt_file_falls_back_to_defaults(tmp_path):
    p = tmp_path / "policy.json"
    p.write_text("{broken")
    assert PolicyStore(p).load() == PackPolicy()


def test_save_is_atomic_no_part_leftover(tmp_path):
    ps = PolicyStore(tmp_path / "policy.json")
    ps.save(PackPolicy())
    assert list(tmp_path.glob("*.part")) == []
    assert (tmp_path / "policy.json").exists()


def test_param_gate_llm_and_vl_only():
    assert check_param_gate(make_manifest("llm", 8), PackPolicy()) == \
        "parameter_count_b 8 > max 4"
    assert check_param_gate(make_manifest("llm", 4), PackPolicy()) is None
    assert check_param_gate(make_manifest("vl", 8), PackPolicy()) is not None
    # 非对话类不设参数门槛（spec §9）
    assert check_param_gate(make_manifest("asr", 8), PackPolicy()) is None
    assert check_param_gate(make_manifest("ocr", 100), PackPolicy()) is None


def test_policy_change_affects_next_preflight_only(tmp_path):
    ps = PolicyStore(tmp_path / "policy.json")
    m8 = make_manifest("llm", 8)
    assert check_param_gate(m8, ps.load()) is not None
    ps.save(PackPolicy(max_model_parameters_b=8))
    assert check_param_gate(m8, ps.load()) is None


def test_store_rejects_nonpositive_values(tmp_path):
    ps = PolicyStore(tmp_path / "policy.json")
    with pytest.raises(ValueError):
        ps.save(PackPolicy(max_model_parameters_b=0))
    with pytest.raises(ValueError):
        ps.save(PackPolicy(system_reserved_memory_mb=0))
    # 原 policy 未被破坏
    assert ps.load() == PackPolicy()
