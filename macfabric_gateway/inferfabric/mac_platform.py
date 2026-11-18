"""DEPRECATED shim — moved to inferfabric.platform.probe (M1 refactor).

Kept one release cycle. Compatibility discipline: this module resolves
`mem_total_mb` through ITS OWN globals inside `budget_mb`, so existing
tests/callers that patch `mac_platform.mem_total_mb` keep working.
New code must import inferfabric.platform.probe directly.
"""
import warnings

from .platform import probe as _probe

IS_MACOS = _probe.IS_MACOS
DEFAULT_RESERVE_MB = _probe.DEFAULT_RESERVE_MB
_policy_reserve_mb = _probe._policy_reserve_mb  # noqa: F401 (compat)
_run = _probe._run  # noqa: F401 (compat)


def pid_on_port(port: int) -> int | None:
    return _probe.pid_on_port(port)


def mem_total_mb() -> int | None:
    return _probe.mem_total_mb()


def mem_used_mb() -> int | None:
    return _probe.mem_used_mb()


def budget_mb() -> int:
    """B = RAM − reserve；mem_total_mb 经本模块命名空间动态解析（可打桩）。"""
    return _probe._budget_core(mem_total_mb())


__all__ = ["IS_MACOS", "DEFAULT_RESERVE_MB", "pid_on_port", "mem_total_mb",
           "mem_used_mb", "budget_mb"]

warnings.warn(
    "inferfabric.mac_platform is deprecated; import "
    "inferfabric.platform.probe instead",
    DeprecationWarning,
    stacklevel=2,
)
