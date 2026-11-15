"""inferfabric/monitor_report.py — 统一统计口径（PLAN-2026-11-15 v2 第 3 节契约）。

P0 纯函数：窗口解析、分桶边界、模型身份。不做 I/O、不依赖时钟——
until 一律显式传入，保证同一报告内所有分组共享同一区间。

窗口契约（滚动窗口，非自然日历）：
  1h  → 3600s  × 12 桶（5min）
  24h → 86400s × 24 桶（1h）
  7d  → 604800s × 28 桶（6h）
  30d → 2592000s × 30 桶（24h）
区间 [since, until)：since 纳入、until 排除，与 SQL timestamp >= since
AND timestamp < until 严格对应。

身份契约：(location, provider, actual_model_id)。location ∈ local/cloud/
unknown；local 的 provider 为空串；route 缺失或无法定位时 location=unknown，
不用当前配置回填猜测历史行。
"""

import threading
import time

# window → (跨度秒, 桶数)
_WINDOWS: dict[str, tuple[int, int]] = {
    "1h": (3600, 12),
    "24h": (86400, 24),
    "7d": (604800, 28),
    "30d": (2592000, 30),
}

DEFAULT_WINDOW = "24h"
VALID_WINDOWS = frozenset(_WINDOWS)
VALID_SCOPES = frozenset({"all", "local", "cloud"})

# 报告契约版本（Task 7）：结构变更必须推进
REPORT_CONTRACT = "monitor-report/1"

# 分页扫描页大小：query_request_log 默认 limit 会截断 10 万行窗口，
# 这里按键分页全量扫；样本（ttft/duration 浮点）是唯一驻留内存的大对象
_PAGE_SIZE = 20_000

# 错误 Top 条数（脱敏后仅 class + 计数）
_ERROR_TOP_N = 10

_UNKNOWN = "unknown"


def resolve_window(window: str | None, until: float) -> tuple[float, float, int]:
    """window → (since, until, buckets)。区间 [since, until)，until 排除。

    非法窗口抛 ValueError；window 为 None/空串时取默认 24h。
    """
    win = window or DEFAULT_WINDOW
    if win not in _WINDOWS:
        raise ValueError(
            f"unknown window {window!r} (expected one of {sorted(_WINDOWS)})")
    span, buckets = _WINDOWS[win]
    return until - span, until, buckets


def bucket_edges(since: float, until: float, buckets: int) -> tuple[float, ...]:
    """[since, until) 均分为 buckets 桶，返回 buckets+1 个边界。

    edges[i] <= t < edges[i+1] 归第 i 桶；edges[0]=since（纳入）、
    edges[-1]=until（排除）。按实际秒长均分，不冒称本地自然日。
    """
    if buckets <= 0:
        raise ValueError(f"buckets must be positive, got {buckets}")
    if until <= since:
        raise ValueError(f"until must be greater than since ({since=} {until=})")
    width = (until - since) / buckets
    return tuple(since + i * width for i in range(buckets + 1))


def model_identity(row: dict) -> tuple[str, str, str]:
    """请求日志行 → (location, provider, actual_model_id) 聚合身份。

    - route 含 `cloud:<provider>/…`（含 pool 路由 `pool:<p>/cloud:…`）→
      cloud，provider 取 route 解析值，缺失时退回 cloud_provider 列。
    - route 含 `local:<…>` → local，provider 为空串。
    - 其余（route 缺失/无法识别）→ unknown，不冒认；model 缺失同样
      记 unknown。显示名称不参与聚合主键。
    """
    model = row.get("model") or _UNKNOWN
    route = row.get("route") or ""
    cloud_provider = row.get("cloud_provider") or ""

    location, provider = _UNKNOWN, _UNKNOWN
    idx = route.find("cloud:")
    if idx != -1:
        rest = route[idx + len("cloud:"):]
        provider = rest.split("/", 1)[0] if rest else ""
        if not provider:
            provider = cloud_provider
        location = "cloud"
    elif "local:" in route:
        location, provider = "local", ""
    else:
        provider = _UNKNOWN

    if not provider:
        provider = _UNKNOWN if location == _UNKNOWN else provider
    return location, provider, model


