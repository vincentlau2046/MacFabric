# A 基础合同与调用 ID 硬切 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 封闭生产穿透，建立统一产品资料与可恢复、权限不扩大的公开 ID 硬切。

**Architecture:** 保留内部 ModelConfig.name；新 product 域投影资料和公开身份。迁移协调器统一维护锁、CAS、私有快照与恢复日志，复用 SecurityAdmin 强保护和各领域写接口。

**Tech Stack:** Python、pytest、dataclass、YAML、SQLite、macOS 子进程隔离。

**Spec:** `docs/superpowers/specs/2026-11-16-product-definition-v2.md` §§3–4、9；总计划 `2026-11-16-product-upgrade.md`。

## Global Constraints

- 当前仅文档落盘，所有实施步骤未执行；实施需用户审核本计划。
- 调用 ID 同步硬切，不保留旧 ID 路由别名；内部生命周期身份和历史日志保留。
- 开发 8998、生产 8999；禁止直接写生产 DB，禁止全局 pkill proxy.handler。
- 保持鉴权开启；不保存/输出真实密钥到文档、测试证据或示例。
- 未获明确要求不 commit/push；生产维护/迁移点另报备。

## Review Focus

- 拷贝来的 dev YAML 仍指向 prod 绝对路径或硬链接，须启动失败（A1）。
- 现有 canonical ID 与旧 accepted 集合重叠，不能错误退役（A2/A4）。
- scope 含未知值或跨 namespace 冲突，禁止降为 NULL/全权限（A3）。
- 预览后改配置、并发 key 操作、半写断电，拒绝或恢复，不能半新半旧（A3）。
- 旧 ID 已有缓存、messages 与非聊天端点，不能绕过 strict resolver（A4）。

---

## 文件责任

新增 `inferfabric/product/__init__.py`、`identity.py`（资料/命名）、`migration.py`（协调器）、`maintenance.py`（准入锁）、`inferfabric/isolation.py`（路径/环境/启动边界）。新增均位于 `macfabric_gateway/`。

修改 config/manager/proxy_manager、proxy handler/chat_handlers/response_cache、security key_store/admin、packs schema/catalog/config_gen、process_manager/llama_cpp、两种 dev 启动脚本；不做全仓无关拆分。

公共 DTO 在 A2 定义；后续 B/C 只能扩充该合同，不能再起前端命名转换器。

### Task A1: 开发资产和引擎执行隔离

**Files:**
- Create: `macfabric_gateway/inferfabric/isolation.py`
- Modify: `scripts/dev-gateway.sh`、`scripts/sandbox-gateway.sh`
- Modify: `macfabric_gateway/inferfabric/process_manager/llama_cpp.py`、`packs/runtime_prep.py`、`packs/sandbox.py`、`packs/supervisor.py`（均在 inferfabric 下）
- Test: `macfabric_gateway/tests/unit/test_environment_isolation.py`、既有 `test_packs_sandbox.py`

**Interfaces:**
- `validate_dev_layout(paths: dict[str, Path], production_root: Path) -> None`：realpath＋inode 检查；包含配置引用的权重/引擎路径、写根和 runtime 链。
- `engine_environment(source: Mapping[str, str]) -> dict[str, str]`：白名单 PATH/HOME/TMPDIR 与已验证必要 Metal 系统变量；HOME/TMPDIR 指向隔离受控根，不带云 key。
- `IsolationEvidence(enforced: bool, mechanism: str, reason: str | None)`：必须由执行探针产生，不靠符号存在；既有 provider 在正式/试加载两处实际应用。
- 开发统一根 `~/.inferfabric-dev`；sandbox 脚本转为该隔离启动器入口，不再软链生产。端口占用返回失败，不杀占用者。

- [ ] **Step 1: RED 测试。** `test_dev_rejects_symlink_and_hardlink_to_prod`、`test_copied_yaml_with_prod_runtime_rejected`、`test_both_engine_spawns_use_loopback_and_scrub_secrets`、`test_symbol_probe_is_not_enforcement`；断言生产哨兵 hash 不变、拒绝发生在 spawn 前、命令不含 0.0.0.0、环境无 fixture CLOUD_KEY。探针真写越界路径/连禁止网络失败才可 enforced=true。
- [ ] **Step 2: 运行 RED。** 根目录运行 `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_environment_isolation.py macfabric_gateway/tests/unit/test_packs_sandbox.py -v`；预期行为断言失败，不接受依赖缺失/导入错误充当 RED。
- [ ] **Step 3: 实现边界。** 接上路径检查、loopback、环境白名单、provider 与 supervisor 限制；移除 scripts 的共享 packs/池/云配置。无法强制的沙箱如实 degraded 并服从既有准入，不假写 false。rlimit、并发与清理必须落 spawn，不只是计算数值。
- [ ] **Step 4: 同命令 GREEN＋总计划全量测试。** 用两棵临时根证明 install/uninstall/failure 不改生产哨兵。真实 macOS enforcement 探针在获准执行后单独记录；未通过不得宣称强隔离。
- [ ] **Step 5: 审查检查点。** 核对 diff 与生产零改动，记录日志/警告；不自动提交。

