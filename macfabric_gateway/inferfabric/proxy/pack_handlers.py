"""能力包 admin API 门面 — PK1（Task 8）。

PackManager 聚合 Catalog/PolicyStore/PackStore/PackInstaller：App 只见
HTTP 契约，URL/hash 由后端提供（Catalog-only 安装入口，spec §6.1 裁决）。

HTTP 契约（handler.py 薄委托）：
  GET  /admin/packs/catalog / status / policy
  POST /admin/packs/install {"pack_id"} / policy
  旧 /admin/packs/download 原样保留（用户导入模型路径）。

安装事务在后台线程执行；同 pack_id 进行中 → 409（互斥由 installer 的
per-pack Lock + 本门面 in_progress 表共同保证）。
"""

import json
import logging
import socket
import threading
import urllib.request
from pathlib import Path

from inferfabric.packs.catalog import Catalog, load_catalog
from inferfabric.packs.config_gen import (
    ConfigExistsError,
    build_model_config,
    write_managed_yaml,
)
from inferfabric.packs.installer import PackInstaller
from inferfabric.packs.policy import PackPolicy, PolicyStore
from inferfabric.packs.sandbox import NoopProvider, probe_sandbox
from inferfabric.packs.store import PackRecord, PackStore

log = logging.getLogger("inferfabric.packs")

POLICY_MEM_RANGE = (1024, 65536)

BUNDLED_CATALOG = Path(__file__).resolve().parents[1] / "packs_catalog.yaml"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class HttpArtifactFetcher:
    """生产 fetcher：HTTPS 流式下载到 dest（调用方保证 dest 为 .part）。"""

    def __init__(self, chunk=1024 * 1024):
        self._chunk = chunk

    def fetch(self, artifact, dest) -> None:
        req = urllib.request.Request(artifact.source, method="GET")
        with urllib.request.urlopen(req, timeout=60) as resp, \
                open(dest, "wb") as f:
            while True:
                chunk = resp.read(self._chunk)
                if not chunk:
                    break
                f.write(chunk)


