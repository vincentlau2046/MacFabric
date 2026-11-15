"""同快照监控报告 — PLAN-2026-11-15 v2 Task 7（P3）。

契约（计划 Interfaces）：
- build_monitor_report(db, *, window, until, scope="all")：同一报告内
  totals/models/series/pools/errors 共享区间与读快照；精确计数不被
  100k 查询上限截断；重启回读一致。
- 身份 (location, provider, actual_model)；scope 过滤后 local+cloud+
  unknown == 总量；跨 provider 同名不混合。
- 性能分位按有效原样本（线性插值），不平均桶分位；缺 TTFT/usage/价格
  = unknown ≠ 0。
- 池统计：早期失败入分母；删除池历史可查；老摘要缺失输出覆盖率。
"""

import json
import time
from pathlib import Path

import pytest

from inferfabric.monitor_report import build_monitor_report
from inferfabric.request_log_db import RequestLogDB

T0 = 1_800_000_000.0
SINCE_24H = T0 - 86400


def row(rid, ts, *, model="gpt-x", status=200, route="local:qwen",
        provider=None, tin=10, tout=5, ttft=100.0, dur=500.0,
        error=None, metadata=None):
    return {"req_id": rid, "key_name": "k", "model": model, "status": status,
            "ttft_ms": ttft, "tokens_in": tin, "tokens_out": tout,
            "duration_ms": dur, "route": route, "cloud_provider": provider,
            "error": error, "timestamp": ts, "ts": "",
            "metadata": metadata if metadata is not None else {}}


def make_db(tmp_path):
    return RequestLogDB(db_path=tmp_path / "request_log.db")


def insert_all(db, rows):
    for i in range(0, len(rows), 5000):
        db.insert_request_log(rows[i:i + 5000])


class TestFullWindowOver100k:

    def test_exact_counts_no_truncation(self, tmp_path):
        db = make_db(tmp_path)
        n = 100_001
        rows = []
        for i in range(n):
            ts = SINCE_24H + (i % 86000) + 0.5
            rows.append(row(f"bulk-{i}", ts, tin=1, tout=1))
        insert_all(db, rows)

        report = build_monitor_report(db, window="24h", until=T0)
        assert report["totals"]["requests"] == n  # 不是 10000/100000 截断
        assert report["totals"]["tokens_in"] == n
        assert report["totals"]["tokens_out"] == n
        # series 桶合计 == 总量（同报告内一致）
        assert sum(b["requests"] for b in report["series"]) == n

    def test_restart_parity(self, tmp_path):
        db = make_db(tmp_path)
        insert_all(db, [row(f"r{i}", SINCE_24H + i + 1) for i in range(500)])
        r1 = build_monitor_report(db, window="24h", until=T0)
        db2 = RequestLogDB(db_path=tmp_path / "request_log.db")  # 模拟重启
        r2 = build_monitor_report(db2, window="24h", until=T0)
        assert r1["totals"] == r2["totals"]
        assert r1["models"] == r2["models"]


class TestScopeIdentityAndPercentiles:

    def test_scope_sum_and_identity_split(self, tmp_path):
        db = make_db(tmp_path)
        rows = [
            row("l1", SINCE_24H + 10, route="local:qwen"),
            row("c1", SINCE_24H + 20, route="cloud:prov_a/gpt-x",
                provider="prov_a"),
            row("u1", SINCE_24H + 30, route="pool:fast"),  # 未归属（无上游）
            row("c2", SINCE_24H + 40, route="cloud:prov_b/gpt-x",
                provider="prov_b"),
        ]
        insert_all(db, rows)
        total = build_monitor_report(db, window="24h", until=T0)
        local = build_monitor_report(db, window="24h", until=T0, scope="local")
        cloud = build_monitor_report(db, window="24h", until=T0, scope="cloud")
        assert (local["totals"]["requests"] + cloud["totals"]["requests"]
                + (total["totals"]["requests"]
                   - local["totals"]["requests"]
                   - cloud["totals"]["requests"])) == 4
        assert local["totals"]["requests"] == 1
        assert cloud["totals"]["requests"] == 2
        assert total["totals"]["requests"] == 4
        # 跨 provider 同名不混合：cloud 内同名 models 表两行（local/unknown
        # 的同名行是独立身份组，不并入）
        gx = [m for m in total["models"]
              if m["model"] == "gpt-x" and m["location"] == "cloud"]
        assert len(gx) == 2
        assert {m["provider"] for m in gx} == {"prov_a", "prov_b"}

    def test_percentiles_from_raw_samples(self, tmp_path):
        db = make_db(tmp_path)
        # TTFT 样本 1..100（等差），第 95 分位线性插值 = (n-1)*0.95
        rows = [row(f"p{i}", SINCE_24H + 10 + i, ttft=float(i + 1),
                    tout=10, dur=float(1000 + i)) for i in range(100)]
        insert_all(db, rows)
        report = build_monitor_report(db, window="24h", until=T0)
        m = report["models"][0]
        expected_p95 = 1 + (100 - 1) * 0.95  # = 95.05
        assert m["p95_ttft_ms"] == pytest.approx(expected_p95)
        assert m["ttft_samples"] == 100

    def test_missing_fields_unknown_not_zero(self, tmp_path):
        db = make_db(tmp_path)
        rows = [
            row("n1", SINCE_24H + 10, ttft=None),               # 无 TTFT
            row("n2", SINCE_24H + 20,                            # 有 TTFT
                metadata={"pool_summary": {"v": 1, "pool": "fast",
                                           "attempt_count": 1,
                                           "attempts": [{"usage_known": False}]}}),
            row("n3", SINCE_24H + 30, route="pool:x", ttft=None),  # unknown 组零样本
        ]
        insert_all(db, rows)
        report = build_monitor_report(db, window="24h", until=T0)
        local = [m for m in report["models"] if m["location"] == "local"][0]
        assert local["ttft_samples"] == 1       # 缺 TTFT 的行不进样本
        # 若缺失被当 0ms，p50 会被拖到 50 —— 缺失 = 不进样本，而非 0
        assert local["p50_ttft_ms"] == pytest.approx(100.0)
        unknown = [m for m in report["models"] if m["location"] == "unknown"][0]
        assert unknown["ttft_samples"] == 0
        assert unknown["p50_ttft_ms"] is None   # 零样本 = unknown，非 0ms
        assert report["totals"]["usage_unknown_rows"] == 1  # 缺 usage 行计数
        # 未配价格：cost 为 null 而非 0
        assert report["totals"]["cost_estimate"] is None
        assert report["totals"]["cost_coverage"] == "unpriced"


