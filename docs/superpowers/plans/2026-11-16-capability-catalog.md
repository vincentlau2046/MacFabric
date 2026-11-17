# C 能力目录与用户扩展 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 以一套可信安装合同支持四类模板、12型号候选与用户链接导入。

**Architecture:** 官方/自定义/本机发现入口只生成安装候选，共用事务与独立runtime依赖。由固定runtime的分型模板生成正式启动和验证配置，逐产物证据驱动目录晋级。

**Tech Stack:** Python、GGUF元数据、llama.cpp Metal、流式HTTPS下载、YAML manifest、pytest与语义fixtures。

**Spec:** `docs/superpowers/specs/2026-11-16-product-definition-v2.md` §§7–10；统一能力架构既有裁决。

## Global Constraints

- 当前仅文档落盘，所有实施步骤未执行；实施需用户审核本计划。
- 默认 LLM/VL ≤4B；预算 `B = RAM − reserve`，env ＞ policy ＞ 8192 MiB；设置唯一编辑入口。
- 模型源 ModelScope；引擎回归基线 b12361；新引擎版本另冻；Gemma/Whisper 既有源与许可裁决不变。
- 开发 8998、生产 8999；禁止直接写生产 DB，禁止全局 pkill proxy.handler。
- 保持鉴权开启；下载与真实模型长链需预检预算/超时/监视/停止/终态。
- 未获明确要求不 commit/push；候选不是支持，不凑12个“已验证”。

## Review Focus

- 官方installer读 `_reload_gateway` 而装配写另一字段，需实际安装完成免重启（C1）。
- donor runtime卸载、并发安装/取消/断电，不能破坏其他模型或假installed（C1）。
- IPv6/重定向/DNS重绑定/无Content-Length/整文件hash，拒绝或限额不爆内存（C3）。
- GGUF魔数正确却类型/参数/投影错误，不能靠health 200晋级（C2/C3）。
- 产物/引擎变了还显示旧passed、BGE dense冒充sparse，证据绑定防误宣传（C4）。

---

## 文件责任

新增 `inferfabric/packs/transaction.py`、`runtime_store.py`、`templates.py`、`verification.py`、`metadata.py`、`url_policy.py`（均在 `macfabric_gateway/` 下）；修改既有installer/custom/config_gen/runtime_prep/schema/catalog/pack_handlers，不并行维护另一套安装实现。运行资料沿用A2，公开ID沿用A4。

### Task C1: 共用安装事务和独立运行时

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/transaction.py`、`runtime_store.py`
- Modify: `macfabric_gateway/inferfabric/packs/installer.py`、`custom.py`、`store.py`、`uninstaller.py`、`runtime_prep.py`
- Modify: `macfabric_gateway/inferfabric/proxy/pack_handlers.py`
- Test: `macfabric_gateway/tests/unit/test_pack_transaction.py`、`test_runtime_store.py`、`test_packs_wiring.py`、`test_packs_e2e_fake.py`

**Interfaces:**
- `InstallCandidate(manifest: PackManifest, source_kind: str)`：source_kind=official/user/local；内部规范化为同一manifest，不允许入口跳过预检。
- `InstallTransaction.run(candidate: InstallCandidate) -> InstallResult`；安装阶段严格为preflight/downloading/verifying/preparing/checking/configuring/reloading/installed；末态失败/取消保留原因和可恢复journal。
- `PackInstaller.set_reload_gateway(fn: Callable[[], None]) -> None` 明确更新installer实际读取字段；PackManager仅调用此setter，不直接写动态属性。
- `RuntimeStore.acquire(runtime_id: str, sha256: str) -> RuntimeLease`（独立受控runtime根、inflight pin）、`commit_reference(lease, pack_id: str) -> None`、`release_reference(pack_id: str) -> None`；引用变更和回收有锁/日志，路径不指向另一模型包。具体产物由固定清单，不根据用户URL推断engine代码。
- 安装并发默认1个事务（可排队）、全局资源预算在真实写入/加载前重新确认；同包互斥。取消只在可回滚阶段受理，重启恢复未完成journal。

- [ ] **Step 1: RED。** `test_official_install_reloads_real_manager_without_restart` 必须走installer.install→实际装配回调→查询管理器新模型，而非只调用PackManager._reload；`test_user_and_official_share_preflight`；`test_uninstall_donor_does_not_break_other_runtime`；`test_cancel_failure_restart_leave_no_controlled_residue`；`test_pending_install_pins_runtime`；`test_global_install_budget_serializes`；`test_degraded_truthful_not_false`。测试不访问生产store。
- [ ] **Step 2: 运行RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_pack_transaction.py macfabric_gateway/tests/unit/test_runtime_store.py macfabric_gateway/tests/unit/test_packs_wiring.py macfabric_gateway/tests/unit/test_packs_e2e_fake.py -v`；预期官方回调/共用门禁断言失败。
- [ ] **Step 3: 实现事务。** 复用已有安全下载/原子文件/安装/卸载组件，删除custom平行链；runtime依赖独立，旧donor软链迁移仅在受控事务中处理，保留用户权重；安装最终必须校验registry/YAML/manager一致后才能installed。接A1路径/执行隔离和A3维护锁。
- [ ] **Step 4: 同命令GREEN＋全量。** 注入每阶段失败/取消/重启；复验官方和用户两条入口，不以一次fixture热加载盖过另一条。
- [ ] **Step 5: 审查检查点。** 记录状态机/恢复/引用测试证据，无真实下载、无生产改动。

