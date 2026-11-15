# 监控统计、池路由加固与 UI 体验 v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为轻量 MacFabric 提供可信的时间/模型/性能统计、可恢复且可解释的角色池路由，以及不依赖切卡片刷新的原生操作体验。

**Architecture:** 保留 Python 网关与 AppKit + SwiftUI 原生壳，复用上游日志、统计算法、双协议和池转发资产，但先修正记录真实性、预算及恢复缺口。SQLite 作为持久统计真相源，逻辑请求与上游尝试分开建模；监控数字、表格和图表消费同一统计快照。优先使用现有 metadata 列，确有必要才提出 schema 迁移，不为维持“零迁移”牺牲正确性。

**Tech Stack:** Python / SQLite / 现有 HTTP 网关 / pytest；Swift、AppKit、SwiftUI、Swift Charts、Combine；现有 CLT 直编与双档环境。

**Spec:** 基线见 [PLAN.md](PLAN.md)，尤其 D2/D3/D11/D12/D14；本文件第 1–4 节固化本轮用户需求及复审后的设计契约，后续任务共同依赖它们。

**Version / Status:** v2，2026-11-15；替代本文件 v1。用户授权本轮更新文档，**不授权据此立即实施代码**。阶段划分、接口和技术默认值是建议落地方案，不冒写为已完成或用户逐项裁决；执行前另行确认。

## Global Constraints

- 默认 light 风格；菜单栏常驻与主窗口双形态保持。
- 不纳入功耗、电费、GPU 运维大盘；不为本轮新增特权助手、额外采样守护或重型分析依赖。
- 轻量版不是复制完整 Web 控制台；Agent/UA 管理、暗色主题、⌘K、冷却持久化后置。
- 保持本地 LLM ≤4B、内存预算 B = RAM − 8G、默认不启动模型/首请求按需唤醒等既定行为。
- 保持已有协议/白名单/位置约束、完整逻辑模型名鉴权及配置 CAS；监控或后台发现不得扩大授权、扩大模型白名单或自行唤醒模型。
- 客户端响应已提交后不得重试或切目标；内部摘要不得泄露凭证、请求正文、完整会话或未脱敏上游错误。
- 安装版 :8999 / ~/.inferfabric，与调试版 :8998 / ~/.inferfabric-dev 隔离；禁止全局 pkill 网关。
- 本轮仅文档；未来实施先在调试环境通过验证，再申请晋升安装版。提交、推送、安装版替换按当次授权执行，不视为本文件自动授权。
- 沿用 ObservableObject + 手动 Binding；CLT 不支持的 SwiftUI 宏不可引入。不因美化强行拆分整个 App 或修改 vendor 参考副本。

## Review Focus

1. 冷启动历史超过 10 万条、重启回放和跨窗口边界：总数不可静默截断或因进程重启漂移；由 Task 1/7 的容量与持久一致性测试锁定。
2. 同名模型跨服务商、别名重映射及历史配置变更：用稳定身份区分，旧行不推造当前配置事实；由 Task 1/2/7 锁定。
3. 上游非 2xx、SSE 中断、客户端断开：区分真实状态、提交与完整性，不冒充成功或重复响应；由 Task 3 锁定。
4. 半开探测遇准入失败、异常或预算耗尽，以及更换凭证：不得泄漏探测权或永久封死候选；由 Task 4/6 锁定。
5. 快速切窗口、连点排序、保存失败/取消、窗口关闭重开：旧响应不得覆盖新状态，草稿不丢，不靠切卡片刷新；由 Task 8/9 锁定。

---

## 1. 需求追踪与轻量版边界

