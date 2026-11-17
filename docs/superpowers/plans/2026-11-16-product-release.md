# D 真实验收与双端发布 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 以真实语义、原生GUI与可回滚的同源双端产物证明整版交付。

**Architecture:** 测试runner先服务逐型号晋级，产物管线可独立在隔离目标测试；最终汇总门禁再批准生产晋升。成对安装先验证再切换，迁移域负责配置/权限恢复，不能仅回退程序目录。

**Tech Stack:** Python pytest/HTTP runner、Swift AppKit/Accessibility、DMG、发布manifest、SHA256、launchd（仅最终获准生产步骤）。

**Spec:** `docs/superpowers/specs/2026-11-16-product-definition-v2.md` §§4、9–10；`2026-11-16-ui-standard-v2.md` §9。

## Global Constraints

- 当前仅文档落盘，所有实施步骤未执行；实施需用户审核本计划。
- 生产只吃已验证发布产物，App 和网关同一 manifest；生产迁移、重启、安装、下载预算、对外发送单独报备。
- 开发 8998、生产 8999；禁止直接写生产 DB，禁止全局 pkill proxy.handler。
- 调用 ID 同步硬切，不保留旧 ID 路由别名；内部生命周期身份和历史日志保留。
- 原生 SwiftUI＋AppKit，不用 WebView；浏览器门禁不适用。
- 保持鉴权开启；不保存/输出真实密钥到文档、测试证据或示例。
- 未获明确要求不 commit/push，产物构建不等于对外发布授权。

## Review Focus

- App与网关同tag但不同源码/摘要/配置schema，安装前拒绝（D1）。
- 200空正文、只有reasoning、向量无语义、重排index乱，必须failed（D2）。
- AX权限拒绝/进程退出/heartbeat消失不能当仍运行或成功（D2）。
- 迁移后旧App/旧scope/新配置混合回滚，恢复协调器阻止开放（D3）。
- QA中密钥/私有配置/生产路径泄漏、未完成项目被“全绿”概括（D4）。

---

## 文件责任与时序

新增 `scripts/build-release.sh`、`release-manifest.schema.json`、`scripts/verify-capabilities.py`、`verify-native-ui.swift`；修改make-dmg/release-install/promote-install/build.sh；新增测试与QA矩阵。

**D2的runner在C2完成后即可实现并单独验收，C4随后消费它；D4才依赖C4全型号结果。** D1/D2无需等待全部模型验证，最终release的具体manifest冻结则必须等D4证据。这样没有“先全部验证才能创建验证工具”的环依赖。

### Task D1: 成对发布产物与安装拒绝门禁

**Files:**
- Create: `scripts/build-release.sh`、`release-manifest.schema.json`
- Modify: `scripts/make-dmg.sh`、`scripts/release-install.sh`、`scripts/promote-install.sh`、`macfabric-app/build.sh`
- Test: `macfabric_gateway/tests/unit/test_paired_release.py`

**Interfaces:**
- manifest字段：release_version、git_commit、app_sha256、gateway_sha256、runtime_artifacts、config_schema_version、identity_migration_version、min_compatible_app、min_compatible_gateway、verification_report_sha256。
- `build-release.sh --output <dir> --version <version>` 构建成对arm64产物；网关含固定Python/已冻结依赖，不在目标生产执行pip/uv解析。App bundle版本与commit来自相同输入，替换现0.1.0硬编码；产物内嵌该身份。
- `release-install.sh <release> --target-root <dir> --app-target <path> --dry-run`：只有验证通过才可切换；隔离测试不得接触launchd和/Applications。禁止codeload源码回退、本地git archive回退、首次从开发仓复制models.d。
- `promote-install.sh` 只委托验证后的成对安装，不再本地build＋直拷App。DMG内含同一manifest与网关/依赖资源。
- 下载渠道是用户获准的release地址；manifest/摘要必须来自受信发布记录，不能把“同站可任意改的hash”称为签名认证；Developer ID/公证条件若不满足，报告限制，不假宣称已签名。

