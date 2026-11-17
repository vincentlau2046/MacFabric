# B 全页面 UI 与鉴权 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将已安装模型及所有页面统一到原生表格/详情与真实鉴权交互。

**Architecture:** 提取现有单文件内的产品资料、鉴权、设计令牌与共享列表组件；保留原生壳和现有网关。数据契约测试用CLT编译，视觉与操作用真实Dev App验收。

**Tech Stack:** SwiftUI、AppKit、Security.framework、Foundation URLSession、swiftc；Python契约fixtures。

**Spec:** `docs/superpowers/specs/2026-11-16-ui-standard-v2.md`；`2026-11-16-product-definition-v2.md` §§3、5–6、9。

## Global Constraints

- 当前仅文档落盘，所有实施步骤未执行；实施需用户审核本计划。
- 原生 SwiftUI＋AppKit，不用 WebView；三张视觉样稿确认前不写 UI 实现。
- 调用 ID 同步硬切，不保留旧 ID 路由别名；内部生命周期身份和历史日志保留。
- 默认 LLM/VL ≤4B；预算 `B = RAM − reserve`，env ＞ policy ＞ 8192 MiB；设置唯一编辑入口。
- 保持鉴权开启；不保存/输出真实密钥到文档、测试证据或示例。
- 开发 8998、生产 8999；未获明确要求不 commit/push，不替换 /Applications。

## Review Focus

- 长名称/同名变体/筛选排序后动作错绑，必须按instance_id（B1/B3）。
- 网络失败或非2xx被解释为disabled；旧状态需stale（B2）。
- Keychain锁定/拒绝/profile变更，不静默丢key或跨环境读取（B2）。
- 无LLM却选首个嵌入试聊、给嵌入生成Anthropic配置（B4）。
- 监控历史同名合并、资源重复扣reserve、表单双入口（B4）。

---

## 文件责任与先决条件

依赖 A2 DTO；B2 可在隔离fixture网关验证，B4端到端需A4/C2。

新增 `macfabric-app/Sources/ProductModels.swift`（DTO/身份）、`AuthState.swift`（状态机）、`GatewayKeychain.swift`（key生命周期）、`APIExamples.swift`（按类型示例）、`DesignSystem.swift`（令牌/列规则）、`ModelTable.swift`（共享列表）、`ModelDetails.swift`（检查器）。保留 MacFabricApp.swift 中 App/路由/原有控制器，其相关业务逐项接入，不借机全重写。

新增 `macfabric-app/Tests/ContractTests.swift`、`Tests/Fixtures/product-models.json` 与 `scripts/test-app-contracts.sh`。build.sh 改为显式编译新增文件并链接 Security；不得继续只编 MacFabricApp.swift 造成提取文件不生效。

### Task B1: 产品资料测试与视觉评审

**Files:**
- Create: `macfabric-app/Sources/ProductModels.swift`、`DesignSystem.swift`
- Create: `macfabric-app/Tests/ContractTests.swift`、`Tests/Fixtures/product-models.json`、`scripts/test-app-contracts.sh`
- Create (评审材料): `design/product-v2-local-inference.md`、`product-v2-packs.md`、`product-v2-hub.md`（均在design下，实施时才创建）
- Modify: `macfabric-app/build.sh`、`Sources/MacFabricApp.swift` 的ModelItem/PackRef消费点

**Interfaces:**
- `ProductModel: Decodable, Identifiable`，`id == instanceID`，字段由A2蛇形DTO映射；未知类型 `.unknown`，未知资源 `nil`，能力/兼容/验证/安装/运行分别建enum，不用一个status承载。
- `ModelColumnLayout.visibleColumns(availableWidth: CGFloat) -> [ColumnID]`，按UI v2断点；SwiftUI视图只消费结果。
- `test-app-contracts.sh` 从仓库根可运行，将指定无UI逻辑源＋ContractTests编译到 `$CLAUDE_JOB_DIR/tmp/app-contracts/`，`@main`断言失败返回非0；每例输出PASS/FAIL且总退出码正确，不引入SwiftUIMacros依赖。