| 用户需求 | v2 交付 | 任务 |
|---|---|---|
| 24 小时/天/月统计视角 | 近 1 小时、近 24 小时、近 7 天、近 30 天；按范围自动分桶，明确时间与口径 | 1、7、8 |
| 基于模型统计 | 服务商/模型身份可区分；请求、成功率、输入/输出 tokens、错误分类、详情与趋势 | 1、2、7、8 |
| 性能统计 | TTFT、TPOT、端到端耗时 p50/p95、端到端输出速率、有效样本数 | 3、7、8 |
| 角色模型池 proxy 加固 | 真实传输结果、双协议路径、预算、回退、冷却与恢复、可解释统计 | 2–7 |
| UI 美化/体验提升 | 状态一致、保存闭环、实时更新、窄窗/键盘可用，然后视觉统一 | 8、9 |
| 保持轻量 | 不做功耗电费；Agent 管理等增强不阻塞核心 | 全部 |

“按天”是近 30 天内的日宽分桶，“近 30 天”不是自然月。自然日历的“今日/本月”若以后增加，必须单独命名和定义；不把两种窗口混用。

## 2. v1 调研结论的纠正（静态核查，不冒充新实测）

- **30d 不能只补枚举。** metrics 内存 deque 上限 100000；历史查询也有限额。启动回放虽然请求 720h，不代表该范围数据完整，回放顺序与淘汰顺序也需测试。参考 `inferfabric/metrics_aggregator.py`、`db.py`、`telemetry.py`（均位于 macfabric_gateway 下）。
- **App 数字源与刷新有缺口。** `fetchCurve()` 只消费 local，顶部总数据由此求和；`fetchMetrics()` 只在初始化拉取。新增窗口前先纠正它们，不能只做 picker。
- **route 不是候选链。** 现有 route 主要记录最终承接目标，失败尝试主要进进程日志；DB 无法可靠还原 attempts、回退或首选承接率。有 metadata/cost 列不代表写链已贯通。
- **失败日志可能缺失。** dispatch 的部分错误路径 route=None，而 SQLite route 为 NOT NULL，INSERT OR IGNORE 会静默跳过；即时内存、JSONL 与重启回放可能不一致。
- **转发成功信号需先修。** 本地 OpenAI 分支存在非成功响应或流异常被包装为成功的路径；Mac 本地 Anthropic 池的原生/翻译能力映射也不能等同于直连。
- **预算与半开不是边角美化。** 同步发现发生在尝试预算之前，多层 gate 和 socket timeout 不等于端到端截止；半开权在若干未准入/预算/异常出口可能泄漏。
- **不自动永久 FAILED。** 401/403 是运行健康问题，不直接证明协议不兼容。现有失配证据主要被忽略，并非已有完整 STALE 发布链；指纹也未覆盖认证版本。
- **原有 18/18 只算历史冒烟记录。** 不把临时目录中的脚本当可持续回归底盘，需归档用例与确定的执行入口，确保导入的是 macfabric_gateway 而非 vendor。

## 3. 统一统计契约（P0 冻结后供后续任务使用）

### 3.1 时间、快照与完整性

- `window`: `1h | 24h | 7d | 30d`，默认 24h；标签写完整“近 …”，不展示含糊的“月”。
- 统计区间 `[since, until)`；同一报告只取一次 until，所有分组和图共享区间及 SQLite 一致性读快照。
- 请求按**完成时刻**计入，跨零点请求不按开始时刻重复计算。输出时间戳为 epoch 秒；界面显示本地时区和明确区间。
- v2 滚动分桶：1h=12×5min，24h=24×1h，7d=28×6h，30d=30×24h；均从 since 划分，按实际秒长，不冒称本地自然日。跨时区/DST 只改变显示，不改变合计。
- 保留已有端点无新参数时的窗口/墙钟语义，不能为了原生 App 破坏 Web 回退；统一报告使用独立 v2 契约，不混用旧窗口结果。
- 持久统计允许日志批量写入带来的短暂最终一致（当前 logger 有批量缓冲），不在每次查询强制 fsync。报告输出 collected_at、since、until、coverage 与数据质量说明；不能以“最后一条请求很旧”误判采集故障。
- 精确计数/token 不能被 100000 上限截断。性能分位若未来采用近似算法，须单独声明算法/误差，不能悄悄抽样；本轮先使用分页/完整样本的精确计算加缓存。
- 新安装、留存裁剪或旧失败记录缺失时标明覆盖不足；不承诺修复前历史完全准确。默认留存 90 天不在本轮擅自缩短。

