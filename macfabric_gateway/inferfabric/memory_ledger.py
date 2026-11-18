"""DEPRECATED shim — moved to inferfabric.platform.resource_umem (M1 refactor).

Kept one release cycle so existing imports keep working:
    from inferfabric.memory_ledger import MemoryLedger, Mode, ...   # still fine
New code must import from inferfabric.platform.resource_umem / .resource.
"""
import warnings

from .platform.resource import (  # noqa: F401
    AdmitDecision,
    LedgerEntry,
    Lifecycle,
    Mode,
)
from .platform.resource_umem import UnifiedMemoryLedger  # noqa: F401

MemoryLedger = UnifiedMemoryLedger

__all__ = ["MemoryLedger", "UnifiedMemoryLedger", "Mode", "Lifecycle",
           "AdmitDecision", "LedgerEntry"]

warnings.warn(
    "inferfabric.memory_ledger is deprecated; import "
    "inferfabric.platform.resource_umem instead",
    DeprecationWarning,
    stacklevel=2,
)
