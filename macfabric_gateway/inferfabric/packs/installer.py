"""安装事务 — PK1（Task 5）。

状态机（spec §7.1）：
  preflight → staging → downloading → verifying → preparing_runtime
  → writing_config → isolated_healthcheck → gateway_reload → installed

事务规则：
- 所有下载/构建先放 <root>/_staging/<pack_id>/，.part 永不执行或注册。
- sha256 在 staging 内逐 artifact 校验后才移入正式目录（TOCTOU 安全：
  下载→校验→启用之间无窗口）。
- hash/运行时准备/健康检查/配置写入/reload 全部成功才 commit。
- 任一阶段失败：删 staging（及未提交的 pack_dir），不动已安装包，
  不写半成品 models.d；错误为阶段化固定码，原文不带上游内容。
- 上次崩溃残留的 staging 在下次安装开始时清理。
- 沙箱准入（spec §8.3）：探测 ≠ full 且 degraded_install_allowed=False
  → 拒绝；允许降级 → 安装继续并显式标记 sandbox_degraded。
"""

import hashlib
import shutil
import threading
from dataclasses import dataclass
from pathlib import Path

INSTALL_STAGES = ("preflight", "staging", "downloading", "verifying",
                  "preparing_runtime", "writing_config",
                  "isolated_healthcheck", "gateway_reload", "installed")

# 升级回退窗口：新版本切换成功后保留的旧版本数（spec §7.4 裁决）
UPGRADE_KEEP_PREVIOUS = 1


@dataclass
class InstallResult:
    ok: bool
    stage: str
    error: str | None = None
    pack_dir: Path | None = None
    sandbox_degraded: bool = False


def _noop(*a, **k) -> None:
    return None


