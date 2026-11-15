"""monitor 契约的确定性合成样本（PLAN-2026-11-15 Task 1）。

全部离线：不调用真实上游、不含任何用户凭证。行形状对齐 request_log
（db.py）：req_id/model/status/ttft_ms/tokens_in/tokens_out/duration_ms/
route/cloud_provider/error/timestamp/metadata。

九类样本：success / upstream_error / no_upstream / retry_same_target /
fallback / stream_interrupt / missing_usage / alias / deleted_pool_history。
供本文件自检与 Task 7 test_monitor_report 复用。
"""

T0 = 1_800_000_000.0

OK = 200
UPSTREAM_5XX = 502


def _row(req_id: str, *, model: str, status: int, route: str,
         ts: float, tokens_in: int = 100, tokens_out: int = 50,
         ttft_ms: float | None = 120.0, duration_ms: float = 900.0,
         cloud_provider: str | None = None, error: str | None = None,
         metadata: dict | None = None) -> dict:
    row = {
        "req_id": req_id, "model": model, "status": status,
        "ttft_ms": ttft_ms, "tokens_in": tokens_in,
        "tokens_out": tokens_out, "duration_ms": duration_ms,
        "route": route, "cloud_provider": cloud_provider,
        "error": error, "timestamp": ts,
        "metadata": metadata if metadata is not None else {},
    }
    return row


def synthetic_rows(until: float = T0) -> list[dict]:
    """按类别构造 9+ 行，全部落在 [until-86400, until) 内。"""
    since = until - 86400
    mid = since + 43200
    return [
        # 成功：本地
        _row("s-local", model="qwen3-4b", status=OK,
             route="local:qwen3-4b", ts=since + 10),
        # 成功：云端 prov_a（pool 路由）
        _row("s-cloud-a", model="gpt-x", status=OK,
             route="pool:fast/cloud:prov_a/gpt-x", cloud_provider="prov_a",
             ts=since + 20),
        # 上游错误（真实 5xx，非成功）
        _row("e-upstream", model="gpt-x", status=UPSTREAM_5XX,
             route="cloud:prov_b/gpt-x", cloud_provider="prov_b",
             error="upstream 502", ts=since + 30),
        # 无上游（池内无可用候选/预算耗尽，未到达上游）
        _row("e-no-upstream", model="iff/premium", status=503,
             route="pool:premium", tokens_in=0, tokens_out=0,
             ttft_ms=None, duration_ms=5.0, error="no_available_candidate",
             ts=since + 40,
             metadata={"pool_summary": {"outcome": "no_candidate"}}),
        # 同目标重试后成功（2 attempts / 1 retry / 0 fallback）
        _row("r-same-target", model="gpt-x", status=OK,
             route="cloud:prov_a/gpt-x", cloud_provider="prov_a",
             ts=mid,
             metadata={"pool_summary": {
                 "pool": "fast", "attempt_count": 2, "retry_count": 1,
                 "fallback_count": 0,
                 "final_target": {"candidate_id": "c1", "provider": "prov_a",
                                  "actual_model_id": "gpt-x"}}}),
        # 切换目标后成功（2 attempts / 0 retry / 1 fallback）
        _row("r-fallback", model="gpt-x", status=OK,
             route="pool:fast/cloud:prov_b/gpt-x", cloud_provider="prov_b",
             ts=mid + 10,
             metadata={"pool_summary": {
                 "pool": "fast", "attempt_count": 2, "retry_count": 0,
                 "fallback_count": 1,
                 "first_attempted": {"candidate_id": "c1", "provider": "prov_a"},
                 "final_target": {"candidate_id": "c2", "provider": "prov_b",
                                  "actual_model_id": "gpt-x"}}}),
        # 流中断：HTTP 200 但流未正常终止（逻辑非成功）
        _row("e-stream", model="qwen3-4b", status=OK,
             route="local:qwen3-4b", tokens_out=12,
             error="stream_interrupted", ts=mid + 20,
             metadata={"pool_summary": {"outcome": "stream_interrupted",
                                        "completed": False}}),
        # 缺 usage（tokens 全 0 且无 usage 证据，区分于真实 0）
        _row("u-missing", model="gpt-x", status=OK,
             route="cloud:prov_a/gpt-x", cloud_provider="prov_a",
             tokens_in=0, tokens_out=0, ts=mid + 30,
             metadata={"pool_summary": {"usage_known": False}}),
        # 别名：请求名是别名，实际模型不同（身份按 actual_model_id 记录在
        # metadata；行级 model 保留请求名以复现历史行为）
        _row("a-alias", model="iff/fast", status=OK,
             route="pool:fast/local:qwen3-4b", ts=mid + 40,
             metadata={"pool_summary": {
                 "requested_model": "iff/fast",
                 "final_target": {"candidate_id": "c3", "provider": "",
                                  "requested_model_id": "iff/fast",
                                  "actual_model_id": "qwen3-4b"}}}),
        # 已删除池的历史（池已不存在，历史行仍可查、按 route 归类）
        _row("h-deleted-pool", model="gpt-x", status=OK,
             route="pool:legacy/cloud:prov_a/gpt-x", cloud_provider="prov_a",
             ts=mid + 50,
             metadata={"pool_summary": {"pool": "legacy", "attempt_count": 1}}),
    ]


SAMPLE_CLASSES = {
    "s-local": "success", "s-cloud-a": "success",
    "e-upstream": "upstream_error", "e-no-upstream": "no_upstream",
    "r-same-target": "retry_same_target", "r-fallback": "fallback",
    "e-stream": "stream_interrupt", "u-missing": "missing_usage",
    "a-alias": "alias", "h-deleted-pool": "deleted_pool_history",
}