class TestPoolSummaryCoverage:

    def test_pool_stats_with_coverage(self, tmp_path):
        db = make_db(tmp_path)
        rows = [
            # 有摘要：fast 池成功，最终承接 c1
            row("s1", SINCE_24H + 10, route="pool:fast/local:qwen",
                metadata={"pool_summary": {
                    "v": 1, "pool": "fast", "outcome": "ok",
                    "attempt_count": 2, "retry_count": 1, "fallback_count": 0,
                    "final_target": {"candidate_id": "c1", "provider": None,
                                     "requested_model_id": "qwen",
                                     "actual_model_id": "qwen"},
                    "attempts": []}}),
            # 无摘要的早期失败：仍入分母
            row("f1", SINCE_24H + 20, status=404, route="pool:fast",
                error="unknown_pool"),
            # 已删除池 legacy：历史仍可查
            row("h1", SINCE_24H + 30, route="pool:legacy/cloud:prov_a/gpt-x",
                provider="prov_a",
                metadata={"pool_summary": {
                    "v": 1, "pool": "legacy", "outcome": "ok",
                    "attempt_count": 1, "retry_count": 0, "fallback_count": 0,
                    "final_target": {"candidate_id": "c9", "provider": "prov_a",
                                     "requested_model_id": "gpt-x",
                                     "actual_model_id": "gpt-x"},
                    "attempts": []}}),
        ]
        insert_all(db, rows)
        report = build_monitor_report(db, window="24h", until=T0)
        pools = {p["pool"]: p for p in report["pools"]}
        assert set(pools) == {"fast", "legacy"}
        fast = pools["fast"]
        assert fast["requests"] == 2                 # 早期失败入分母
        assert fast["success"] == 1
        assert fast["final_targets"] == {"c1": 1}
        assert fast["attempt_count"] == 2            # 仅汇总有摘要的行
        assert fast["summary_coverage"] == pytest.approx(0.5)
        assert pools["legacy"]["requests"] == 1
        assert pools["legacy"]["final_targets"] == {"c9": 1}

    def test_error_top_sanitized(self, tmp_path):
        db = make_db(tmp_path)
        rows = [
            row("e1", SINCE_24H + 10, status=502, route="cloud:p/gpt-x",
                provider="p", error="upstream 502: token sk-abc123 leaked"),
            row("e2", SINCE_24H + 20, status=429, route="local:qwen",
                error="rate limited"),
        ]
        insert_all(db, rows)
        report = build_monitor_report(db, window="24h", until=T0)
        err_dump = json.dumps(report["errors"])
        assert "sk-abc123" not in err_dump   # 原文不落监控摘要
        classes = {e["class"] for e in report["errors"]}
        assert "upstream_5xx" in classes and "rate_limited" in classes