### 3.2 身份、请求与尝试

- 分组身份：`(location, provider, actual_model_id)`；location=local/cloud，local 的 provider 为空。显示名称不得成为聚合主键。
- 记录逻辑池名、请求中的候选模型名与实际传输模型名，别名不混淆真实目标；历史缺身份时标记 unknown，不用当前配置回填猜测。
- 一次逻辑请求恰一条最终 RequestLog；auth/selection/gate/预算失败也记入逻辑分母，并单列“未到达上游”。物理模型成功率仅统计归属到该目标的实际尝试，不能把未知目标错误算给首选。
- `attempt_count`: 真正发起的上游调用数量，准入失败不计；`retry_count`: 同目标再调用次数；`fallback_count`: 切换至不同目标并实际发起调用的次数。直接择中次位（如首位冷却）不算发生回退。
- 候选承接分布=最终实际目标分布；“首选承接”不根据当前排序倒推。缺尝试摘要的旧行，相关指标为 null/unknown，并显示有摘要的覆盖率。

### 3.3 指标含义

- 逻辑成功=响应按目标协议正常完成且无网关错误；HTTP 状态、committed 与完整性分别保存，HTTP 200 的流中断不是成功。
- tokens 输入/输出分开，usage 缺失与真实 0 区分；本地+云端=总量（未归属项单列）。
- TTFT 分两层：逻辑TTFT从网关接收请求起，到首个有效输出；模型TTFT从该次上游调用开始计时。仅流式且能识别首个有效输出时计入，不能把headers/角色/保活事件当首token；端到端耗时从网关接收至终态，含池内排队/等待/回退。
- TPOT沿用可测的近似值 `(attempt_duration_ms - attempt_ttft_ms) / (tokens_out - 1)`，限定正常完成的流式尝试、tokens_out≥2且有效耗时为正；标为估算ms/token，不声称逐token硬件采样。不得把逻辑排队/回退耗时混入该公式。旧行无法证明起点或eligible条件的指标排除，并显示有效样本覆盖率。
- 性能表显示 p50/p95 与样本数，分位统一使用排序样本的线性插值算法（索引 `(n-1)×q`，q=0.5/0.95）；端到端输出速率明确标 `tokens_out / 总耗时（tok/s）`，不冒称纯解码速率。不对分桶 p95 再求平均来产生全窗 p95。
- 非流式、短输出、缺 usage 的不适用指标显示“—”；少样本明确标注，不能用 0 代替未知。
- 云费用标为估算：按实际 provider/model 的已知价格计，未配价显示未配置/估算不完整。旧 token 按当前价格重算必须说明，不冒称历史账单；失败尝试缺 usage 时不声称包含全部上游消耗。
- 错误 Top 使用有限分类（鉴权、无可用候选、限流、连接、上游4xx/5xx、超时、流中断等），不把敏感原文直接显示或落入监控摘要。

## 4. 阶段依赖与文件边界

执行顺序：**P0 契约/测试底盘 → P1 记录与传输正确性 → P2 路由可靠性 → P3 监控完整纵向交付 → P4 体验/美化 → 发布验收**。P1 未通过不得承诺统计可信；P2 未通过不得以几次成功调用宣称池可靠。

| 文件/模块（已有） | 责任与变更边界 |
|---|---|
| `macfabric_gateway/inferfabric/proxy/request_logger.py`、`db.py`、`telemetry.py` | 终态日志、版本化摘要、SQLite 完整落库及一致性查询 |
| `macfabric_gateway/inferfabric/model_pool/dispatch.py`、`pool_forward.py` | AttemptResult、终态、预算、回退与半开生命周期 |
| `macfabric_gateway/inferfabric/proxy/chat_handlers.py`、`forwarder.py`、`proxy/anthropic_bridge.py` | 可重试/已提交边界、双协议传输、流完整性与中断 |
| `macfabric_gateway/inferfabric/ratelimit.py`、`proxy_manager.py`、`cloud_discovery.py` | 排队预算、后台发现单飞及 last-known 状态 |
| `macfabric_gateway/inferfabric/model_pool/{config,catalog,registry,evidence,admin}.py` | 参数校验、协议映射、证据与健康分离、管理可观测性 |
| `macfabric_gateway/inferfabric/metrics_aggregator.py`、`proxy/handler.py` | 旧统计兼容、报告路由；不把新 SQL 大段塞进 handler |
| `macfabric-app/Sources/MacFabricApp.swift` | store/视图/原生交互；本轮先局部组织，不无故改构建布局 |