# ═══════════════════════════════════════════════════════════════════
# 同快照监控报告（PLAN-2026-11-15 v2 Task 7 / P3）
# ═══════════════════════════════════════════════════════════════════


def _percentile(samples: list[float], q: float) -> float | None:
    """线性插值分位（全窗 p95 按原样本求，不平均桶分位）。空样本 → None。"""
    if not samples:
        return None
    s = sorted(samples)
    idx = (len(s) - 1) * q
    lo = int(idx)
    hi = min(lo + 1, len(s) - 1)
    return s[lo] + (s[hi] - s[lo]) * (idx - lo)


def _error_class(row: dict) -> str:
    """失败行 → 脱敏错误类别。只出类别名，原文（可能含凭证）不进摘要。"""
    status = row.get("status")
    error = str(row.get("error") or "")
    if status == 429:
        return "rate_limited"
    if status in (401, 403):
        return "auth"
    if isinstance(status, int) and status >= 500:
        return "upstream_5xx"
    lowered = error.lower()
    if any(k in lowered for k in ("no_upstream", "unknown_pool", "pool_unavailable",
                                  "no_available_candidate", "no_ready_target",
                                  "no_compatible_target")):
        return "no_upstream"
    if isinstance(status, int) and status >= 400:
        return "upstream_4xx"
    if error:
        return "other"
    return "other"


def _pool_name(row: dict) -> str | None:
    """行归属池名：摘要优先，其次 route 的 `pool:<name>` 标记；否则 None。"""
    ps = row.get("metadata") or {}
    summary = ps.get("pool_summary") if isinstance(ps, dict) else None
    if isinstance(summary, dict) and summary.get("pool"):
        return str(summary["pool"])
    route = row.get("route") or ""
    if route.startswith("pool:"):
        rest = route[len("pool:"):]
        return rest.split("/", 1)[0] or None
    return None


