# PLAN 2026-11-15 — 监控统计强化 + 池路由加固 + UI 美化/体验提升

状态：已获用户批准（2026-11-15）。执行顺序：Phase 1 → 2 → 3 → U1 → U2 → U3（每 Phase 完成即构建/晋升/实测/提交）。
约束：功耗/电费类功能不做（用户裁决：本端口为轻量版）；服务端零 schema 变更优先；全部改动需过 18 项既有回归。

---

## 〇、调研结论（2026-11-15 实查）

- 原版 inferfabric 监控资产大多健在：`/api/metrics?window=1h|24h|7d|all`、`/api/token-curve?granularity=minute|hour|day|week`（天=30×1d、周=13×7d）、`/api/latency?window=minute|hour|day`（TTFT/TPOT p50/p95 分位 × 时间分桶）、`/api/agent-stats`、`/api/power`（不移植）。
- 数据底盘：`request_log` 20 列（`route` 记 `pool:<池>/<候选链>`、`key_name`、`agent`、`ua`、`cost`），聚合器重启回放 720h，惰性留存清理已有。
- App 监控台只写死 24h：4 个 StatCard + 24h 柱状图 + 按模型表；四档曲线/延迟趋势/agent 维度全部未消费。
- 池路由引擎成熟（固定动作表/预算/冷却半开/404 隔离/committed 保护/逐 attempt 观测），加固点在边角（见 Phase 3）。

---

## Phase 1 — 统计底盘

1. **监控台窗口切换**：App 加 1h / 24h / 7d / 30d(月) picker；服务端 `get_metrics` 补 `"30d"` 档。
   验收：切"月"看到完整 30 天聚合；四档数字随窗口联动。
2. **按模型统计增强**：指标表窗口联动；加成功率列；错误 Top；接入 `/api/agent-stats`（agent/UA 维度，local/cloud scope）。
   验收：制造一次失败请求后，错误 Top 与成功率列正确反映。
3. **按池统计（新端点）**：`GET /api/pool-stats?window=1h|24h|7d|30d` — 从 `request_log.route` 聚合每池请求数/成功率/候选选中分布/平均 attempts；App 池卡显示"近24h：N 次 · 成功率 · 首选承接分布"。
   验收：走 iff/fast 发 3 次请求，池卡数字与分布正确。

## Phase 2 — 图表与性能视角

4. **Token 用量四档曲线**入 App（minute/hour/day/week，local/cloud 双 scope，含成本，复用端点）。
5. **延迟趋势图**入 App（/api/latency：TTFT/TPOT p50/p95，minute/hour/day，Swift Charts 折线，top5 模型）。
   验收：发起若干请求后两图有数据且与 web 控制台口径一致。

## Phase 3 — 池路由 proxy 加固

6. **首请求去阻塞**：池路径 `_ensure_cloud_discovered` 改"last-known 状态立即路由 + 异步触发发现"，不同步等 `discover_all()`（当前上游慢时首请求可被分钟级发现拖住）。
   验收：清空发现状态后首请求 <2s 返回（走 last-known 或明确池错误，不卡分钟级）。
7. **证据闭环**：池转发成功 → PROBED 证据落盘（指纹失配自动 STALE 已有）；持续 401/403 → FAILED；池卡透出每候选证据/冷却/隔离状态。
   验收：成功调用后 `model_pool_evidence.json` 出现 PROBED 条目；池卡状态可见。
8. **池参数 UI 化**：max_attempts / deadline_ms 池卡内可调（CAS 回写）。
   验收：App 内改 max_attempts=3 生效（raw 回读一致）。
9. （低优，记录不实施）冷却状态持久化 — 重启后半开探测自愈。

---

## Phase U — UI 美化 / 体验提升

### U1 反馈与状态规范（先做，全局收益最大）
- **反馈横幅三态化**：actionMessage 按 ✅/⚠️/❌ 前缀自动着色（ok 绿 / warn 橙 / error 红）+ 图标，替代当前全页统一蓝色底。
- **卡片三态规范**：统一"加载中（骨架占位）/ 空态（一句说明 + 一个动作按钮）/ 错误态（原因 + 重试）"组件，替换现在各卡零散文案。
- **数字卡统一**：StatCard 数字大字重、标签小字、变化时数值过渡动画。

### U2 交互精修
- **池卡操作收纳**：候选行"换/移除/↑↓/拖拽"密度过高 → 次要操作（移除/换）收进行尾溢出菜单或 hover 显现；保留拖拽与 ↑↓。
- **浮窗体验**：云端模型属性 sheet 加 Esc 关闭、点击外部关闭、保存后行内 chip 即时刷新动画。
- **busy 态按钮**：所有 SmallBtn 加载中转圈（统一 spinner），替代纯文字"推理中…"。
- **列表/图表动效**：tab 切换过渡、Chart 数据更新事务动画（克制，遵循减法原则）。

### U3 导航与快捷
- **快捷键**：⌘1-8 切页、Esc 关浮窗/弹层、⌘K 可选（后续）。
- **菜单栏迷你条增强**：网关状态点 + 当前活跃模型 + 快捷"打开主窗口"。
- **设置页重组**：分组为「系统 / 网关与目录 / API Key 鉴权 / 关于」，开关项统一交互（已接线的可交互，未接线诚实标注——延续现有原则）。

### 低优记录
- 暗色主题完整回归（light 已是默认；dark token 翻转成本高，待 light 稳定后再评估）。

---

## 验收底线（全 Phase 通用）

- 构建通过 → 晋升安装版 → API 级实测 → 18 项回归不回退 → STATUS.md 记录 → 双远端提交。
- 每项改动"现场生效"（store 订阅 + 乐观更新模式延续，不允许"切卡片才刷新"回归）。