class PackManager:
    def __init__(self, root, models_d, catalog_path=None, fetcher=None,
                 reload_gateway=None):
        self.root = Path(root)
        self.models_d = Path(models_d)
        self.catalog = Catalog(load_catalog(catalog_path or BUNDLED_CATALOG))
        self.store = PackStore(self.root / "state.json")
        self.policy = PolicyStore(self.root / "policy.json")
        self._reload_gateway = reload_gateway
        self._fetcher = fetcher or HttpArtifactFetcher()
        self._in_progress: dict[str, str] = {}   # pack_id -> stage
        self._progress_lock = threading.Lock()
        self.installer = PackInstaller(
            root=self.root, fetcher=self._fetcher, policy=self.policy,
            sandbox_provider=NoopProvider(), catalog_probe=probe_sandbox,
            write_model_config=self._write_model_config,
            reload_gateway=self._reload_gateway)
        reconcile_on_boot(self.store, self.root)
        self._uninstaller = None    # 惰性：attach_uninstaller 注入网关侧回调
        self._disabled_models: set[str] = set()

    def attach_uninstaller(self, registry, disable_route_fn, stop_pack_fn,
                           is_alive_fn, pgid_fn=None, reload_fn=None) -> None:
        """网关侧回调注入（Task 12 集成时由 pm 侧装配）。

        registry 需 iter_candidates/purge_candidates（PoolRegistry 现有契约）。
        """
        from inferfabric.packs.uninstaller import PackUninstaller
        self._uninstaller = PackUninstaller(
            root=self.root, store=self.store, models_d=self.models_d,
            manifest_for=self._manifest_for, registry=registry,
            disable_route_fn=lambda name: (self._disabled_models.add(name),
                                           disable_route_fn(name))[-1],
            stop_pack_fn=stop_pack_fn, is_alive_fn=is_alive_fn,
            pgid_fn=pgid_fn, reload_fn=reload_fn or self._reload)

    def _manifest_for(self, pack_id: str):
        entry = self.catalog.find(pack_id)
        return entry.manifest if entry else None

    def preview_uninstall(self, pack_id: str) -> tuple[int, dict]:
        if self._uninstaller is None or self._manifest_for(pack_id) is None:
            return 404, {"error": f"unknown pack {pack_id!r}"}
        return 200, self._uninstaller.preview_uninstall(pack_id)

    def uninstall(self, pack_id: str, confirmed: bool = False) -> tuple[int, dict]:
        if self._uninstaller is None or self._manifest_for(pack_id) is None:
            return 404, {"error": f"unknown pack {pack_id!r}"}
        code, payload = self._uninstaller.uninstall(pack_id, confirmed=confirmed)
        if code == 200:
            self._disabled_models.discard(
                self._manifest_for(pack_id).model_id)
        return code, payload

    def is_model_disabled(self, model_name: str) -> bool:
        """包卸载中/已完成的路由禁用查询 — 新请求 503 的判定依据。"""
        return model_name in self._disabled_models

    # ── 钩子 ──

    def _write_model_config(self, pack_dir, manifest) -> None:
        port = _free_port()
        cfg = build_model_config(manifest, pack_dir, port=port)
        try:
            write_managed_yaml(cfg, self.models_d, manifest)
        except ConfigExistsError:
            log.info("pack config already exists: %s", manifest.pack_id)

    def _reload(self) -> None:
        if self._reload_gateway is not None:
            self._reload_gateway()

    # ── 查询 ──

    def catalog_payload(self) -> dict:
        return {"packs": [{
            "pack_id": e.manifest.pack_id,
            "display_name": e.display_name,
            "summary": e.summary,
            "tags": list(e.tags),
            "capability": e.manifest.capability,
            "builtin": e.builtin,
            "risk_level": e.risk_level,
            "manifest": e.manifest.to_dict(),
        } for e in self.catalog.entries]}

    def status_payload(self) -> dict:
        packs = [self._rec_payload(r) for r in self.store.all()]
        with self._progress_lock:
            for pack_id, stage in self._in_progress.items():
                for p in packs:
                    if p["pack_id"] == pack_id:
                        p["status"] = stage
                if all(p["pack_id"] != pack_id for p in packs):
                    packs.append({"pack_id": pack_id, "status": stage,
                                  "stage": stage, "error": None,
                                  "sandbox_degraded": False,
                                  "pack_version": "", "installed_at": None})
        return {"packs": packs}

    def _rec_payload(self, rec) -> dict:
        d = {"pack_id": rec.pack_id, "pack_version": rec.pack_version,
             "status": rec.status, "stage": rec.stage, "error": rec.error,
             "sandbox_degraded": rec.sandbox_degraded,
             "installed_at": rec.installed_at, "affected_pools": []}
        return d

    # ── 安装 ──

    def start_install(self, pack_id: str) -> tuple[int, dict]:
        entry = self.catalog.find(pack_id)
        if entry is None:
            return 404, {"error": f"unknown pack_id {pack_id!r}"}
        with self._progress_lock:
            if pack_id in self._in_progress:
                return 409, {"error": f"install already in progress for "
                                      f"{pack_id!r}"}
            self._in_progress[pack_id] = "preflight"
        t = threading.Thread(target=self._run_install, args=(entry,),
                             daemon=True, name=f"pack-install-{pack_id}")
        t.start()
        return 202, {"pack_id": pack_id, "status": "preflight"}

    def _run_install(self, entry) -> None:
        pack_id = entry.manifest.pack_id
        try:
            res = self.installer.install(entry)
        except Exception as exc:   # 不让线程带异常消失
            res_ok, stage, err = False, "failed", \
                f"internal_error:{type(exc).__name__}"
        else:
            res_ok, stage, err = res.ok, res.stage, res.error
        import time
        now = int(time.time())
        if res_ok:
            self.store.set(PackRecord(
                pack_id=pack_id, pack_version=entry.manifest.pack_version,
                status="installed", stage="installed", error=None,
                sandbox_degraded=res.sandbox_degraded, installed_at=now))
        else:
            self.store.set(PackRecord(
                pack_id=pack_id, pack_version=entry.manifest.pack_version,
                status="failed", stage=stage, error=err,
                sandbox_degraded=False, installed_at=None))
        with self._progress_lock:
            self._in_progress.pop(pack_id, None)
        self._reload()

    # ── 策略 ──

    def policy_get(self) -> tuple[int, dict]:
        p = self.policy.load()
        return 200, {"max_model_parameters_b": p.max_model_parameters_b,
                     "system_reserved_memory_mb": p.system_reserved_memory_mb}

    def policy_put(self, body: dict) -> tuple[int, dict]:
        if not isinstance(body, dict):
            return 400, {"error": "body must be an object"}
        try:
            cur = self.policy.load()
            p = PackPolicy(
                max_model_parameters_b=int(body.get(
                    "max_model_parameters_b", cur.max_model_parameters_b)),
                system_reserved_memory_mb=int(body.get(
                    "system_reserved_memory_mb",
                    cur.system_reserved_memory_mb)))
        except (TypeError, ValueError):
            return 400, {"error": "policy values must be integers"}
        if p.max_model_parameters_b < 1:
            return 400, {"error": "max_model_parameters_b must be >= 1"}
        lo, hi = POLICY_MEM_RANGE
        if not lo <= p.system_reserved_memory_mb <= hi:
            return 400, {"error": f"system_reserved_memory_mb must be in "
                                  f"[{lo}, {hi}] MiB"}
        self.policy.save(p)
        return 200, {"max_model_parameters_b": p.max_model_parameters_b,
                     "system_reserved_memory_mb": p.system_reserved_memory_mb}


def reconcile_on_boot(store: PackStore, root) -> list[str]:
    from inferfabric.packs.store import reconcile
    fixed = reconcile(store, root)
    if fixed:
        log.warning("pack store reconciled on boot: %s", fixed)
    return fixed


# ── 进程级单例（handler 使用；测试经 reset_pack_manager 重置） ──

_manager: PackManager | None = None
_manager_lock = threading.Lock()


def get_pack_manager(catalog_path=None) -> PackManager:
    global _manager
    with _manager_lock:
        if _manager is None:
            import os
            state_dir = Path(os.environ.get(
                "MACFABRIC_STATE_DIR", str(Path.home() / ".inferfabric")))
            models_dir = Path(os.environ.get(
                "MACFABRIC_MODELS_DIR", "macfabric_gateway/models.d"))
            _manager = PackManager(root=state_dir / "packs",
                                   models_d=models_dir,
                                   catalog_path=catalog_path)
        return _manager


def reset_pack_manager() -> None:
    global _manager
    with _manager_lock:
        _manager = None