- [ ] **Step 1: RED。** `testDecodeUnknownNotChat`、`testNameNotDerivedFromSlug`、`testDuplicateNamesKeepInstanceIdentity`、`testResourceNilNotZero`、`testColumnsAt819_820_1099_1100`；BGE title=BGE-M3、id=旧instance，api=bge-m3，三者独立。
- [ ] **Step 2: 运行RED。** `bash scripts/test-app-contracts.sh`；预期上述行为断言失败，脚本/SDK不可用不算RED。
- [ ] **Step 3: 实现DTO与布局纯逻辑。** 编译源列表显式更新；不提前实现视图。与A2固定fixture互验，显示字段不承担操作身份。
- [ ] **Step 4: 同命令GREEN。** fixture含长中英文、重复名变体、30+行、未知/失联/失败；再在总计划全量Python测试通过后记录接口检查点。
- [ ] **Step 5: 视觉样稿评审。** 制作本地推理/能力包/模型服务标准窗与窄内容区样稿，含明暗与详情；数值标示例，不能伪装真实验证记录。用户确认前停在此处，不能因纯逻辑绿灯开始UI代码。不自动提交或发布样稿。

### Task B2: 鉴权状态、Keychain 与统一请求注入

**Files:**
- Create: `macfabric-app/Sources/AuthState.swift`、`GatewayKeychain.swift`
- Modify: `Sources/MacFabricApp.swift` fetchSecurityStatus/sendPrompt及安全设置、`build.sh`（均在macfabric-app下）
- Test: `macfabric-app/Tests/ContractTests.swift`（URLProtocol fixture＋可注入credential store）

**Interfaces:**
- `SecuritySnapshot`（policy/active/enforced/fetchedAt）＋`SecurityState`（loading/loaded(snapshot, stale: Bool)/unavailable）；显示enabled_all/enabled_pools/disabled从成功snapshot派生，不从false缺省派生。
- `GatewayProfile`（dev/prod，固定loopback origin）；`GatewayCredentialStore`协议 `load(profile:) throws -> String?`、`save(_:profile:) throws`、`delete(profile:) throws`。Keychain service=`io.macfabric.gateway-api-key`，account=`<profile>|<origin>`；不共用cloud凭证；仅本次会话使用内存store。
- `InferenceRequestAuthorizer.authorize(_ request: URLRequest, profile: GatewayProfile) throws -> URLRequest`：只向匹配profile的loopback网关origin附Bearer，重定向到不同origin拒绝，不向管理/模型下载请求注入。
- 状态请求使用HTTP状态与结构验证；可见窗口每30秒刷新、页面激活立即刷新，避免现3秒timer顺带过度轮询；请求代际防止旧profile响应覆盖新profile。

- [ ] **Step 1: RED。** `test500MalformedTimeoutAreNotDisabled`、`testLastGoodMarkedStale`、`testPolicyAllPoolsOffPresentation`、`testKeychainDeniedDoesNotSaySaved`、`testDevNeverReadsProdAccount`、`testOldProfileResponseIgnored`、`testAuthorizationOnlyMatchingInferenceOrigin`、`testCrossOriginRedirectDropsRequestNotLeaksKey`；错误401/403不提示安装模型。
- [ ] **Step 2: 运行RED。** `bash scripts/test-app-contracts.sh`；预期状态/请求/隔离断言失败。
- [ ] **Step 3: 实现并接线。** 去除Hub硬编码“鉴权未启用”；录入/会话或Keychain选择/删除/重录和真实错误提示统一组件；不静默创建key、不恢复摘要。调试fixture不访问真实Keychain；真实Keychain验证使用独立测试account且清理。
- [ ] **Step 4: 同命令GREEN＋构建。** `bash macfabric-app/build.sh --debug`，预期独立bundle成功链接Security且仍8998；原生手验Keychain拒绝/锁定/保存/删除，权限不足标阻塞。不重开生产App，不操作生产key。
- [ ] **Step 5: 审查检查点。** 扫描日志/复制示例/偏好文件无fixture明文泄漏；附脱敏状态矩阵。

### Task B3: 原生表格与详情替换两页卡墙

**Files:**
- Create: `macfabric-app/Sources/ModelTable.swift`、`ModelDetails.swift`
- Modify: `macfabric-app/Sources/MacFabricApp.swift` InferenceView/ModelRowView/PacksView/PackCard/CustomPackCard；`build.sh`
- Test: `macfabric-app/Tests/ContractTests.swift`；原生证据 `docs/qa/product-v2/native-ui.md`

