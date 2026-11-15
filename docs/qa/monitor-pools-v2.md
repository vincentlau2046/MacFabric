# 监控/池 v2 验收用例与证据索引

PLAN-2026-11-15 v2（Task 7 报告契约 + Task 8 原生监控台 + Task 9/10 体验）。
场景先行（Task 8 checkbox 1），证据随验收逐项回填。

## 1. 场景与预期

### M1 四档窗口快速切换
- **操作**：监控台范围 1h → 24h → 7d → 30d 快速连续切换。
- **预期**：只呈现最后一次选择的数据；中间选择的响应即使后到也被
  generation 校验丢弃；无图表闪烁回退。

### M2 新请求入库后出现
- **操作**：发起一次成功对话（及一次失败请求）。
- **预期**：下次持久统计刷新（15s 轮询或手动刷新）后，成功/失败均出现在
  totals/模型表/错误分类；失败请求计入对应错误类别，不消失。

### M3 筛选期间旧数据标注
- **操作**：切换范围/来源后立即观察。
- **预期**：旧报告保留展示，标题带**旧区间**标签 + 「切换中 · 显示旧数据」；
  新响应到达后整体替换，数字/表/图同源（同快照契约），不出现图新表旧。

### M4 刷新纪律
- **预期**：监控页可见时 15s 自动刷新；手动刷新按钮立即可用；同查询由
  网关 15s TTL 单飞缓存兜底；离页/关窗暂停重查询，重新进入立即更新；
  子视图不各自发请求（单一 fetch 点）。

### P1 池卡摘要（轻量）
- **预期**：每池显示区间内逻辑请求数/成功率/最终承接；展开后显示
  attempt/retry/fallback、摘要覆盖率与候选运行态（冷却原因/半开探测/
  最近真实尝试 — 来自 /admin/model-pools/runtime，Task 6 契约），
  不用「注册表存在」冒充请求正在调用。URL/API Key/model 调用指引保留
  在模型池页（PoolsView），监控台不恢复每池复制 YAML 按钮。

### E1 边界显示
- **预期**：无数据 → 空态文案；未配价 → 费用「未配价」（不是 ¥0.00，
  币种与价格配置一致，价格单位 ¥/1M tokens）；
  缺 TTFT/usage → 「—」与 unknown 计数（不是 0ms/0）；模型名过长 →
  表格省略 + 详情卡完整可选中复制。

## 2. 已取证（2026-11-15，隔离实例 :8997 + 临时状态目录）

| 项 | 方法 | 结果 |
|---|---|---|
| 空态 | GET /api/monitor-report（空库） | requests=0, models=0, series=12 桶 ✓ |
| 参数校验 | window=90d / scope=galaxy | 400 ✓（不静默回退） |
| 旧 API 兼容 | GET /api/metrics 无参 | 200 ✓ |
| 计数一致性 | SQLite 直插 6 行混合场景 → API | requests=6 与 DB 行数一致；series 合计=6 ✓ |
| 身份契约 | cloud:prov_a/gpt-x + cloud:prov_b/gpt-x | models 两行不混合 ✓；scope local 2 + cloud 3 + 未归属 1 = 6 ✓ |
| 池统计 | 早期失败(unknown_pool) + 摘要行 | 分母=2 含早期失败；attempt_count=2；coverage=0.5 ✓ |
| 错误脱敏 | 502 带 `sk-secret-xyz` 文本 | 类别 upstream_5xx；原文不出现 ✓ |
| 10 万行 | 单元测试 test_full_window_over_100k | 精确计数不截断；构建 0.42s / RSS≈78MB ✓ |

## 3. 待人工 GUI 取证（需真机交互）

- [ ] M1 四档快速切换只呈现最后一次（SwiftUI 交互时序）
- [ ] M2 成功/失败新请求在下次刷新出现（需真实模型调用）
- [ ] M3 筛选期间旧数据旧区间标识的视觉呈现
- [ ] M4 主窗口关闭/重开、离线/恢复的轮询暂停与立即更新
- [ ] P1 池卡展开冷却原因/半开探测的视觉核对（需制造冷却：停掉本地引擎后发池请求）
- [ ] 调试版 App（build.sh --debug → MacFabric-dev.app → :8998）全流程走查

取证方法：`scripts/dev-gateway.sh` + `open macfabric-app/build/MacFabric-dev.app`，
完成后在本节勾选并补截图路径/日志摘录。

## 4. Task 9 场景（保存/冲突/拖拽/状态一致性）

### 反例执行结论（现状缺口 → 处置）

