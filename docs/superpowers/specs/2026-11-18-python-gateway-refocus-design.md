# MacFabric 回归纯 Python 网关 + 平台抽象层重构（上游 cherry-pick 化）— 设计文档

> 日期：2026-11-18 · 状态：待用户裁决
> 关联基线：docs/PLAN.md（D1–D14 沿用，本文修订其中 UI 相关结论并新增 D15–D18）

## 1. 意图与动机

放弃 SwiftUI 原生 App 这条产品线，MacFabric 收敛回**纯 Python 网关 + Web Dashboard**（InferFabric 原本的产品形态）。终极目标：Mac 侧验证好的特性最终**合入 InferFabric 上游**，使 InferFabric 同时适配 **x86（CUDA/Blackwell）与 Apple Silicon（Metal/统一内存）** 两个硬件平台。

动机（用户原话归纳）：
- 单人维护不动"网关 + 原生 App"双前端；SwiftUI App 是当前与上游偏离最大的部分。
- 分叉包 `macfabric_gateway/` 与上游的偏离应当是**平台层**的偏离，而不是产品分叉。
- 上游合入通过 **cherry-pick** 完成，由**上游责任人**负责执行；本工作区只负责把特性做成"可 cherry-pick"的形态，**不在本工作区实施合入**。

## 2. 目标 / 非目标 / 反目标

**目标**
1. SwiftUI App 线彻底删除（D17，2026-11-18 已执行）；UI 能力全部由 Web Dashboard 承接。
2. Mac 特性收敛为平台抽象层，与网关核心解耦，形成清晰的 cherry-pick 单元。
3. Dashboard 补齐 App 已有且仍需要的功能页（对齐清单见 §6）。
4. 建立 cherry-pick 工作流与清单（§7），让上游责任人可以按特性逐个摘取。
5. 吸收 opencodex 的四个可借鉴设计（§8）。

**非目标**
- 不在本工作区执行向 InferFabric 上游的合入（不发 PR、不改上游仓库）。
- 不新写原生代码（Swift/菜单栏壳本期不做，见 D18）。
- 不新增引擎适配（MLX、mflux 等另立议题，不混入本次重构）。
- 不改变 :8999 双协议入口与既有 models.d schema 兼容承诺。

**反目标（出现即失败）**
- 平台抽象做成"if darwin 散落各处"的第二代分叉——必须收敛在 platform 层内。
- cherry-pick 单元互相纠缠，摘一个特性必须连带摘半个网关。
- 为了上游化牺牲 Mac 侧现有已验证行为（回归基线不回退）。

## 3. 约束

- C1 上游 ~12k 行网关 + 近 2000 测试是资产，重构以"最小触碰上游文件"为第一原则。
- C2 本机是 Apple Silicon；x86/CUDA 路径的回归只能靠上游责任人执行，本工作区需保证平台分支**测试可在任一平台跑**（单测纯逻辑、平台探测可 mock）。
- C3 内存账本三规则（PLAN §3）是已裁决行为，抽象层不得改变其语义。
- C4 vendor/ 只读参考、gitignore；上游对应版本以其 git 历史为准。
- C5 现有 admin API 端点（App 时代沉淀）全部保留——它们是 Dashboard 的后端。

## 4. 已裁决结论（新增/修订）

| # | 决策 | 结论 |
|---|---|---|
| D15（修订 D3） | UI 形态 | **放弃 SwiftUI App 产品线**，UI = 上游式 Web Dashboard（挂在 :8999 网关同端口）。D3 的"菜单栏常驻 + 主窗口"结论废止 |
| D16 | 上游合入方式 | cherry-pick，**由 peer session `inferfabric-pr` 负责向上游提交 PR 与合入事务**（2026-11-18 用户裁决）；本工作区交付物 = 干净的特性分支 + 摘取清单 + 每特性验收测试，交由该 session 执行上游动作；本工作区不直接 push 上游、不开 PR |
| D17（用户裁决 2026-11-18） | App 代码处置 | **彻底删除**："不完美的东西宁愿不要"。安装版 /Applications/MacFabric.app、dev 版与 build 产物、`macfabric-app/` 源码、`~/.inferfabric-dev`、App 缓存全部清除（源码可从 git 历史找回）；网关侧 `~/.inferfabric` 与 `com.macfabric.gateway` 守护保留 |
| D18（用户未反对，按此执行） | 常驻入口 | 本期纯 headless + 浏览器；菜单栏薄壳（点开=浏览器开 Dashboard）作为后续可选项另立 |
| D19（用户裁决 2026-11-18） | autostart 归属 | **网关自身托管**（维持现状：网关启动钩子 best-effort 拉起）；D13 的 LaunchAgent/App 子进程托管切换随 App 废止；procguard 仅负责网关自身守护 |
| D20（用户裁决 2026-11-18） | 34 个演进 diff 归宿 | **分级整理**：M1 增设 diff 审计子阶段——通用修复 → 逐个做 pick 分支上游化；平台相关 → 并入 platform 层；Mac 专属 → 留 fork |
| D21（用户裁决 2026-11-18） | 上游接收意向 | 上游责任人**已确认接收** cherry-pick → 摘取基建严格按 §9 全等级执行 |
| D22（用户裁决 2026-11-18） | 重构期节奏 | main **不冻结**新特性；接受 pick 分支事后 rebase，manifest 记录基线 commit 供对齐 |