### Task C2: 四类型模板与语义验证合同

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/templates.py`、`verification.py`
- Modify: `macfabric_gateway/inferfabric/packs/config_gen.py`、`runtime_prep.py`、`schema.py`、`process_manager/llama_cpp.py`（process_manager在inferfabric下）
- Create: `macfabric_gateway/tests/semantic/fixtures/{chat,embedding,rerank,vision}.json`
- Test: `macfabric_gateway/tests/unit/test_capability_templates.py`、`test_capability_verification.py`

**Interfaces:**
- 模板ID：保留`llama_cpp_chat_v1`；新增`llama_cpp_embedding_v1`、`llama_cpp_rerank_v1`、`llama_cpp_vision_v1`。后端registry提供支持状态给UI，不再前端白名单。
- `build_launch_spec(manifest: PackManifest, pack_dir: Path, port: int) -> LaunchSpec`，含argv/env/isolation/artifact_paths；试加载与正式spawn消费同一规格，避免检查时不带正式context/Metal/mmproj/pooling。
- `verify_capability(client, manifest: PackManifest, fixtures_dir: Path) -> VerificationResult`，含status/evidence/engine_sha/artifact_shas/errors；模板未实现或引擎版本不支持必须拒绝，不落假installed。
- embedding配置包含pooling、normalize、dimension、query/document格式；rerank配置包含BGE输入与分数方向；VL包含匹配mmproj摘要/家族检查。未知不能静默用chat模板。

- [ ] **Step 1: RED。** `test_template_flags_same_for_probe_and_formal_spawn`；`test_embedding_pooling_normalization_and_dimensions`；`test_bge_rerank_score_index_contract`；`test_vision_requires_matching_projector`；`test_unknown_template_not_installable`；`test_empty_content_reasoning_only_fails_chat`。fixture判定：chat问2+2须正文包含4、流式有终态；embedding查询“猫在窗边睡觉”，相关文档cos高于“数据库索引优化”；rerank同样语料相关文档index排首、分数有限且映射不变；vision用固定红圆蓝方图片问红色形状，须识别圆而非方。模型生成代码只AST/静态判断，不无隔离执行。
- [ ] **Step 2: 运行RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_capability_templates.py macfabric_gateway/tests/unit/test_capability_verification.py -v`；预期类型/语义断言失败。此处fixture响应只验判定器，不冒充模型真推理。
- [ ] **Step 3: 实现registry与统一启动规格。** 按固定b12361真实CLI/API能力决定flags；不支持的型号返回adaptation_required并阻断，若需升级另交报告。resource校验涵盖完整配置峰值，不用极小probe掩盖正式加载风险。
- [ ] **Step 4: 同命令GREEN＋全量。** 负例覆盖错误维度/NaN/乱序/错误投影/空正文/流式中断；为D2提供同一组语义fixtures与真实runner接口。
- [ ] **Step 5: 审查检查点。** 冻结模板/fixture/hash，不在此宣称12型号已支持。

### Task C3: 安全链接识别与旧导入归一

**Files:**
- Create: `macfabric_gateway/inferfabric/packs/metadata.py`、`url_policy.py`
- Modify: `macfabric_gateway/inferfabric/packs/custom.py`、`proxy/pack_handlers.py`（proxy在inferfabric下）、已有下载器实际使用点
- Modify: `macfabric-app/Sources/MacFabricApp.swift` CustomPackCard/LocalDiscoverCard
- Test: `macfabric_gateway/tests/unit/test_custom_metadata.py`、`test_custom_url_policy.py`、`test_packs_custom.py`