计划新增：`macfabric_gateway/inferfabric/monitor_report.py`，统一窗口、身份、分桶与报告聚合；测试放 `macfabric_gateway/tests/unit/`。本文件以下接口均为**拟新增或拟调整契约**，不是声称现有代码已提供。

---

## P0 — 定义口径与验收样本

### Task 1：统一统计模型和确定性样本

**Files:** 新建 `macfabric_gateway/inferfabric/monitor_report.py`、`macfabric_gateway/tests/unit/test_monitor_contract.py`；补文档中的字段契约。

**Interfaces:** `resolve_window(window: str, until: float) -> tuple[float, float, int]` 返回 since/until/桶数；`model_identity(row: dict) -> tuple[str, str, str]` 返回分组身份。以第3节为唯一口径。

- [ ] 写 `test_window_boundaries`：固定 until，四档跨度分别为 3600/86400/604800/2592000；since 纳入、until 排除；各桶相加等于全窗合计。
- [ ] 写 `test_model_identity_and_unknown`：相同 model_id 的两个 provider 不合并，本地同名不混入云端；历史字段缺失保持 unknown。
- [ ] 运行上述用例确认红灯，再实现最小纯函数，复跑确认绿灯。
- [ ] 建立合成样本：成功/失败/无上游/重试/切换/流中断/缺 usage/别名/已删池历史；全部不调用真实上游、不使用用户凭证。评审契约后按授权提交。

## P1 — 修观测与转发正确性

### Task 2：终态日志完整落库，贯通尝试摘要

**Files:** 修改 `proxy/request_logger.py`、`db.py`、`telemetry.py`、`model_pool/dispatch.py`、`model_pool/pool_forward.py`（完整路径见第4节）；新建 `macfabric_gateway/tests/unit/test_pool_request_log.py`。

**Interfaces:** RequestLog 增加可选 `metadata: dict`（缺省空）；metadata 中 `pool_summary` 版本1：pool/protocol/config_revision、requested_model、first_attempted/final_target、attempt_count/retry_count/fallback_count、outcome、精简 attempts。目标含 candidate_id、provider、requested_model_id、actual_model_id；每个已发起attempt含status/error_class、committed/completed、stream、duration_ms/ttft_ms、tokens_in/tokens_out及usage_known，均遵循第3节起点和有效性定义；未知字段明确 null。逻辑日志另记全程duration/ttft，不用最终尝试覆盖全程值；直连请求也产出相同的单attempt观测字段，不人为加pool名。新增字段不保存秘密。

- [ ] 写 `test_pool_errors_persist`：未知池、鉴权拒绝、无候选、gate拒绝、预算耗尽均恰一条 SQLite 终态记录；route 非空，保持 pool 前缀；不能只检查内存/JSONL。
- [ ] 写 `test_attempt_summary_roundtrip`：同目标重试一次后成功=2 attempts/1 retry/0 fallback；A失败转B成功=2/0/1；准入拒绝不计 attempt；旧metadata缺失保持未知。
- [ ] 先红灯，再贯通摘要序列化/批量写入/回读，校准“无网络调用”的 admitted 标志；结构化传输未完成的部分由 Task3 接续锁定。
- [ ] 复跑确认终态一行且汇总重启可读；不得用每 attempt 一行污染请求数。排查异常忽略路径，给无法保存的记录可感知告警。按授权提交。

### Task 3：真实传输结果与 Mac 双协议覆盖

