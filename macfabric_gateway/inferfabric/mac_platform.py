"""
inferfabric/mac_platform.py — MacFabric Apple Silicon 平台层。

职责（PLAN.md P1「CUDA 线门禁退役」）：
- 端口→PID 探测：macOS 无 fuser，改用 lsof；Linux 保留上游 fuser 行为。
- 统一内存（Unified Memory）口径：Mac 无独立显存，gpu_used/total 映射到
  系统内存水位；预算 B = RAM − 8G（D2 裁决，MACFABRIC_RESERVE_MB 可覆盖）。
- 非 macOS 平台全部回退上游行为（nvidia-smi/fuser），分叉不破坏上游兼容。

所有探测函数失败时返回保守值，绝不抛异常（上游 health.py 同一纪律）。
"""

import os
import re
import subprocess
import sys

log_label = "macfabric.platform"

IS_MACOS = sys.platform == "darwin"

# D2: 统一内存预算 = RAM − 8G。仅 macOS 生效；环境变量可覆盖（便于测试）。
DEFAULT_RESERVE_MB = 8 * 1024  # 8192MB


def _run(cmd: list[str], timeout: int = 10) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


# ─── 端口 → PID ──────────────────────────────────────────────────

def pid_on_port(port: int) -> int | None:
    """返回占用 TCP 监听端口的 PID；探测失败返回 None。

    macOS: lsof -ti tcp:PORT -sTCP:LISTEN（fuser 不存在于 macOS）
    Linux: fuser PORT/tcp（上游行为不变）
    """
    try:
        if IS_MACOS:
            r = _run(["lsof", "-ti", f"tcp:{port}", "-sTCP:LISTEN"])
            if r.returncode == 0 and r.stdout.strip():
                return int(r.stdout.strip().splitlines()[0])
            return None
        r = _run(["fuser", str(port) + "/tcp"])
        if r.returncode == 0:
            m = re.search(r"(\d+)", r.stdout)
            return int(m.group(1)) if m else None
    except Exception:
        return None
    return None


# ─── 统一内存水位 ────────────────────────────────────────────────

def mem_total_mb() -> int | None:
    """物理内存总量 MB。macOS 用 sysctl hw.memsize；非 macOS 返回 None。"""
    if not IS_MACOS:
        return None
    try:
        r = _run(["sysctl", "-n", "hw.memsize"])
        if r.returncode == 0 and r.stdout.strip().isdigit():
            return int(r.stdout.strip()) // (1024 * 1024)
    except Exception:
        pass
    return None


def mem_used_mb() -> int | None:
    """已用内存 MB = total − (free + inactive + purgeable)。

    vm_stat 口径：free/inactive/speculative 页可回收，active/wired/compressed
    视为在用。失败返回 None。
    """
    if not IS_MACOS:
        return None
    total = mem_total_mb()
    if total is None:
        return None
    try:
        r = _run(["vm_stat"])
        if r.returncode != 0:
            return None
        pages = {}
        page_size = 4096
        m = re.search(r"page size of (\d+) bytes", r.stdout)
        if m:
            page_size = int(m.group(1))
        for line in r.stdout.splitlines():
            mm = re.match(r"^(.+):\s+(\d+)", line.strip())
            if mm:
                pages[mm.group(1).rstrip(":")] = int(mm.group(2))

        def pg(key: str) -> int:
            for k, v in pages.items():
                if k.startswith(key):
                    return v
            return 0

        reclaimable = (pg("Pages free") + pg("Pages inactive")
                       + pg("Pages speculative"))
        used_mb = total - (reclaimable * page_size) // (1024 * 1024)
        return max(used_mb, 0)
    except Exception:
        return None


# ─── 预算 B（内存账本地基）─────────────────────────────────────

def budget_mb() -> int:
    """统一内存推理预算 B = RAM − 8G（D2）。非 macOS 回退上游（返回 None 语义由调用方处理）。

    这里返回 int；非 macOS 上调用方不应使用本函数（is_macos() 门禁在前）。
    """
    reserve = int(os.environ.get("MACFABRIC_RESERVE_MB", DEFAULT_RESERVE_MB))
    total = mem_total_mb()
    if total is None:
        return 0
    return max(total - reserve, 0)