**Interfaces:**
- `inspect_model_source(url: str) -> ImportPreview`：preview_id、来源文件元数据/摘要、识别类型/参数/缺失依赖、eligibility、warnings、input_revision；通过受限HEAD/Range读取，不为预览整包下载。无法安全识别明示unknown/blocked。
- `read_gguf_metadata(stream: BinaryIO, *, max_metadata_bytes: int) -> dict`：首版上限16 MiB元数据，超限拒绝；检查文件声明计数/偏移/字符串长度，参数量不以体积猜。必要完整文件分析仍在确认后受控下载阶段做。
- `validate_download_target(url: str, resolved_addresses: tuple[str, ...]) -> None`；每跳检查并在实际连接绑定经校验目的IP，TLS仍验证原host，不能仅预检DNS后让下载器再次自由解析。
- 新 POST `/admin/packs/custom/preview`；现custom提交新增preview_id/input_revision/confirmed，最终仍由C1.run执行。旧调用缺预览返回明确`preview_required`，不悄悄走原链。
- 本机导入通过受控文件复制/元数据识别→同候选事务，不执行文件；非支持Ollama/vLLM格式明确拒绝并移除旧直接YAML导入动作。

- [ ] **Step 1: RED。** `test_redirect_ipv6_private_rebinding_and_url_credentials_denied`；`test_unknown_length_stream_capped_at_32_gib`（用小测试限额同算法）；`test_hash_stream_not_read_all`；`test_truncated_or_oversized_gguf_metadata_rejected`；`test_fractional_parameters_not_size_guess`；`test_vl_missing_projector_blocked`；`test_policy_memory_disk_before_large_download`；`test_stale_preview_requires_reconfirm`；`test_local_import_never_bypasses_transaction`。错误样本不被执行。
- [ ] **Step 2: 运行RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_custom_metadata.py macfabric_gateway/tests/unit/test_custom_url_policy.py macfabric_gateway/tests/unit/test_packs_custom.py -v`；预期旧链安全/预检断言失败。
- [ ] **Step 3: 实现预览和共用提交。** 下载前磁盘/策略/资源门禁，流式摘要/限额/超时；32 GiB沿用上限但仍受可用磁盘约束。完整元数据再核对预览，一致后按类型验证/注册/热加载。用户添加源与官方ModelScope规则区分：本轮不默默更换官方源，用户明确输入的HTTPS源仍须安全检查与许可提示。
- [ ] **Step 4: 同命令GREEN＋全量＋Swift契约测试。** `bash scripts/test-app-contracts.sh`；隔离fixture验证从链接预览到目录出现/无需重启/卸载；真实下载另申请预算。
- [ ] **Step 5: 审查检查点。** UI不用pack slug作用户输入，无法识别时只问缺失资料，不假称全自动。

### Task C4: 逐型号冻结与晋级

**Files:**
- Modify: `macfabric_gateway/packs_catalog.yaml`
- Create: `docs/qa/product-v2/catalog-evidence.md`
- Test: `macfabric_gateway/tests/unit/test_catalog_promotion.py`
- Consume: A2 DTO、C2模板与验证结果、D2真实runner。

**Interfaces:**
- 每条晋级证据：display_name/api_model_id、变体、source_url/license/转换说明、model/mmproj/runtime各SHA256、参数/上下文、下载/磁盘、Mac机型/内存/峰值、模板、semantic run_id、隔离/鉴权/免重启结果。
- `validate_catalog_promotion(entry: CatalogEntry, evidence: dict) -> list[str]`；passed只能在证据摘要全部对应且无阻断时发布；pending/failed条目保持不可误安装的状态与原因。

- [ ] **Step 1: RED。** `test_all_twelve_targets_have_explicit_identity`（按spec逐项枚举，不只断言len=12）；`test_changed_runtime_or_weights_invalidates_passed`；`test_missing_source_license_projector_or_semantics_blocks_promotion`；`test_bge_dense_not_claimed_sparse`；`test_gemma_and_whisper_not_reintroduced`。
- [ ] **Step 2: 运行RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_catalog_promotion.py -v`；预期目录资料/晋级合同断言失败。
- [ ] **Step 3: 先冻结文件清单再申请真实执行。** 文本6、嵌入3、重排1、视觉2逐型核查ModelScope产物/许可/摘要，先每型一个变体；不能编造hash或把链接可达当支持。计划外引擎升级与OCR/ASR/TTS/aigc单列报告再审。
- [ ] **Step 4: 获准后每型跑D2单模型真实链。** 通过才更新verification及证据；失败保留候选/失败原因，不换型号凑数；完成后同单测GREEN＋全量测试。没有真实证据时Task C4保持未完成，即使目录数据单测已绿。
- [ ] **Step 5: 审查检查点。** 提交12行真实进度矩阵与剩余阻断，明确首批实际交付数量；不自动发布。
