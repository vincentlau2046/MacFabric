"""池逻辑名前缀硬切 iff/ → fabric-（用户裁决 2026-11-16，方案 B 硬切）。

- POOL_PREFIX = "fabric-"：池路由/池校验/key 作用域只认新前缀
- iff/ 不保留别名：不再识别为池，按普通模型名走直连/云路径
- 动机：slash 命名在部分客户端 SDK/工具上有兼容问题（model 字段被
  当路径段处理）；fabric- 无特殊字符
"""

from inferfabric.model_pool.config import load_pools_dict
from inferfabric.model_pool.dispatch import is_pool_name, pool_name_of


def test_fabric_prefix_is_pool_name():
    assert is_pool_name("fabric-fast") is True
    assert pool_name_of("fabric-fast") == "fast"
    assert pool_name_of("fabric-premium") == "premium"


def test_iff_prefix_hard_cut():
    # 硬切：旧 iff/ 前缀不再识别为池（用户裁决 2026-11-16 — 单用户
    # 场景不留别名，避免技术债）
    assert is_pool_name("iff/fast") is False


def test_plain_model_not_pool():
    assert is_pool_name("qwen3-4b") is False
    assert is_pool_name("fabric") is False          # 无连字符不算
    assert is_pool_name("fabric-") is True          # 空池名交由 unknown_pool 404


def test_pool_config_rejects_fabric_self_reference():
    # 禁池引用池：目标名不得落在 fabric- 逻辑命名空间
    raw = {"schema_version": 1, "pools": {"fast": {
        "enabled": True, "max_attempts": 2, "deadline_ms": 60000,
        "strategy": "priority_failover",
        "candidates": [{"id": "c1", "kind": "local",
                        "model_name": "fabric-fast"}]}}}
    pools, issues = load_pools_dict(raw, current_revision=0)
    assert pools is None
    assert any("fabric-" in i and "must not reference pools" in i
               for i in issues), issues