**Files:** 修改 `model_pool/dispatch.py`、`pool_forward.py`、`proxy/chat_handlers.py`、`forwarder.py`、`proxy/anthropic_bridge.py`、`model_pool/catalog.py`；新建 `macfabric_gateway/tests/unit/test_pool_transport_contract.py`。

**Interfaces:** 各池传输统一返回既有 `AttemptResult`，补响应完整性与实际目标身份；布尔“发送过响应”不得等同 ok。入站协议、实际传输协议和流结束状态分别可识别，日志用 Task2 的摘要。

- [ ] 写 `test_non_2xx_is_not_success`、`test_committed_error_never_replays`：本地/云端错误状态保真；未提交才可按动作表回退；已发headers/字节后只结束当前响应，不写第二个错误信封。
- [ ] 写 `test_stream_terminal_and_disconnect`：正常结束、缺终止标志、显式错误事件、读异常、客户端断开分开分类；中断不得记作正常成功，不伪造 usage。
- [ ] 写 `test_mac_anthropic_pool_paths`：llama_cpp 原生/非原生及 Ollama 等适配路径按真实能力走原生或 Anthropic→OpenAI 桥；不支持时明确排除，不因漏声明悄悄改选云端；位置约束仍有效。
- [ ] 写 `test_direct_and_pool_observation_parity`：直连/池共用相同attempt起点与usage未知语义；先前失败/等待只能影响逻辑耗时，不混入最终模型TPOT；对Task2摘要逐字段回读验证。
- [ ] 先红灯，再最小调整结构化传输与协议映射；金标验证文本/工具/图像块/流式协议契约，不从一次文本成功推断其余功能。复跑通过后按授权提交。

## P2 — 角色模型池路由可靠性

### Task 4：绝对截止与半开探测权生命周期

**Files:** 修改 `model_pool/pool_forward.py`、`dispatch.py`、`ratelimit.py`、相关传输文件；新建 `macfabric_gateway/tests/unit/test_pool_deadline_recovery.py`。

**Interfaces:** 池入口建立同一单调时钟 `deadline_at: float`；逻辑gate、物理gate、429等待、连接/读流/唤醒等待使用 `max(0, deadline_at - monotonic())`，每阶段后重新计算。保留非池路径兼容默认参数；超时不是各阶段各获一次完整预算。

- [ ] 写 `test_deadline_includes_all_waits`：假钟下排队/上游耗时/Retry-After累计不得突破预算；观察模式也尊重池硬截止，不因固定300s等待绕过；流持续发小片也不能无限延长总预算。
- [ ] 写 `test_half_open_release_all_exits`：预算已尽不先领取探测权；未准入、抛异常、客户端取消后探测权可重获；并发时仅一个真实半开探测，拒绝准入不误记端点失败。
- [ ] 先红灯，再补绝对截止及显式取消/释放。预算耗尽在未提交时发正确协议错误；已提交时只终止流并记中断。无法中断的底层调用须给有界等待方案和证据，不得继续标硬预算已完成。
- [ ] 用假钟和本地伪上游复跑两协议/流与非流，不依赖远端耗时断言。保持现有错误动作表；max_attempts包括同目标重试，若重试耗尽预算则不承诺还能切候选。按授权提交。

### Task 5：发现移出请求关键路径，保持白名单

**Files:** 修改 `proxy_manager.py`、`cloud_discovery.py`、`model_pool/dispatch.py`；新建 `macfabric_gateway/tests/unit/test_cloud_discovery_singleflight.py`。

**Interfaces:** `ensure_cloud_discovered(background: bool = False) -> None` 保留旧默认兼容；池调用 background 模式只确保单个后台任务，使用启动已有 specs/enabled_models floor。发现失败可重试，成功后衔接既有轮询与价格刷新，退出有生命周期管理。