### Task A2: 显式身份和资料贯通

**Files:**
- Create: `macfabric_gateway/inferfabric/product/identity.py`、`__init__.py`
- Modify: `macfabric_gateway/inferfabric/config.py`、`manager.py`、`packs/schema.py`、`packs/catalog.py`、`packs/config_gen.py`
- Test: `macfabric_gateway/tests/unit/test_product_identity.py`、`test_packs_schema.py`、`test_packs_config_gen.py`

**Interfaces:**
- `ModelIdentity(instance_id: str, display_name: str, api_model_id: str)`；`validate_api_model_id(value: str) -> str` 按 spec 正则/96字符/保留前缀验证，仅用于本地。
- `product_record(model: ModelConfig, metadata: Mapping[str, object]) -> dict[str, object]`：输出 spec §3.2 的 DTO，未知 nullable；资源/能力证据由元数据输入，不抓网猜。
- `ModelConfig` 新增 nullable `display_name`、`api_model_id`；`instance_id` 投影现有 name，不重复持久化冲突键。已迁移配置显式 api_model_id 必须等于引擎 served_name/alias；不一致验证失败。
- PackManifest 新增 `product` 结构（包含 display_name/api_model_id/publisher/family/variant/capabilities）；parameter_count_b 改有限非负数值、拒 bool/NaN/Inf。严格 parser 白名单/to_dict/catalog 入口/fixtures 同步更新。未迁移旧 manifest 可解析以预览，但不可绕过迁移自动变成规范部署。
- 产品 DTO 中 resources 键：`parameter_count_b`、`download_mb`、`disk_mb`、`peak_memory_mb`、`configured_context`、`theoretical_context`、`measurement`；source 与 verification 绑定摘要和证据引用。

- [ ] **Step 1: RED。** `test_identity_not_guessed_from_pack_slug` 断言 BGE-M3/instance旧名/api bge-m3；`test_fractional_parameters_roundtrip` 断言0.6与1.7不变；`test_api_name_collision_and_reserved_prefix_rejected`；`test_unknown_metadata_is_not_chat_or_zero`；`test_existing_lifecycle_and_explicit_idle_30_preserved`。另测同名两实例不同ID、false/NaN拒绝、旧manifest仍可进预览但未晋级。
- [ ] **Step 2: 运行 RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_product_identity.py macfabric_gateway/tests/unit/test_packs_schema.py macfabric_gateway/tests/unit/test_packs_config_gen.py -v`；预期合同断言失败。
- [ ] **Step 3: 实现资料合同。** catalog→manifest→managed YAML→manager `/models` 同源；不改旧内部文件名；新增默认按 spec，既有显式用户策略不重置。public 路由切换在 A4，不在此偷偷启用 fallback。
- [ ] **Step 4: 同命令 GREEN＋全量。** 验证 strict unknown-field 测试仍有效、管理生命周期仍接受 instance_id；生产文件未访问。
- [ ] **Step 5: 审查检查点。** 固定 DTO fixtures 供 B1、C1 使用，不自动提交。

### Task A3: 受保护、可恢复的迁移领域

**Files:**
- Create: `macfabric_gateway/inferfabric/product/migration.py`、`maintenance.py`
- Modify: `macfabric_gateway/inferfabric/security/key_store.py`、`security/admin.py`、`model_pool/registry.py`、`proxy/handler.py`、`proxy_manager.py`
- Test: `macfabric_gateway/tests/unit/test_identity_migration.py`、`test_identity_migration_auth.py`

**Interfaces:**
- `IdentityMigrationCoordinator.preview(mapping: dict[str, ModelIdentity]) -> dict` 返回 `preview_id`、`input_revision`（各输入SHA/revision的总摘要）、`mapping`、`retired_ids`、`affected_counts`、`blockers`。映射键为 instance_id，旧接受集合由配置事实枚举，不由请求者任意指定。
- `apply(preview_id: str, input_revision: str, *, confirmed: bool) -> dict`、`recover() -> dict`、`rollback(migration_id: str, *, confirmed: bool) -> dict`；错误用稳定 code：conflict/blockers/maintenance_timeout/recovery_required。返回不含密钥、digest或私有备份正文。
- `MaintenanceGate` 用于推理在途计数与所有配置/包/池/KeyStore写操作互斥；`enter(timeout_s=180)` 超时不改数据，新请求503 maintenance；配置被外部改写时摘要重核对失败。
- `KeyStore.rewrite_model_scopes(mapping: dict[str, str], *, expected_revision: str) -> None`：事务内精确替换、保序去重；已确认不改名的fabric/cloud scope原样保留，无法识别/歧义scope阻断；NULL保留NULL、撤销/过期/策略/摘要不变。KeyStore 提供 `migration_revision() -> str`、`backup_to(path: Path) -> None`、`restore_from(path: Path) -> None`，在线备份/恢复归 KeyStore 所有，不走外部 sqlite 脚本。
- 池引用由 `snapshot_and_raw()` 读取，使用 revision-aware 领域迁移方法 `rewrite_local_model_refs(mapping: dict[str,str], expected_revision: int) -> RegistrySnapshot`，只改 kind=local 的 model_name，保留未知/云候选和额外原始字段；迁移专用写法不得因严格新建校验而丢历史异常候选。
- 新 POST `/admin/keys/identity-preview`、`identity-apply`、`identity-rollback`；在 SecurityAdmin 的会话/Host/Origin/CSRF 检查之后调用协调器。preview也要求保护；无安全服务时503，不降级到无token管理通道。请求 body ≤16384 bytes。
- journal 在隔离 state 的 `identity-migrations/<id>/`，0700目录/0600文件；prepared/applied/committed/rolled_back/recovery_required。启动 `recover()` 在监听推理前执行。

- [ ] **Step 1: RED。** `test_preview_enumerates_internal_and_served_ids`、`test_unmapped_scope_blocks_no_privilege_widening`（NULL/scoped/revoked/expired四类，digest不变）、`test_pool_raw_unknown_candidates_preserved`、`test_revision_change_refuses_apply`（配置/池/key分别改）、`test_no_session_bad_origin_or_csrf_denied`（仅Bearer也拒绝）、`test_drain_timeout_does_not_write`、`test_crash_after_each_boundary_recovers_consistently`（monkeypatch真实文件/领域写边界抛错，不加生产测试后门）、`test_startup_refuses_half_applied_state`。每个崩溃点验证全部恢复旧合同或全部提交新合同，绝无混合权限。
- [ ] **Step 2: 运行 RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_identity_migration.py macfabric_gateway/tests/unit/test_identity_migration_auth.py -v`；预期迁移/保护断言失败。
- [ ] **Step 3: 实现领域与保护。** 先维护互斥，再重核对/一致性备份/准备日志/fsync，再分域写与重载验证，最后提交日志再开放。失败关门，恢复通过才重开。并发写和快照恢复有真实锁；维护期不提供绕过的“强制继续”。为现有安全管理客户端增加受保护预览/确认入口说明，不增加公共无认证迁移 CLI。
- [ ] **Step 4: 同命令 GREEN＋全量。** 所有 fixture key在临时 security.db 创建；检查权限/日志脱敏、完整回滚、重复apply幂等/已提交冲突，永不碰生产DB。
- [ ] **Step 5: 审查检查点。** 输出脱敏迁移矩阵与恢复流程；生产 apply 仍为未执行。