| 反例 | 现状缺口 | 处置 |
|---|---|---|
| 云属性浮窗填非法数字（"12a"）保存 | 静默按清除处理（NSNull），数据被无声抹掉 | 字段内报错「需为正整数」，保留输入，不发请求 |
| 浮窗保存遇 500/断网 | 保存即关浮窗，草稿丢失 | 成功（ok 回调）才关闭；失败留在浮窗可重试 |
| 服务商表单失败 | 点「添加」立即清空表单，失败草稿丢失 | 成功才清空；失败保留草稿 + 横幅报错 |
| 只带 candidate id 拖拽 | 同 id 候选可跨池存在 → 会误操作其他池 | 拖拽数据改 "pool\\|candidate" 双身份，跨池 drop 拒绝 |
| 拖拽取消（落空白/切页签） | poolDragging 高亮残留 | 容器级取消落点 + 页签切换 cancelPoolDrag |
| 连点排序 | 两个 mutation 并发 GET→CAS 交错 | 串行队列按意图顺序执行；409 重放排队尾 |
| 未保存按 Esc（浮窗） | 静默关闭丢修改 | editorDirty 标记；Esc 走确认丢弃对话框 |
| 最后一把有效 key 撤销 | 无风险提示 | 确认行附「撤销后所有客户端将无法调用」警示 |
| 未保存明文二次新建 | oneTimeKey 被覆盖显示 | 有未保存明文时先确认再新建 |

### 裁决记录

- 池高级设置（max_attempts/deadline_ms）**留空 = 不修改**（占位提示当前值），
  不采用云属性浮窗的"空白=清除" — 清成默认风险高，恢复默认走显式
  「恢复默认」按钮（删键 → 服务端默认 2 / 60000）。
- 409 冲突保留"新基点字段级重放"（不静默覆盖他人修改）；重放再失败则
  显式报错，不以盲重试承诺"不丢点击"。
- 网关重启 revision 重置：mutation 每次现取 GET 基点，天然重建（toggle
  409 亦重取重试），无"永久忽略较小 revision"路径。

### 已取证（代码级 + 构建）

- 调试构建 0 warning / 0 error（swiftc -O，含全部 Task 9 交互改动）。
- 客户端范围与服务端严格校验一致：1–10 / 1000–300000（config.py Task 6）。
- CAS 走 raw 基底字段修改，未修改字段原样保留（mutatePools 现取 raw）。
- 明文 key 仅存 oneTimeKey 展示一次，不进任何日志/错误消息。

### 待人工 GUI 取证

- [ ] 连点排序：5 次快速 ↑↓ 后顺序与服务端一致、无交错
- [ ] 跨池拖拽被拒（拖 A 池候选到 B 池同 id 行，B 无变化）
- [ ] 拖拽取消后高亮消失（容器空白放下 / 切页签）
- [ ] 浮窗非法数字报错保留输入；断网保存浮窗不关
- [ ] Esc 丢弃确认对话框出现
- [ ] 最后一把 key 撤销警示文案可见

## 5. Task 10 验收清单（轻量视觉与可访问性）

### 验收标准

| 项 | 处置 |
|---|---|
| 反馈有类型 | FeedbackKind（success/progress/info/warning/error）写入时确定；FeedbackBanner 按 kind 上色配图标（✓/沙漏/ⓘ/⚠/✗）；运行时零 emoji 解析（37 处赋值全部迁移为 notify()，编译期固定） |
| 操作结果与刷新状态分开 | monitorLoading/monitorReportWindow（数据刷新态）≠ actionMessage/FeedbackBanner（操作反馈态）；池刷新态经 fetchPools 回归服务端真相 |
| 危险操作始终可发现 | 撤销 key / 移除候选（⋯菜单）/ 删除服务商均常驻按钮，非 hover 出现；均带两击确认 |
| 池次要操作收菜单 | 候选行「移除候选…」收进 ⋯ 菜单；排序入口（↑↓ + 拖拽）保留行面 |
| 窄窗口 | 监控台筛选行 ViewThatFits：宽=单行，窄=两行堆叠，无关键控件裁切；表格横向滚动不裁切（Task 8） |
| 长 modelid 可查看/复制 | 表格省略号 + 详情卡完整 textSelection（Task 8） |
| Tab 键可达 | 原生 SwiftUI 控件（segmented Picker/TextField/Button）默认全键盘可达 |
| ⌘1–8 | 侧栏页签直达（总览⌘1 … 设置⌘8） |
| Esc 安全关闭 | 云属性浮窗 onExitCommand：有未保存修改先确认丢弃（Task 9） |
| 减弱动态效果 | 代码中无 withAnimation/transition/animation（grep 0 处）— 无差别转圈未采用，busy 仅用于具体动作（cloudBusy/securityBusy/monitorLoading），reduce-motion 无需守卫 |
| 设置分区 | 重组为「系统与账本 / 安全」分区标题；未接线开关保持禁用 + 诚实说明（Task 9 原状） |
| 菜单栏 | 已有 mini 织物条（网关/账本/模型状态）+ 打开总览（主窗口）+ 网关面板 + 退出 — 无缺口，不重复造 |