def build_monitor_report(db, *, window: str = DEFAULT_WINDOW, until: float,
                         scope: str = "all", prices: dict | None = None) -> dict:
    """同快照监控报告：totals/models/series/pools/errors 共享区间与读快照。

    db 需提供 query_request_log(since, until=None, model=None, limit=N)
    （TelemetryHub 直通 db.py 即可）。扫描按键分页全量进行，不截断；
    聚合流式进行，仅性能样本（浮点列表）驻留内存。

    - 身份与分桶遵守第 3 节契约（model_identity / bucket_edges）。
    - scope 过滤：local / cloud 按 identity location；unknown 只进 all。
    - 缺 TTFT → 样本不计入（分位为 None，不是 0ms）；摘要 usage_known
      False 的行计入 totals.usage_unknown_rows；prices 缺省 → 成本为
      null（unpriced），不冒充 0。
    - 池统计：早期失败（无摘要）入分母；attempt/retry/fallback 只汇总
      有摘要的行；summary_coverage = 有摘要行 / 分母。
    """
    if scope not in VALID_SCOPES:
        raise ValueError(f"unknown scope {scope!r} (expected one of {sorted(VALID_SCOPES)})")
    since, until, buckets = resolve_window(window, until)
    edges = bucket_edges(since, until, buckets)

    totals = {"requests": 0, "success": 0, "success_rate": 0.0,
              "tokens_in": 0, "tokens_out": 0,
              "usage_unknown_rows": 0, "cost_estimate_usd": None,
              "cost_coverage": "unpriced" if prices is None else "priced"}
    models: dict[tuple, dict] = {}
    series = [{"bucket_start": edges[i], "bucket_end": edges[i + 1],
               "requests": 0, "success": 0, "tokens_in": 0, "tokens_out": 0}
              for i in range(buckets)]
    pools: dict[str, dict] = {}
    error_counts: dict[str, int] = {}
    pool_summary_rows = 0
    cost = 0.0
    priced_tokens = False

    import bisect
    import math as _math

    cursor = until
    seen: set[str] = set()
    while True:
        rows = db.query_request_log(since, cursor, limit=_PAGE_SIZE)
        if not rows:
            break
        prev_min = cursor
        page_min = min(r.get("timestamp") or 0.0 for r in rows)
        for row in rows:
            rid = row.get("req_id")
            if rid is not None:
                if rid in seen:
                    continue  # 分页边界（相等时间戳）重叠，去重不双计
                seen.add(rid)
            loc, provider, model = model_identity(row)
            if scope == "local" and loc != "local":
                continue
            if scope == "cloud" and loc != "cloud":
                continue

            status = row.get("status")
            is_success = isinstance(status, int) and 200 <= status < 400
            tin = int(row.get("tokens_in") or 0)
            tout = int(row.get("tokens_out") or 0)

            totals["requests"] += 1
            if is_success:
                totals["success"] += 1
            totals["tokens_in"] += tin
            totals["tokens_out"] += tout

            # series 桶（全量行都归桶，保证图桶合计 == 总量）
            ts = row.get("timestamp")
            if isinstance(ts, (int, float)) and since <= ts < until:
                b = series[bisect.bisect_right(edges, ts) - 1]
                b["requests"] += 1
                if is_success:
                    b["success"] += 1
                b["tokens_in"] += tin
                b["tokens_out"] += tout

            # models 聚合（跨 provider 同名不混合：键含 location+provider）
            mkey = (loc, provider, model)
            m = models.get(mkey)
            if m is None:
                m = models[mkey] = {
                    "location": loc, "provider": provider, "model": model,
                    "requests": 0, "success": 0, "tokens_in": 0, "tokens_out": 0,
                    "ttft_samples": [], "duration_samples": [],
                }
            m["requests"] += 1
            if is_success:
                m["success"] += 1
            m["tokens_in"] += tin
            m["tokens_out"] += tout
            ttft = row.get("ttft_ms")
            if isinstance(ttft, (int, float)) and ttft > 0:
                m["ttft_samples"].append(float(ttft))
            dur = row.get("duration_ms")
            if isinstance(dur, (int, float)) and dur > 0:
                m["duration_samples"].append(float(dur))

            # 错误类别（脱敏）
            if not is_success and (row.get("error") or (isinstance(status, int) and status >= 400)):
                cls = _error_class(row)
                error_counts[cls] = error_counts.get(cls, 0) + 1

            # 池统计
            pname = _pool_name(row)
            if pname is not None:
                p = pools.get(pname)
                if p is None:
                    p = pools[pname] = {
                        "pool": pname, "requests": 0, "success": 0,
                        "final_targets": {}, "attempt_count": 0,
                        "retry_count": 0, "fallback_count": 0,
                        "summary_rows": 0,
                    }
                p["requests"] += 1
                if is_success:
                    p["success"] += 1
                meta = row.get("metadata") or {}
                summary = meta.get("pool_summary") if isinstance(meta, dict) else None
                if isinstance(summary, dict):
                    pool_summary_rows += 1
                    p["summary_rows"] += 1
                    ft = summary.get("final_target") or {}
                    cid = ft.get("candidate_id") if isinstance(ft, dict) else None
                    if cid:
                        p["final_targets"][cid] = p["final_targets"].get(cid, 0) + 1
                    p["attempt_count"] += int(summary.get("attempt_count") or 0)
                    p["retry_count"] += int(summary.get("retry_count") or 0)
                    p["fallback_count"] += int(summary.get("fallback_count") or 0)
                    for at in summary.get("attempts") or []:
                        if isinstance(at, dict) and at.get("usage_known") is False:
                            totals["usage_unknown_rows"] += 1
                            break

            # 成本估算（配价时）；无价格配置 = unpriced（null 而非 0）
            if prices:
                price = prices.get(model) or prices.get(f"{provider}/{model}")
                if isinstance(price, dict) and (tin or tout):
                    cost += tin * float(price.get("in", 0.0)) \
                        + tout * float(price.get("out", 0.0))
                    priced_tokens = True

        if len(rows) < _PAGE_SIZE:
            break
        # 键分页推进：nextafter 让边界行（相等时间戳）重查一次，seen 去重；
        # 游标不前进（海量同秒行）或越过 since 则终止，宁可停扫不死循环
        cursor = _math.nextafter(page_min, _math.inf)
        if cursor >= prev_min or cursor <= since:
            break

    totals["success_rate"] = round(totals["success"] / totals["requests"], 4) \
        if totals["requests"] else 0.0
    if prices is not None:
        totals["cost_estimate_usd"] = round(cost, 6) if priced_tokens else 0.0
        totals["cost_coverage"] = "priced" if priced_tokens else "no_priced_usage"

    model_rows = []
    for m in models.values():
        ttft = m.pop("ttft_samples")
        dur = m.pop("duration_samples")
        # 分位不做 1 位舍入：round(95.05,1) 因浮点表示回退 95.0，破坏
        # 线性插值契约；展示层自行格式化
        m["p50_ttft_ms"] = _percentile(ttft, 0.5)
        m["p95_ttft_ms"] = _percentile(ttft, 0.95)
        m["ttft_samples"] = len(ttft)
        m["p50_duration_ms"] = _percentile(dur, 0.5)
        m["p95_duration_ms"] = _percentile(dur, 0.95)
        m["duration_samples"] = len(dur)
        m["success_rate"] = round(m["success"] / m["requests"], 4) if m["requests"] else 0.0
        model_rows.append(m)
    model_rows.sort(key=lambda m: (-m["requests"], m["model"]))

    pool_rows = []
    for p in pools.values():
        cov = p.pop("summary_rows") / p["requests"] if p["requests"] else 0.0
        p["summary_coverage"] = round(cov, 4)
        pool_rows.append(p)
    pool_rows.sort(key=lambda p: -p["requests"])

    errors = [{"class": c, "count": n}
              for c, n in sorted(error_counts.items(), key=lambda kv: -kv[1])[:_ERROR_TOP_N]]

    return {
        "contract": REPORT_CONTRACT,
        "window": window or DEFAULT_WINDOW,
        "scope": scope,
        "since": since,
        "until": until,
        "collected_at": time.time(),
        "coverage": {
            "rows_scanned": totals["requests"],
            "pool_summary_rows": pool_summary_rows,
            # 全量键分页扫描，无截断；truncated=True 仅在同秒海量行护栏触发
            "truncated": False,
        },
        "totals": totals,
        "models": model_rows,
        "series": series,
        "pools": pool_rows,
        "errors": errors,
    }


class MonitorReportCache:
    """按 (window, scope) 的短 TTL 单飞缓存。

    TTL 内同查询复用同一报告对象（数字/表/图天然一致）；miss 时在锁内
    构建做单飞（并发请求等待首个构建，不重复扫库）。大扫描只发生在
    报告端点，绝不接入 3s 全局轮询路径。
    """

    def __init__(self, ttl_s: float = 15.0):
        self._ttl = ttl_s
        self._lock = threading.Lock()
        self._cache: dict[tuple[str, str], tuple[float, dict]] = {}

    def get_or_build(self, db, *, window: str, until: float,
                     scope: str = "all") -> dict:
        key = (window or DEFAULT_WINDOW, scope)
        now = time.time()
        with self._lock:
            hit = self._cache.get(key)
            if hit and now - hit[0] < self._ttl:
                return hit[1]
            report = build_monitor_report(db, window=window, until=until,
                                          scope=scope)
            self._cache[key] = (now, report)
            # 防 key 膨胀（窗口×scope 组合有限，仍兜底清理）
            if len(self._cache) > 32:
                cutoff = now - self._ttl
                self._cache = {k: v for k, v in self._cache.items()
                               if v[0] >= cutoff} or {key: (now, report)}
            return report