- [ ] **Step 1: RED。** `test_mismatched_commit_app_hash_schema_rejected_before_swap`、`test_missing_artifact_never_falls_back_to_source`、`test_install_does_not_build_or_resolve_dependencies_in_prod`、`test_second_swap_failure_restores_pair`；在临时target根用假的安全文件产物，断言原两端hash不变、无launchd调用、失败退出非0。
- [ ] **Step 2: 运行RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_paired_release.py -v`；预期当前脚本缺成对验证的行为失败，不实际安装。
- [ ] **Step 3: 实现构建与安装状态机。** 验证manifest→暂存→预检schema/迁移→备份→维护/切换→健康/版本核对→提交。若迁移尚需用户确认就停止并输出待批准项，不自主执行；程序对换不代替A3权限迁移。
- [ ] **Step 4: 同命令GREEN＋全量。** 隔离路径下验证断网/校验不符/磁盘不足/中断/回退；构建真实候选产物需另获构建执行授权，不发布到外部服务。
- [ ] **Step 5: 审查检查点。** 记录成对产物可复现性与尚未满足的签名/公证条件。

### Task D2: 语义与原生验收runner

**Files:**
- Create: `scripts/verify-capabilities.py`、`scripts/verify-native-ui.swift`
- Create: `macfabric_gateway/tests/unit/test_verification_runner.py`、`macfabric-app/Tests/NativeFixtureData.json`
- Consume: C2语义fixtures/verify_capability；B3 AX标识；A1独立布局。

**Interfaces:**
- `verify-capabilities.py --base-url http://127.0.0.1:8998 --model <api_id> --capability <type> --output <private-dir>`：key只读专用 `MACFABRIC_TEST_API_KEY` 环境，子引擎不继承；不在argv/输出打印。拒绝8999。输出result.json含run_id/终态/版本摘要/各assertion；heartbeat.json每阶段/至少30秒更新，stdout只脱敏阶段与最终状态，退出0仅succeeded。
- runner `--self-test` 用fixture响应验证判定器和失败传播，不称真实推理。timeout/取消/连接断开/正文空/错误语义分别非0。
- `verify-native-ui.swift --bundle <dev-bundle> --output <private-dir>`：只接受独立dev bundle，检查AX权限；固定900×650/1200×800/1600×1000和测试数据矩阵，截图/AX检查输出result.json；权限不足返回blocked非0。VoiceOver可人工补验并记录，不伪造自动全覆盖。

- [ ] **Step 1: RED。** `test_200_empty_reasoning_only_and_wrong_semantics_fail`、`test_stream_without_terminal_fails`、`test_embedding_ranking_and_rerank_index_failures`、`test_exit_without_result_is_failure`、`test_heartbeat_timeout_alert`、`test_secret_redacted`、`test_prod_base_url_rejected`。Swift契约测试增加AX拒绝→blocked与非dev bundle拒绝。
- [ ] **Step 2: 运行RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_verification_runner.py -v` 与 `bash scripts/test-app-contracts.sh`；预期判定/权限断言失败，不接受缺工具作为功能RED。
- [ ] **Step 3: 实现runner。** 与C2复用判定逻辑，记录机型、确切变体/引擎与用例，而不是自带另一套宽松规则；监视进程退出和所有终态，180秒无heartbeat停工报警，不持续静默等待。截图必须真实原生，生产文件hash前后比较。
- [ ] **Step 4: 同命令GREEN＋self-test。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python scripts/verify-capabilities.py --self-test --output "$CLAUDE_JOB_DIR/tmp/verify-self-test"`；预期退出0且result=succeeded，通过只证明runner可用。获准后原生命令 `swift scripts/verify-native-ui.swift --bundle macfabric-app/build/MacFabric-dev.app --output "$CLAUDE_JOB_DIR/tmp/native-ui"`，预期截图矩阵/result齐全；AX未授权必须blocked并非0。真实模型运行需获准，随后供C4逐型号验证；下载/安装/取消/重启/卸载均由隔离事务执行。
- [ ] **Step 5: 审查检查点。** runner单独可验收，不等待全部12型号。交付清晰的“真实执行未运行”状态，不能写全能力已绿。

