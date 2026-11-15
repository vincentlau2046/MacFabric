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

# window → (跨度秒, 桶数)
_WINDOWS: dict[str, tuple[int, int]] = {
    "1h": (3600, 12),
    "24h": (86400, 24),
    "7d": (604800, 28),
    "30d": (2592000, 30),
}

DEFAULT_WINDOW = "24h"

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