## 5. 方案比较（已裁决：方案 A）

- **方案 A（选定）：平台抽象层重构 + 特性分批 cherry-pick 上游化**。Mac 特有部分收敛进 platform 层，网关核心与上游同构，UI 回归 Web Dashboard。正中"合入 inferfabric、双平台适配"目标；代价是一次性重构 + Dashboard 补页。
- 方案 B（否决）：维持分叉仓库、只砍 App 线、不做平台抽象。改动最小但与合入目标相悖，长期双份网关代码。
- 方案 C（否决，可作为 A 完成后的终态）：MacFabric 仓库退役，直接在上游仓库开发 Mac 线。单一真相源最彻底，但本地迭代被上游节奏绑死，且分叉包需先"搬回"上游才能开工，前期成本最高。
- 合入模式（D16，2026-11-18 修订）：向上游提交 PR / 跟进合入的事务由 peer session `inferfabric-pr` 承接；本工作区每完成一个 pick 分支即更新 manifest 并通知该 session，两边通过 manifest 对账（状态：待摘取 / 已提交 PR / 已合入 / 被退回）。

## 6. 现状与偏离盘点（设计输入）

### 6.1 分叉包 vs 上游（实测 diff）

- 改动文件 34 个（forwarder/manager/model_pool/proxy/security 等，均为演进性改动而非重写）。
- 新增文件 9 个：`mac_platform.py`、`memory_ledger.py`、`anthropic_translate.py`、`jobs.py`、`monitor_report.py`、`packs/`（11 模块）、`proxy/anthropic_bridge.py`、`proxy/pack_handlers.py`、`proxy/responses_bridge.py`（/v1/responses 原生优先入口已于 11-17 落地）。
- Dashboard 已有分叉改动：`dashboard/fragments/model-pools.html` + `js/model-pools.js`（池 v2：flash/lite/max）。

### 6.2 上游 Dashboard 已有页面

overview / cloud / deploy / inference / monitor / model-pools / anomaly（+ style.css、charts/store/ui 基建）。

### 6.3 App 功能页 → Dashboard 承接映射

| App 功能 | Dashboard 承接方式 |
|---|---|
| 总览（内存织物条 + 网关状态） | overview 页增强：内存账本 committed/B + 压力灯 |
| 模型服务（switch/stop/autostart） | deploy 页（上游已有），补 autostart 开关 |
| 本地推理（试聊） | inference 页（上游已有试聊） |
| 模型池（拖拽排序/候选链/CAS） | model-pools 页（分叉已改，池 v2 已上线） |
| 云端接入（服务商 CRUD/发现/策展/VL 打标） | cloud 页增强（策展行、协议 chip、属性浮窗） |
| 能力包（下载/装机/卸载/进度） | **新增 packs 页**（packs/ 模块 API 已齐，纯前端补页） |
| 监控台 | monitor 页（上游已有） |
| 设置 + 安全密钥（enable/一次性回显） | **新增 security 设置页**（security/admin API 已齐） |
| 拷贝配置按钮 | 升级为 Connect 页（§8 借鉴 1） |

## 7. 平台抽象层设计（核心）

```
inferfabric/
├── platform/                  # 新：平台抽象层（唯一允许感知操作系统的层）
│   ├── __init__.py            #   探测与装配：detect() → PlatformProfile
│   ├── resource.py            #   ResourceLedger 接口（准入/装载模式/压力安全网 三规则语义）
│   ├── resource_vram.py       #   CUDA 后端：包装上游三态 GPU 状态机
│   ├── resource_umem.py       #   统一内存后端：现 memory_ledger.py 迁入（B=RAM−reserve）
│   ├── procguard.py           #   进程守护抽象：launchd(mac) / systemd(linux) / 无（前台）
│   └── engines.py             #   平台默认引擎矩阵（cuda 线 / metal 线）
├── memory_ledger.py           # 迁移期 shim：re-export platform.resource_umem（保留兼容）
└── mac_platform.py            # 迁移期 shim：拆散并入 platform/*（lsof/vm_stat 等实现归位）
```

- **装配点唯一**：manager/proxy 等上游核心只依赖 `ResourceLedger` 接口与 `PlatformProfile`，不 import 平台实现；上游核心文件因本次重构的触碰收敛为"接口注入"级别的最小 diff。
- **三规则语义不变**（C3）：准入拒绝弹窗文案、resident/on_demand、压力卸载均由接口定义，两后端各自实现。
- **迁移期 shim**：旧模块名保留 re-export 一个版本周期，App 时代脚本不立即断。