### Task D3: 硬切及成对回滚演练

**Files:**
- Create: `macfabric_gateway/tests/unit/test_release_identity_recovery.py`
- Modify: `scripts/release-install.sh` 与 A3 `macfabric_gateway/inferfabric/product/migration.py` 的恢复接线
- Create: `docs/qa/product-v2/migration-rehearsal.md`

**Interfaces:**
- `release-install.sh ... --rollback <migration_id>` 委托受保护迁移领域/离线启动恢复，不能自行SQL改scope；回滚清单绑定旧/新双端摘要、配置快照、scope备份与cache epoch。
- 迁移输入来自实际preview；客户端更新清单明确 canonical未改和退役ID两类。外部客户端未知时标需用户更新，不宣称自动完成。

- [ ] **Step 1: RED。** `test_old_app_new_schema_pair_never_opens_gateway`、`test_rollback_restores_scopes_config_cache_and_pair`、`test_restart_after_db_write_before_yaml_recovers`、`test_stale_preview_and_active_requests_abort_before_write`、`test_backup_permissions_and_no_plaintext_keys`。
- [ ] **Step 2: 运行RED。** `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/test_release_identity_recovery.py -v`；预期跨程序/状态恢复断言失败。
- [ ] **Step 3: 实现协调恢复接线。** 区分未开始/已准备/半提交/已提交，失败保持维护；旧代码不认识journal时由已验证恢复工具先处理，不让旧网关自行开放半迁移数据。只能操作已登记受控文件，不删权重资产。
- [ ] **Step 4: 同命令GREEN＋全量；获准后隔离8998真演练。** 新旧请求、scoped/全权/撤销/过期key、预灌缓存、进程重启、官方与自定义免重启、回滚后再晋升均取证。真实测试key在隔离域创建/销毁，不读生产key。
- [ ] **Step 5: 审查检查点。** 记录真实恢复耗时、未完成项和客户端变更表；不把这一步当生产apply授权。

### Task D4: 整版签收与生产晋升申请

**Files:**
- Create: `docs/qa/product-v2/acceptance.md`、`native-ui.md`（如B已创建则更新）
- Consume: A/B/C全部结果、D1–D3证据；最终固定release manifest。

**Interfaces:**
- 签收矩阵按F1–F7/全页面/12型号逐项列pass/fail/blocked/not_run、命令、exit code、报告引用、告警；不得把未测视为pass。
- 生产请求单含release双端摘要/版本、计划停机窗口、迁移preview与revision、客户端旧→新清单、私有备份位置、恢复命令与成功判据。请求单不含key/digest或安全备份正文。

- [ ] **Step 1: 核验前置。** A1强隔离真实探针、A3/A4恢复/硬切、B样稿签收＋全页原生矩阵、C4型号证据齐全；任何未通过项保留blocked，不降低验收标准或补造证据。
- [ ] **Step 2: 最终验证。** 获准执行后运行全量Python测试、Swift契约测试、debug构建、D2原生和各类型真实语义矩阵、鉴权拒绝/合法、生产零穿透对照；读取所有真实输出并记录警告。此为验收任务，不新增无意义RED代码测试。
- [ ] **Step 3: 最终产物复验。** 将已验commit构建成对候选，验证安装后的版本/摘要与同一证据对应；freeze manifest，不能验A代码发布B产物。外部上传前报备，不自动push/tag/release。
- [ ] **Step 4: 交付待批准请求。** 明确剩余限制；用户批准发布/生产迁移点后才进入安装维护操作，使用launchd精确label/PID，不全局pkill。确认前任务停在申请态。
- [ ] **Step 5: 获准后的终态。** 新ID真实客户端成功、旧ID带合法key404、UI鉴权真实、双端同manifest、恢复可用、生产健康；任一失败按D3恢复并如实报告。没有用户授权和真实证据，此步骤永不勾选。