- [ ] 写 `test_slow_discovery_not_on_pool_path`：阻塞的伪 /models 不阻塞已有目标选择；本地首选不等待云发现；无last-known时快速明确错误。
- [ ] 写 `test_concurrent_discovery_singleflight`：并发冷请求只启一个发现任务；失败后可再触发；完成不扩大白名单、不唤醒本地、不重复启动轮询。
- [ ] 先红灯再实现，复跑并与 Task4 预算联测。验收的是“发现不阻塞”，不是要求慢推理两秒内完成。按授权提交。

### Task 6：可恢复健康状态、协议证据与参数校验

**Files:** 修改 `model_pool/{config,registry,evidence,admin}.py`、`pool_forward.py`；新建 `macfabric_gateway/tests/unit/test_pool_health_policy.py`。

**Interfaces:** 继续使用 runtime/events 输出健康、冷却、隔离和原因；**生产401/403不自动写永久FAILED**。兼容性证据仍独立，管理视图明确区分“配置声明”“运行观察”“显式探测结果”。max_attempts/deadline 的raw写入保持CAS。

- [ ] 写 `test_auth_failure_recovers`：401/403冷却后可半开，更换凭证后可恢复；健康状态变化不悄悄覆盖管理员显式FAILED。Task4负责权释放。
- [ ] 写 `test_pool_parameters_strict_validation`：bool/小数/字符串/零/负值服务端拒绝，不靠int强转；建议新写入范围 max_attempts=1..10，deadline_ms=1000..300000。实施前扫描旧配置，超界存量需显式迁移决定，不自动裁剪；范围为技术建议并非既有用户裁决。
- [ ] 复跑范围边界、409、raw无损保留及错误文案；实现健康可观测和参数校验后按授权提交。
- [ ] **后置门禁：**本轮不自动把生产成功写成PROBED。若后续需要，先另立证据子计划，覆盖实际协议/模型/认证版本指纹、FAILED清除/重探测、失配发布、线程安全与异步有界落盘；不得每请求fsync，不得记录成功后让管理快照永不更新。

## P3 — 监控完整纵向交付

### Task 7：同快照报告与基础池统计

**Files:** 实现 `monitor_report.py`；修改 `db.py`、`proxy/handler.py`、必要的旧统计适配；新建 `macfabric_gateway/tests/unit/test_monitor_report.py`。

**Interfaces:** `build_monitor_report(db, *, window: str, until: float, scope: str = "all") -> dict`；拟新增 `GET /api/monitor-report?window=1h|24h|7d|30d&scope=all|local|cloud`。报告含契约版本、区间/采集时间/覆盖说明、totals、models、series、pools、errors；身份与摘要遵守第3节。不再并行新增另一套口径不同的 pool-stats 引擎；确有独立端点消费者时才加薄封装。

- [ ] 写 `test_full_window_over_100k`：合成100001+条，精确count/token/分组无截断，重启回读不变；所有模块使用同一读快照与区间。
- [ ] 写 `test_scope_identity_and_percentiles`：本地+云端+未归属=总量；跨provider同名不混合；全窗p95按有效原样本求，不平均桶p95；图桶合计匹配指标；缺TTFT/usage/价格为未知而非0。
- [ ] 写 `test_pool_summary_coverage`：早期失败入分母，删除池历史仍可查；最终承接分布和attempt/retry/fallback准确；老摘要缺失不补造数值，输出覆盖率。
- [ ] 先红灯再实现完整SQL计数与有界分页性能样本计算。提供按window/scope的短TTL单飞缓存；返回同一报告内数字/表/图一致；保留旧API无参行为。错误Top脱敏。
- [ ] 复跑容量、空态、日志批量刷入前后最终一致和旧端点兼容；记录查询耗时/内存样本，不能把大扫描接到3s全局轮询。按授权提交。

### Task 8：原生监控台与池运行态

**Files:** 修改 `macfabric-app/Sources/MacFabricApp.swift`；新建 `docs/qa/monitor-pools-v2.md`（未来验收用例和证据索引，本轮不创建）。

**Interfaces:** store 拟增 `fetchMonitorReport(window:scope:)`、`monitorSelection`、`monitorLoadState`、`monitorGeneration`，消费Task7报告；池候选健康来自Task6 runtime/events，不用“注册表存在”冒充请求正在调用。

