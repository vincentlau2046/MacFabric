# MacFabric — 设计稿 vs 实现差距排查（2026-11-14）

> 基准：`design/ui-design-v0.html`（11 画面 + 设计令牌）。实现：`macfabric-app/` + `macfabric_gateway/`。
> 状态图例：✅ 已对齐 · 🔶 部分（有骨架缺细节）· ❌ 未做

## 一、画面级 Gap

| # | 画面 | 状态 | 差距明细 |
|---|------|------|---------|
| 1 | 菜单栏常驻 | 🔶 | 有图标+菜单（打开总览/网关面板/退出）；缺设计稿的**下拉内 mini 织物条**与活跃模型速览 |
| 2 | 首启向导 | ❌ | 整页未做（RAM 检测→预算确认→默认池推荐→完成） |
| 3 | 总览 | 🔶 | ✅ 织物条+图例+预算数字+统计瓦片+能力卡格；缺**睡眠态卡**（"唤醒约 2s"）、四态 pill（设计稿 run/load/sleep/stop）、段 hover 显"模型名·基线/实测"与偏差黄点、机器型号行 |
| 4 | 模型服务 Hub | 🔶 | ✅ 接入地址条+复制 Base URL/JSON/cURL；缺**协议 tab 切换**（OpenAI↔Anthropic 两套配置）、**复制环境变量**（ANTHROPIC_BASE_URL 方式）、**云端模型卡**（glm-5 等）、能力筛选 tabs、鉴权状态 |
| 5 | 本地推理 | 🔶 | ✅ 一行一模型+切换/停止+试聊；缺 **sleep/wake 按钮**（端点已有 /sleep /wake）、装载模式/内存账小字列、四态 pill |
| 6 | 模型池 | ❌ | 仅占位列表。缺：池树（iff/<pool> 候选链按调用顺序点亮）、候选排序拖拽、池管理下拉。**前置依赖：网关默认池配置（PLAN 裁决的 5 池）**，/admin/model-pools 现为空 |
| 7 | 监控台 | 🔶 | ✅ 24h 请求柱状图+统计瓦片；缺 tokens 曲线、TTFT/延迟分布、agent 调用统计（/api/agent-stats 现成） |
| 8 | 能力包 | ❌ | 整页未做。**前置依赖：P3 能力端点**（/v1/audio/*、/ocr、/v1/embeddings 预设） |
| 9 | 云端接入 | ❌ | 整页未做。数据端点现成（/admin/cloud/providers、presets、provider-models） |
| 10 | 设置 | ❌ | 整页未做（鉴权开关、auto-switch、预算参数 MACFABRIC_RESERVE_MB、局域网共享 v1.5） |
| 11 | 内存不足弹窗 | ❌ | 未做。**前置依赖：账本 R1 接线到 switch 路径**（memory_ledger 已实现+测试，未接入 manager.switch） |

## 二、内核侧 Gap（支撑画面）

| 项 | 状态 | 说明 |
|---|---|---|
| 账本 R1 接线 | ❌ | `memory_ledger.MemoryLedger` 已实现+31 测试，但 `manager.switch` 未做准入检查（现在 YAML 还是 peak_vram_mb 旧字段，未迁移 mem_baseline_mb/mode/idle_timeout_min 三字段） |
| 账本 R2/R3 调度 | ❌ | idle_sleep_candidates/pressure_eviction_plan 无后台循环调用 |
| 默认池配置 | ❌ | 5 池未写入 models.d/pool 配置 |
| sleep/wake 映射账本 | 🔶 | /sleep /wake 端点有，未与账本 SLEEPING 态同步 |

## 三、执行计划（优先序）

| 批次 | 内容 | 里程碑 |
|---|---|---|
| **G1 本晚** | 总览四态 pill+睡眠卡；本地推理 sleep/wake 按钮（端点现成）；账本三字段迁移+R1 接入 switch（内存不足弹窗 v1） | P2 主体验收 |
| **G2** | 模型服务 Hub 完整化：协议 tab、环境变量复制、云端卡（云端数据现成）、能力筛选 | P2 |
| **G3** | 默认 5 池网关配置 → 模型池树状页（候选链点亮+拖拽排序）；菜单栏 mini 织物条 | P2 收口 |
| **G4** | 监控台补全：tokens 曲线、agent 统计、TTFT（/api/metrics 已有数据面） | P2/P3 |
| **G5** | 云端接入页 + 设置页 + 能力包页（绑 P3 端点落地） | P3 |
| **G6** | 首启向导 + 完整内存不足弹窗交互（force 超卖确认链路） | P3 |
| **G7** | dmg 打包、Sparkle、公证 | P4 |

## 四、已修复（本轮）

- 最小化后无法调出 → `deminiaturize` + `applicationShouldHandleReopen`（菜单栏/Dock 双入口）
- 织物暗色 token 全量落地（desk/panel/glass/line/ink/dim/accent + 九根能力线色）
- 侧栏导航（平台/获取/设置三组，能力包/云端接入/设置灰显占位）
- `/models` 补 `peak_vram_mb`（织物条分段真实内存基线）