### 已取证

- 调试构建 0 warning / 0 error（含全部 Task 10 改动）。
- `grep -c "actionMessage = \""` 残留仅声明与自动清空两处 — 全量类型化。
- 菜单栏能力核对：MiniWeaveView（账本水位+活跃模型）+ showOverview + openDashboard ✓。

### 待人工 GUI 取证

- [ ] 窄窗口（最小宽）筛选行堆叠、无裁切
- [ ] Tab 顺序走查 + ⌘1–8 切页
- [ ] 减弱动态效果开启下操作反馈呈现
- [ ] 无图表数据时监控台空态文案可读

## 6. 终审修复轮取证（2026-11-15，整分支评审 fix-first → 7c309ef + ce24591）

评审（fresh reviewer，0f07cf8..2b64d54）：1 Critical + 10 Important + 2 Minor，
逐条对照源码重定级后一轮修复；每项先 RED 后 GREEN，回归 125/125，
调试构建 0 warning。重定级与拒绝项裁决见 SDD 台账 Final 段。

| 发现 | 修复 | 证据（测试） |
|---|---|---|
| C1 上游错误体经 pool_summary.attempts 入 metadata/进程日志 | safe_attempt_error 固定码化（摘要 + _log_failed_attempts 同源） | test_summary_attempts_error_fixed_code / test_failed_attempt_process_log_sanitized（密文零出现） |
| I1 同秒洪流提前停扫谎报完整；`> since` 违反 [since,until) | (timestamp,id) 真键集分页；下界含 since；_MAX_PAGES 触顶如实 truncated | test_same_timestamp_flood_full_count（100001 同秒行全计）/ test_since_boundary_inclusive |
| I2 3xx 计成功 | 2xx 契约 | test_3xx_not_success |
| I3 直连行缺 usage 冒认 0 | 无摘要证据成功行 0/0 计 usage_unknown_rows | test_direct_row_missing_usage_counts_unknown |
| I4 身份未用 actual_model_id | 池行按 final_target.actual_model_id 聚合 | test_alias_grouped_by_actual_model（iff/fast → qwen3-4b） |
| I5 价格未接线 + 单位/币种错 | handler 传 price_config；复用 cost_of_row（¥/1M）；字段 cost_estimate | test_cost_uses_price_table_yuan_per_1m / test_unpriced_reports_none |
| I6 本地 OpenAI 动作表状态直发 | _forward_request_ex suppress（401/403/429/5xx≠501 未提交交动作表；400/404/413/422/501 PR-14 直发保留） | TestLocalSuppressActionableStatuses 6 项（含 429 Retry-After、流式、客户端零字节） |
| I7 传输异常不计尝试 | 异常 admitted=True + 消耗 max_attempts（冷却语义不变） | test_transport_exception_consumes_attempt |
| I8 fetchPools 无代际守卫 | 池拉取代数，旧响应丢弃 | 构建验证（交互时序属人工 GUI 项） |
| I9 monitor 加载态/onAppear | 加载态随代数清；重进无条件拉取 | 构建验证（人工 GUI 项） |
| I10 筛选行无 ViewThatFits（QA 断言此前与源码不符） | ViewThatFits 宽单行/窄两行 | 构建验证（窄窗人工项） |

### 契约变更（本分支内，未发布）

- `totals.cost_estimate_usd` → `totals.cost_estimate`（币种如实：价格配置
  单位 ¥/1M tokens；UI 显示 ¥，「未配价」语义不变）。
- 本地 OpenAI 池候选对 401/403/429/5xx（501 除外）不再直发客户端错误，
  改为未提交交动作表（冷却/等待/回退）；非回退类 400/404/413/422/501
  直发语义不变（PR-14 冻结范围收窄到其本意）。
- usage 缺失推断：无摘要证据的成功 0/0 行计 unknown（tokens 列 NOT NULL，
  NULL 化需 schema 迁移另案获批）。