- [ ] 先在QA文档写场景与预期：四档快速切换只呈现最后一次；成功/失败新请求在下次持久统计刷新出现；筛选期间旧数据须带旧区间/更新中标识，不套新标签。
- [ ] 界面纵向：范围/来源筛选 → 请求/成功率/输入输出tokens/费用估算 → 用量趋势 → 模型表和选中模型详情/TTFT-TPOT耗时趋势 → 基础池统计与错误分类。性能详情含样本数/单位；模型名完整可查看；不默认展示全部折线。
- [ ] 显示时立即拉取；监控页可见时建议15s刷新、手动刷新可用、同查询单飞。离页或关窗暂停重查询，重新进入立即更新；请求generation防旧响应覆盖，取消网络请求不代替generation校验。避免所有子视图重复发请求。
- [ ] 池卡摘要保持轻量：近24h逻辑请求/成功率/最终承接，详情再展开回退与冷却原因；原有URL/API Key/model调用指引保留，不恢复每池复制内部YAML按钮。
- [ ] 调试构建后逐项实际操作取证，核对API与SQLite；主窗口关闭/重开、离线/恢复、无数据/覆盖不足/部分未知均验收。按授权提交。

## P4 — 体验闭环优先，视觉其次

### Task 9：保存、冲突、拖拽和状态一致性

**Files:** 修改 `macfabric-app/Sources/MacFabricApp.swift`；补充 `docs/qa/monitor-pools-v2.md`。

**Interfaces:** 表单草稿与服务端确认态分离；请求返回成功并应用对应新状态后才关闭编辑器。池mutation按意图顺序串行执行，轮询结果按revision/会话代际校验，不允许旧响应覆盖乐观状态；网关重启后revision重置须重新建基点，不能永久忽略较小revision。

- [ ] 先写并执行反例：非法数字、保存500/断网、409、连点排序交错、拖到其他池/窗外取消、未保存按Esc；确认现状缺口后记录预期。
- [ ] 数字非法保留输入并字段内报错，空白才是清除；busy时明确反馈，失败不关弹层/不丢草稿，成功才更新chips并收起；Esc/点外有未保存修改时确认丢弃，不能一律静默关闭。
- [ ] 同池拖拽携带pool+candidate身份，禁止误操作其他池；取消后清理拖拽高亮；冲突不静默覆盖他人配置，失败回滚可解释，不以盲重试承诺“不丢点击”。
- [ ] 池高级设置接入Task6的max_attempts/deadline_ms，显示当前值和单位；说明重试也消耗尝试次数、预算包含排队/回退。客户端与服务端范围一致，CAS保存不重建有损配置；未修改字段原样保留，错误与冲突留在编辑器内。
- [ ] API Key保留一次性复制与已撤销最多3条显示；最后有效key撤销需明确风险提示，未保存明文不被第二次新建覆盖；操作错误在当前设置卡可见，不泄漏明文到日志。
- [ ] 重放上述QA场景，均不切卡片完成验证；对动作与数据可见延迟分别记录，禁止只用接口成功替代UI通过。按授权提交。

### Task 10：轻量视觉与可访问性收口

**Files:** 修改 `macfabric-app/Sources/MacFabricApp.swift`；补QA证据。

**Interfaces:** 保持light tokens和原生控件；反馈采用有类型的成功/进行中/警告/失败状态，不以解析emoji字符串作为长期逻辑。操作结果与数据刷新状态分开。

- [ ] 先列验收：窄窗口无关键控件裁切、长modelid可查看/复制、Tab键可达、⌘1–8导航、Esc安全关闭、减弱动态效果生效。
- [ ] 统一加载/空/错/旧数据状态、反馈色与图标；危险操作入口始终可发现，不只hover出现。池卡次要操作收菜单，保留明确排序入口。
- [ ] 重组设置分区，未接线功能诚实标注；菜单栏保持网关/模型状态和打开主窗口能力，缺失才补，不重复造功能。最后才加克制动画，不给每个按钮无差别转圈。
- [ ] 在目标最小窗口与键盘路径验收，开启减少动态效果核对；无图表数据也能读懂说明。按授权提交。