class PackInstaller:
    """安装事务执行器。root 由调用方注入（生产 ~/.inferfabric/packs，
    测试 tmp_path）；真实 fetcher/hook 在 Task 8/11/12 接线。"""

    def __init__(self, root: Path, fetcher, policy, sandbox_provider,
                 catalog_probe=None, prepare_runtime=None,
                 write_model_config=None, run_healthcheck=None,
                 reload_gateway=None):
        self._root = Path(root)
        self._fetcher = fetcher
        self._policy = policy
        self._sandbox_provider = sandbox_provider
        self._catalog_probe = catalog_probe
        self._prepare_runtime = prepare_runtime or _noop
        self._write_model_config = write_model_config or _noop
        self._run_healthcheck = run_healthcheck or _noop
        self._reload_gateway = reload_gateway or _noop
        self._locks: dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()

    def _lock_for(self, pack_id: str) -> threading.Lock:
        with self._locks_guard:
            return self._locks.setdefault(pack_id, threading.Lock())

    # ── 目录布局 ──

    def _staging_dir(self, pack_id: str) -> Path:
        return self._root / "_staging" / pack_id

    def pack_dir_for(self, manifest) -> Path:
        return self._root / manifest.pack_id / manifest.pack_version

    def _artifact_rel(self, artifact) -> Path:
        if artifact.kind == "model":
            return Path("models") / artifact.id
        return Path("runtime") / artifact.id

    # ── 阶段 ──

    def _preflight(self, entry) -> tuple[bool, str | None, bool]:
        manifest = entry.manifest
        self._root.mkdir(parents=True, exist_ok=True)
        policy = self._policy.load()
        if manifest.capability in ("llm", "vl") and \
                manifest.parameter_count_b > policy.max_model_parameters_b:
            return False, (f"parameter_count_b {manifest.parameter_count_b} > "
                           f"max {policy.max_model_parameters_b}"), False
        if not entry.builtin:
            free = shutil.disk_usage(self._root).free
            if free < manifest.disk_mb * 1024 * 1024:
                return False, (f"disk free {free // (1024*1024)}MB < "
                               f"required {manifest.disk_mb}MB"), False
        probe = (self._catalog_probe or _noop)()
        if probe is not None and probe.mode.value != "full" and \
                not manifest.degraded_install_allowed:
            return False, (f"sandbox mode {probe.mode.value} not allowed for "
                           f"degraded_install_allowed=False"), False
        degraded = probe is not None and probe.mode.value != "full"
        return True, None, degraded

    def _verify_hashes(self, manifest, base: Path) -> str | None:
        for artifact in manifest.artifacts:
            path = base / self._artifact_rel(artifact)
            if not path.exists():
                return f"artifact_missing:{artifact.id}"
            h = hashlib.sha256()
            with open(path, "rb") as f:
                for chunk in iter(lambda: f.read(1024 * 1024), b""):
                    h.update(chunk)
            if h.hexdigest() != artifact.sha256:
                return f"artifact_sha256_mismatch:{artifact.id}"
        return None

    def _move_into_place(self, manifest, staging: Path, pack_dir: Path):
        for artifact in manifest.artifacts:
            rel = self._artifact_rel(artifact)
            src = staging / rel
            dst = pack_dir / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(str(src), str(dst))

    # ── 主事务 ──

    def install(self, entry) -> InstallResult:
        manifest = entry.manifest
        with self._lock_for(manifest.pack_id):
            return self._install_locked(entry)

    def upgrade(self, entry) -> InstallResult:
        """升级 = 新版本目录走完整事务（含健康检查），全部成功才切换。

        spec §7.4 裁决：不做原地替换；失败时已装旧版不动、staging 清理；
        成功后仅保留 UPGRADE_KEEP_PREVIOUS 个旧版本作回退窗口。
        """
        manifest = entry.manifest
        with self._lock_for(manifest.pack_id):
            res = self._install_locked(entry)
            if not res.ok:
                return res
            pack_root = self._root / manifest.pack_id
            old_versions = sorted(
                d.name for d in pack_root.glob("*")
                if d.is_dir() and d.name != manifest.pack_version)
            excess = old_versions[:-UPGRADE_KEEP_PREVIOUS] if \
                len(old_versions) > UPGRADE_KEEP_PREVIOUS else []
            for old in excess:
                shutil.rmtree(pack_root / old, ignore_errors=True)
            return res

    def _install_locked(self, entry) -> InstallResult:
        manifest = entry.manifest
        staging = self._staging_dir(manifest.pack_id)
        pack_dir = self.pack_dir_for(manifest)
        sandbox_degraded = False

        def fail(stage: str, error: str) -> InstallResult:
            shutil.rmtree(staging, ignore_errors=True)
            if stage not in ("preflight",) and pack_dir.exists() and \
                    stage != "installed":
                # hook 失败：未提交，回滚未成形的正式目录（零残留：连空父目录）
                shutil.rmtree(pack_dir, ignore_errors=True)
                try:
                    pack_dir.parent.rmdir()  # 仅目录为空时成功
                except OSError:
                    pass
            return InstallResult(ok=False, stage=stage, error=error,
                                 sandbox_degraded=sandbox_degraded)

        # preflight
        ok, err, sandbox_degraded = self._preflight(entry)
        if not ok:
            return fail("preflight", err)
        if entry.builtin:
            shutil.rmtree(staging, ignore_errors=True)
            pack_dir.mkdir(parents=True, exist_ok=True)
            try:
                self._prepare_runtime(pack_dir, manifest)
                self._write_model_config(pack_dir, manifest)
                self._run_healthcheck(pack_dir, manifest)
                self._reload_gateway()
            except Exception as exc:
                return fail("preparing_runtime", f"builtin_hook_error:{exc}")
            return InstallResult(ok=True, stage="installed",
                                 pack_dir=pack_dir,
                                 sandbox_degraded=sandbox_degraded)

        # staging：先清上次崩溃残留
        shutil.rmtree(staging, ignore_errors=True)
        staging.mkdir(parents=True, exist_ok=True)

        # downloading
        try:
            for artifact in manifest.artifacts:
                dest = staging / self._artifact_rel(artifact)
                dest.parent.mkdir(parents=True, exist_ok=True)
                part = dest.with_suffix(dest.suffix + ".part")
                self._fetcher.fetch(artifact, part)
                part.rename(dest)
        except Exception as exc:
            return fail("downloading", f"download_error:{type(exc).__name__}")

        # verifying（staging 内校验，通过后才移动）
        err = self._verify_hashes(manifest, staging)
        if err:
            return fail("verifying", err)

        # 移入正式目录（未提交：失败仍整体回滚）
        pack_dir.mkdir(parents=True, exist_ok=True)
        self._move_into_place(manifest, staging, pack_dir)
        shutil.rmtree(staging, ignore_errors=True)

        # preparing_runtime
        try:
            self._prepare_runtime(pack_dir, manifest)
        except Exception as exc:
            return fail("preparing_runtime", f"runtime_error:{exc}")

        # writing_config
        try:
            self._write_model_config(pack_dir, manifest)
        except Exception as exc:
            return fail("writing_config", f"config_error:{exc}")

        # isolated_healthcheck
        try:
            self._run_healthcheck(pack_dir, manifest)
        except Exception as exc:
            return fail("isolated_healthcheck", f"healthcheck_error:{exc}")

        # gateway_reload
        try:
            self._reload_gateway()
        except Exception as exc:
            return fail("gateway_reload", f"reload_error:{exc}")

        # installed（commit）
        return InstallResult(ok=True, stage="installed", pack_dir=pack_dir,
                             sandbox_degraded=sandbox_degraded)