### Task A4: 全公开路由严格解析与缓存封口

**Files:**
- Modify: `macfabric_gateway/inferfabric/product/identity.py`、`manager.py`、`proxy_manager.py`、`proxy/handler.py`、`proxy/chat_handlers.py`、`proxy/response_cache.py`、`packs/config_gen.py`
- Test: `macfabric_gateway/tests/unit/test_public_model_ids.py`、`test_identity_migration.py`

**Interfaces:**
- `resolve_public_model(api_model_id: str) -> ModelConfig | None` 仅精确 canonical ID；内部 `get_model(instance_id)` 不变；删公共 find_model_by_served_name 内部名回退或把调用方全部迁到 strict 接口，不能遗留第二公开解析路径。
- `model_to_service` 只映射 canonical→instance；auth 接受同一个 canonical 名（不再 split('/')[-1] 改 scope 语义）。云ID和fabric池维持各自既有合同，不套本地正则。
- `ResponseCache.advance_identity_epoch() -> None`：迁移提交/回滚清旧缓存；公开请求先按既有策略auth，再解析合法模型，再查缓存。不得以缓存命中绕过存在性/身份校验。
- `/v1/models` 按已部署/实际支持过滤，不按“是否有其他模型active”选不同全集；ID与能力列表一致。

- [ ] **Step 1: RED。** 四端点参数化：合法新ID成功、同一合法key对退役ID404；预灌旧缓存仍404；缺key401；原本canonical仍成功；fabric/cloud不误退役；scoped key不允许其他新ID；本地生命周期旧instance仍可控制。`test_installed_models_listing_stable_across_active_changes` 断言开关另一模型不删目录。
- [ ] **Step 2: 运行 RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_public_model_ids.py macfabric_gateway/tests/unit/test_identity_migration.py -v`；预期内部名仍可路由/缓存越过校验的行为失败。
- [ ] **Step 3: 统一 public resolver。** 更新 chat/messages/embedding/rerank、引擎alias、池候选验证和scope；包装层保持既有错误信封。证据绑定 migration epoch，缺资料的旧部署进入迁移阻断而非自动别名。
- [ ] **Step 4: 同命令 GREEN＋全量。** 在独立8998演练preview→apply→新请求→旧请求拒绝→重启恢复→rollback；真实模型请求需另获长链执行授权，单测不能冒充真实语义。
- [ ] **Step 5: 审查检查点。** 交接 product DTO 和迁移报告给 B/C/D；不执行生产硬切。