class TestRouteAndCache:

    def test_parse_params(self):
        from inferfabric.proxy.handler import parse_monitor_params
        assert parse_monitor_params("window=7d&scope=cloud") == ("7d", "cloud")
        assert parse_monitor_params("") == ("24h", "all")
        with pytest.raises(ValueError):
            parse_monitor_params("window=90d")
        with pytest.raises(ValueError):
            parse_monitor_params("scope=galaxy")

    def test_cache_singleflight(self, tmp_path):
        from inferfabric.monitor_report import MonitorReportCache
        db = make_db(tmp_path)
        insert_all(db, [row("x1", SINCE_24H + 10)])
        cache = MonitorReportCache(ttl_s=60)
        r1 = cache.get_or_build(db, window="24h", until=T0, scope="all")
        r2 = cache.get_or_build(db, window="24h", until=T0, scope="all")
        assert r1 is r2  # TTL 内同查询复用同一报告对象
        r3 = cache.get_or_build(db, window="24h", until=T0, scope="cloud")
        assert r3 is not r1

    def test_cache_prices_change_within_ttl(self, tmp_path):
        """价格经 get_or_build 传入（终审 I5）：接线不换缓存键，TTL 内生效。"""
        from inferfabric.metrics_aggregator import CloudModelPrice
        from inferfabric.monitor_report import MonitorReportCache
        db = make_db(tmp_path)
        insert_all(db, [row("px", SINCE_24H + 10, route="cloud:prov_a/gpt-x",
                            provider="prov_a", tin=1_000_000, tout=0)])
        cache = MonitorReportCache(ttl_s=60)
        r1 = cache.get_or_build(db, window="24h", until=T0, scope="all",
                                prices={"gpt-x": CloudModelPrice(2.0, 1.0)})
        assert r1["totals"]["cost_estimate"] == pytest.approx(2.0)


class TestReviewFixPass:
    """最终评审修复轮（0f07cf8..2b64d54 整分支评审）：每项先 RED 后 GREEN。"""

    def test_same_timestamp_flood_full_count(self, tmp_path):
        """I1：10 万行同秒洪流必须全量计数（(timestamp,id) 键集分页）。"""
        db = make_db(tmp_path)
        n = 100_001
        ts = SINCE_24H + 100.0
        rows = [row(f"flood-{i}", ts, tin=1, tout=1) for i in range(n)]
        insert_all(db, rows)
        report = build_monitor_report(db, window="24h", until=T0)
        assert report["totals"]["requests"] == n
        assert sum(b["requests"] for b in report["series"]) == n
        assert report["coverage"]["truncated"] is False

    def test_since_boundary_inclusive(self, tmp_path):
        """I1：[since, until) 下界含 since —— 恰在 since 的行必须入报告。"""
        db = make_db(tmp_path)
        insert_all(db, [row("edge-at-since", SINCE_24H, tin=2, tout=1)])
        report = build_monitor_report(db, window="24h", until=T0)
        assert report["totals"]["requests"] == 1

    def test_3xx_not_success(self, tmp_path):
        """I2：3xx 不是成功（传输契约 = 2xx）。"""
        db = make_db(tmp_path)
        insert_all(db, [row("r302", SINCE_24H + 10, status=302, tin=3, tout=2)])
        report = build_monitor_report(db, window="24h", until=T0)
        t = report["totals"]
        assert t["requests"] == 1 and t["success"] == 0
        # 3xx 无 error 文本且 <400 → 不计错误类别（既非成功也非错误）
        assert report["errors"] == []

    def test_direct_row_missing_usage_counts_unknown(self, tmp_path):
        """I3：直连成功行缺 usage（0/0、无摘要证据）计 unknown，不冒认 0。"""
        db = make_db(tmp_path)
        insert_all(db, [row("du", SINCE_24H + 10, status=200, tin=0, tout=0)])
        report = build_monitor_report(db, window="24h", until=T0)
        assert report["totals"]["usage_unknown_rows"] == 1

    def test_alias_grouped_by_actual_model(self, tmp_path):
        """I4：池行按 final_target.actual_model_id 聚合（行级 model 保留请求名）。"""
        import sys
        from pathlib import Path as _P
        sys.path.insert(0, str(_P(__file__).parent))
        import fixtures_monitor as fx
        db = make_db(tmp_path)
        insert_all(db, fx.synthetic_rows())
        report = build_monitor_report(db, window="24h", until=T0)
        local_models = {m["model"] for m in report["models"]
                        if m["location"] == "local"}
        assert "qwen3-4b" in local_models
        assert "iff/fast" not in local_models

    def test_cost_uses_price_table_yuan_per_1m(self, tmp_path):
        """I5：复用 cost_of_row 唯一计价入口（¥/1M tokens），字段名 cost_estimate。"""
        from inferfabric.metrics_aggregator import CloudModelPrice
        db = make_db(tmp_path)
        insert_all(db, [row("cp", SINCE_24H + 10, model="gpt-x", status=200,
                            route="cloud:prov_a/gpt-x", provider="prov_a",
                            tin=1_000_000, tout=2_000_000)])
        report = build_monitor_report(db, window="24h", until=T0,
                                      prices={"gpt-x": CloudModelPrice(3.0, 4.0)})
        t = report["totals"]
        assert t["cost_estimate"] == pytest.approx(3.0 * 1 + 4.0 * 2)
        assert t["cost_coverage"] == "priced"
        assert "cost_estimate_usd" not in t

    def test_unpriced_reports_none(self, tmp_path):
        """I5：无价格配置 → cost_estimate null + unpriced（显式，非缺省）。"""
        db = make_db(tmp_path)
        insert_all(db, [row("up", SINCE_24H + 10)])
        report = build_monitor_report(db, window="24h", until=T0)
        assert report["totals"]["cost_estimate"] is None
        assert report["totals"]["cost_coverage"] == "unpriced"