## 5. 验证入口、阶段门禁与发布

以下命令仅为**未来执行说明，本轮未运行**。新增测试文件均为计划产物，当前不存在。

- 单任务：`PYTHONPATH=macfabric_gateway .venv/bin/python -m pytest macfabric_gateway/tests/unit/<对应文件>.py -q`；先确认测试依赖可用、导入路径指向macfabric_gateway，再执行红/绿循环。
- 本仓回归：`PYTHONPATH=macfabric_gateway .venv/bin/python -m pytest macfabric_gateway/tests/unit -q`；现有vendor池/统计用例作为适配参考，不通过切换PYTHONPATH到vendor来冒充产品回归。
- 调试构建：先读 `macfabric-app/build.sh` 的调试参数，再使用其调试档；不猜参数，不直接晋升。网关前检确认端口/状态目录/进程归属。
- 原历史18项冒烟需整理成仓库内确定性回归入口，记录每项断言/数据准备/清理/退出码；结果输出有真实终态，后台长链有失败与停工可感知信号。不以“18/18”的旧文本替代本轮执行证据。

**发布顺序必须是：**调试环境红/绿与故障注入 → 自动回归 → 原生UI验收 → 记录证据与剩余限制 → 按授权提交/推送 → 获准后晋升安装版 → 最小健康检查及必要回滚。不得先替换安装版再做第一次功能验证。

**至少覆盖的集成矩阵：**

| 类别 | 必须通过的场景 |
|---|---|
| 数据正确性 | 100001+条、跨时间边界、重启、同名跨provider、缺usage/价格、已删除池历史、旧行摘要未知 |
| 转发 | 两协议×流/非流×本地/云端；本地原生/桥；非2xx、SSE中断、客户端断开、已提交不回退 |
| 回退/恢复 | 连接错误、429等待、5xx一次重试、401/403冷却、现有404隔离规则；半开遇未准入/异常/预算耗尽；换key恢复 |
| 预算 | 冷发现单飞不阻塞、逻辑/物理gate满、小deadline、慢持续分片、重试等待超剩余时间 |
| 原生UI | 不切页实时排序、连点/取消/冲突、快速切窗口、保存失败草稿、窄窗/键盘、关窗停轮询后重开恢复 |
| 安全/运维 | key不入监控/日志、鉴权和白名单不扩权、调试安装隔离、无额外常驻采样、测试不遗留有效key/改坏真实配置 |

## 6. 明确后置与实施前门禁

- 后置：自然日“今日/本月”、90天/周档、完整Agent/UA/API Key用量管理、暗色主题、⌘K、冷却持久化、自动PROBED写入及显式探测管理；不为复用旧端点把它们塞回首版。
- P0结束前冻结第3节数据契约；参数范围是技术建议，需结合存量扫描确认。若不能做到硬deadline，须降级并明确标注软预算，不能继续沿用硬预算验收宣称。
- 若实施发现必须迁移schema、改变既有错误回退动作表/证据安全语义、放宽授权、增加依赖或拆大模块，应停下补方案并获准，不边实现边猜。
- 实施前需再次核对工作区与用户当时授权；本文件的完成不表示代码、回归、部署已完成。

## 7. v2 自审记录

- 需求覆盖：第1节逐项映射到任务；排除项单列，不再把完整上游控制台当轻量版范围。
- 数据契约：范围/分桶/身份/请求与attempt/成功与性能/费用与缺失值统一，不再承诺从route恢复不存在的候选链。
- 风险闭环：五项Review Focus均有对应任务断言；证据FAILED死锁风险从实施项中移除，采用可恢复健康状态。
- 依赖与验收：先日志/结果真实性再统计与展示；新接口与旧端点兼容；测试命令针对本仓内核；先调试验证后安装版晋升。
- 本轮交付范围：仅将本文件更新为v2；没有执行任何待办、测试、代码修改、部署、commit或push。