## 8. opencodex 借鉴（四项，均已评估落地方式）

1. **Connect 页（托管客户端配置）**：Dashboard 新增 Connect 页——不止"拷贝配置"，一键把 Claude Code / Codex 等工具的 base_url/auth 指向 :8999（写目标工具的配置文件前需显式确认 + 可回退）。落地为 `platform/clients.py` + dashboard/fragments/connect.html。
2. **Responses API 入口**：`proxy/responses_bridge.py` 已有原生优先版本（11-17），本次仅纳入 cherry-pick 清单并补齐上游可跑的合同测试。
3. **账号池 + 配额路由 + 会话亲和**：云端聚合增强（多 key/多账号轮询、配额感知路由、会话粘住首账号）。本期只做**设计占位与接口预留**，实现另立议题（避免重构期混入行为变更）。
4. **菜单栏薄壳**：后置为可选项（D18），形态=极薄菜单栏项点击开浏览器，不是控制面。

## 9. cherry-pick 工作流（D16 落地方式）

- **分支纪律**：每个可摘取特性一条分支，基于上游对应基线（vendor 记录的上游版本）rebase 出 `pick/<feature>` 分支；MacFabric main 照常集成演进（D22：不冻结新特性，pick 分支允许事后 rebase，manifest 记录基线 commit 供对齐）。
- **变更形态约束**：
  - 新功能进新文件/新目录（platform/、packs/、*bridge.py、dashboard 新 fragments）——上游摘取零冲突；
  - 触碰上游既有文件时，diff 必须是"注入点"级别（接口、一行装配、一个分支条件），并在清单中标注触碰文件与冲突风险。
- **摘取清单**：`docs/upstream/CHERRY-PICK-MANIFEST.md`——每条记录：特性名、pick 分支、commit 范围、新增文件、触碰的上游文件、依赖的其他特性、验收测试（上游平台可跑）、已知不适用项（如 umem 后端在 CUDA 机器默认不启用）。
- **跨平台可验证**：每特性附"平台无关单测 + 平台探测 mock 说明"；CUDA 侧行为验证归上游责任人，清单给出建议验收命令。

## 10. 里程碑（粗粒度，细化交 writing-plans）

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0 冻结 | App 线清除（D17，已完成 2026-11-18）、现行回归基线记录 | MacFabric 全量回归绿，基线入 docs |
| M1 平台层 | §7 抽象层落地，memory_ledger/mac_platform 迁移为 shim；**D20 diff 审计子阶段**（34 文件改动分级：通用修复/平台相关/Mac 专属三单归类） | 全部既有单测经 shim 通过；新增 platform 单测（两后端 + mock 探测）；diff 审计结论入 CHERRY-PICK-MANIFEST |
| M2 Dashboard 对齐 | §6.3 映射表：packs 页、security 页、overview 账本增强、cloud 策展增强、deploy autostart | App 每项功能在 Dashboard 有等价操作路径，逐条验收 |
| M3 opencodex 借鉴 | Connect 页 + responses 合同测试补齐；账号池出设计占位 | Connect 页实测改写/回退 Claude Code 配置 |
| M4 摘取基建 | pick/* 分支重建 + CHERRY-PICK-MANIFEST.md | 每特性分支在上游基线上可独立应用并通过其测试 |

## 11. 留给实施者的决定

- platform/ 内部文件切分的最终粒度、shim 保留时长（建议一个版本周期）。
- Dashboard 各页前端实现细节（沿用上游 fragments/js 模式，不引入构建链）。
- pick 分支的切分顺序（建议按 M1→M2→M3 依赖序，每特性一分支）。
- Connect 页支持哪些客户端先行（建议 Claude Code + Codex，其余按需追加）。

## 12. 评审裁决记录（builder check，2026-11-18）

以下为评审代拟、按"合理实施者可自行定夺"处理的项，用户可翻阅纠正：

1. pick 基线 = vendor git HEAD（e453a90），不追上游最新；上游前进由上游责任人 rebase。
2. shim 保留至"上游摘取成功"与"一个版本周期"先到者，shim 内加 DeprecationWarning。
3. pick 分支依赖序：platform 资源层 → procguard/engines → dashboard 新页 → responses 合同测试/Connect 页；账号池占位（仅接口）随 platform 首分支带上。
4. M0 回归基线 = `macfabric_gateway/tests` 全量绿 + :8999 双协议手动冒烟，记录入 docs/qa；上游测试抽样跑作平台无关证据。
5. 面向上游化的 dashboard 单元文案跟随上游既有风格；仅 fork 自用部分可中文，manifest 标注。
6. packs/security 页纯前端补页（后端 API 已核实齐备），M2 不新增后端端点。
7. Connect 页先行客户端：Claude Code + Codex。
8. App 处置升级为彻底删除（用户裁决，见 D17），M0 相应收敛为"基线记录"。