**Interfaces:**
- `ModelActionTarget(instanceID: String, apiModelID: String, packID: String?)`；启停用instanceID，推理用apiModelID，安装卸载用packID。状态改变刷新不以displayName索引。
- `ModelTable`与目录表共享列/状态样式，目录行键packID＋variant；`ModelDetails`消费完整DTO，不读取硬编码模板白名单。
- AX标识 `model-row:<instanceID>`、`model-action:<instanceID>`、`pack-row:<packID>:<variant>`；详情提供完整文本供原生验证，不把测试状态塞进生产模型。

- [ ] **Step 1: RED。** `testSortedFilteredActionsPreserveIDs`、`testNarrowColumnsKeepNameTypeStatusAction`、`testRunningAndInstalledIndependent`、`testRefreshKeepsSelectionUntilRemoved`；新增布局断言与操作目标测试。建立原生现状截图，记录错列和pack标题缺陷作为视觉RED。
- [ ] **Step 2: 运行RED。** `bash scripts/test-app-contracts.sh`；预期目标/状态断言失败，原生截图需真实Dev App而非HTML。
- [ ] **Step 3: 按已确认样稿实现。** 连续表面/共享表头/固定资源与动作列/可变名称列；详情收纳端口/包ID/启动/策略/路径；按UI v2断点收列；取消/进度以真实后端能力为准。旧导入入口等待C3统一，不保留绕过写配置按钮。
- [ ] **Step 4: 同命令GREEN＋debug构建与原生矩阵。** 测900×650/1200×800/1600×1000、亮暗、长名称/30+行、VoiceOver/键盘/大字体。验证加载/睡眠/测试/卸载确认绑定正确实例，未获真实安装授权时用隔离fixture状态，不冒充真包验收。
- [ ] **Step 5: 审查检查点。** 归档脱敏原生截图；样稿一致不等于通过语义门禁，后者在D2。

### Task B4: 其余页面、接入示例与分型试用

**Files:**
- Create: `macfabric-app/Sources/APIExamples.swift`
- Modify: `macfabric-app/Sources/MacFabricApp.swift` OverviewView/HubView/HubRow/PoolsView/PoolCard/MonitorView/CloudView/SettingsView/WizardView/MiniWeaveView/sendPrompt
- Test: `macfabric-app/Tests/ContractTests.swift`；`docs/qa/product-v2/native-ui.md`

**Interfaces:**
- `APIExamples.make(model: ProductModel, profile: GatewayProfile, format: ExampleFormat) throws -> String`；format=curl/json/anthropic；嵌入/重排拒绝anthropic，示例不读credential store。
- `TryoutKind.forType(_ type: PrimaryType) -> TryoutKind?`：llm=chat，vl=image，embedding=embeddingComparison，rerank=ranking；未交付类型=nil。
- 监控显示解析 `instance_id`/原始ID→displayName，不改历史日志、不按displayName聚合。`MemoryPresentation`直接消费后端budget/reserve/committed，不再次扣reserve。

- [ ] **Step 1: RED。** `testEmbeddingHasEmbeddingsEndpointNotChat`、`testRerankExampleHasQueryDocuments`、`testNoLLMDoesNotFallbackToEmbeddingChat`、`testExamplesNeverContainCredential`、`testHistorySameNameNotMerged`、`testBudgetDoesNotSubtractReserveTwice`（36GiB/8GiB→28GiB预算），`testReserveSingleEditorAndEnvOverrideVisible`。逐页列出旧硬编码/术语缺陷作为原生RED清单。
- [ ] **Step 2: 运行RED。** `bash scripts/test-app-contracts.sh`；预期示例/目标/预算断言失败。Cloud原始ID含slash必须原样可复制，不能套本地命名正则。
- [ ] **Step 3: 逐页接共享合同。** 统一友好名称、资源、状态、表单与错误；池保留fabric和候选顺序；移除第二保留内存编辑点；首启复用设置口径。试用统一authorizer，401/403/未部署/空正文分别处理，不能只显示200成功。
- [ ] **Step 4: 同命令GREEN＋debug构建＋全量Python测试。** 原生逐页检查表填写实际结果，复制的脱敏示例在隔离fixture验证请求method/path/body/header；真实模型/合法测试key链留D2，不能在此用fixture宣称真实可用。
- [ ] **Step 5: 审查检查点。** 交接完整页面清单、源字段与原生证据；未获用户批准不替换安装版。
