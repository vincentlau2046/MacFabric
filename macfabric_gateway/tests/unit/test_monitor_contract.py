"""monitor_report 契约测试 — 计划 PLAN-2026-11-15 Task 1（P0）。

口径唯一来源：docs/PLAN-2026-11-15-monitor-pools-ux.md 第 3 节。
窗口：1h/24h/7d/30d，区间 [since, until)，until 排除；分桶从 since 划分。
身份：(location, provider, actual_model_id)；历史字段缺失保持 unknown。
"""

import pytest

from inferfabric.monitor_report import bucket_edges, model_identity, resolve_window

from fixtures_monitor import SAMPLE_CLASSES, synthetic_rows

T0 = 1_800_000_000.0  # 固定 until，杜绝时钟依赖


class TestWindowBoundaries:
    def test_spans_and_buckets(self):
        assert resolve_window("1h", T0) == (T0 - 3600, T0, 12)
        assert resolve_window("24h", T0) == (T0 - 86400, T0, 24)
        assert resolve_window("7d", T0) == (T0 - 604800, T0, 28)
        assert resolve_window("30d", T0) == (T0 - 2592000, T0, 30)

    def test_default_window_is_24h(self):
        assert resolve_window(None, T0) == resolve_window("24h", T0)

    def test_unknown_window_rejected(self):
        with pytest.raises(ValueError):
            resolve_window("90d", T0)
        with pytest.raises(ValueError):
            resolve_window("month", T0)

    def test_bucket_edges_cover_window(self):
        # since 纳入、until 排除：edges[0]=since，edges[-1]=until，落点
        # [edges[i], edges[i+1]) 归第 i 桶；桶宽按实际秒数均分。
        for win, nb in (("1h", 12), ("24h", 24), ("7d", 28), ("30d", 30)):
            since, until, buckets = resolve_window(win, T0)
            edges = bucket_edges(since, until, buckets)
            assert len(edges) == buckets + 1
            assert edges[0] == since and edges[-1] == until
            assert all(edges[i] < edges[i + 1] for i in range(buckets))
            width = (until - since) / buckets
            assert all(
                abs((edges[i + 1] - edges[i]) - width) < 1e-6
                for i in range(buckets)
            )

    def test_buckets_sum_equals_total(self):
        # 各桶宽度相加 == 全窗合计（秒）
        for win in ("1h", "24h", "7d", "30d"):
            since, until, buckets = resolve_window(win, T0)
            edges = bucket_edges(since, until, buckets)
            assert sum(edges[i + 1] - edges[i] for i in range(buckets)) == until - since


class TestModelIdentity:
    def test_cloud_provider_not_merged(self):
        a = model_identity({"route": "cloud:prov_a/gpt-x", "cloud_provider": "prov_a", "model": "gpt-x"})
        b = model_identity({"route": "cloud:prov_b/gpt-x", "cloud_provider": "prov_b", "model": "gpt-x"})
        assert a == ("cloud", "prov_a", "gpt-x")
        assert b == ("cloud", "prov_b", "gpt-x")
        assert a != b

    def test_local_not_mixed_with_cloud(self):
        local = model_identity({"route": "local:qwen3-4b", "model": "qwen3-4b"})
        cloud = model_identity({"route": "cloud:prov_a/qwen3-4b", "cloud_provider": "prov_a", "model": "qwen3-4b"})
        assert local == ("local", "", "qwen3-4b")
        assert local != cloud

    def test_pool_route_location(self):
        row = {"route": "pool:fast/cloud:prov_a/gpt-x", "cloud_provider": "prov_a", "model": "gpt-x"}
        assert model_identity(row) == ("cloud", "prov_a", "gpt-x")
        row_local = {"route": "pool:fast/local:qwen3-4b", "model": "qwen3-4b"}
        assert model_identity(row_local) == ("local", "", "qwen3-4b")

    def test_route_provider_beats_missing_cloud_provider(self):
        # 历史行可能缺 cloud_provider：route 里带 provider 时仍可归属
        row = {"route": "cloud:prov_a/gpt-x", "model": "gpt-x"}
        assert model_identity(row) == ("cloud", "prov_a", "gpt-x")

    def test_missing_fields_stay_unknown(self):
        assert model_identity({}) == ("unknown", "unknown", "unknown")
        # 缺 route：无法定位 location，不冒认
        assert model_identity({"model": "gpt-x", "cloud_provider": "prov_a"}) == (
            "unknown", "unknown", "gpt-x")
        # 缺 model：身份第三元为 unknown
        assert model_identity({"route": "local:qwen3-4b"}) == ("local", "", "unknown")


class TestSyntheticSamples:
    """合成样本自检：十类齐全、身份可解析、时间落在 24h 窗内（Task 7 复用）。"""

    def test_all_classes_present_and_inside_window(self):
        rows = synthetic_rows(T0)
        assert {r["req_id"] for r in rows} == set(SAMPLE_CLASSES)
        since, until, _ = resolve_window("24h", T0)
        for r in rows:
            assert since <= r["timestamp"] < until, r["req_id"]
            loc, prov, model = model_identity(r)
            # 未到达上游的行（无 local:/cloud: 段）按契约保持 unknown
            if r["req_id"] == "e-no-upstream":
                assert loc == "unknown"
            else:
                assert loc in ("local", "cloud"), r["req_id"]
            assert model, r["req_id"]

    def test_provider_split_on_same_model(self):
        rows = {r["req_id"]: model_identity(r) for r in synthetic_rows(T0)}
        # 同名 gpt-x 在 prov_a/prov_b 不合并
        assert rows["s-cloud-a"] == ("cloud", "prov_a", "gpt-x")
        assert rows["e-upstream"] == ("cloud", "prov_b", "gpt-x")
        # 本地同名不混入云端
        assert rows["s-local"] == ("local", "", "qwen3-4b")
