# 产品整版升级 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让统一能力架构、既有模型、公开调用名与全部原生页面遵循同一产品定义。

**Architecture:** 先封闭隔离缺口，再建立产品资料与可恢复硬切迁移；UI、鉴权、目录和扩展消费同一合同。按子计划独立验证，最后通过同源双端发布产物交付，不把代码发布等同于生产迁移。

**Tech Stack:** Python / pytest / YAML / SQLite；SwiftUI＋AppKit＋Security Keychain；llama.cpp Metal；macOS launchd。

**Spec:** `docs/superpowers/specs/2026-11-16-product-definition-v2.md`、`docs/superpowers/specs/2026-11-16-ui-standard-v2.md`

## Global Constraints

- 当前仅文档落盘，所有实施步骤未执行；实施需用户审核本计划。
- 调用 ID 同步硬切，不保留旧 ID 路由别名；内部生命周期身份和历史日志保留。
- 默认 LLM/VL ≤4B；预算 `B = RAM − reserve`，env ＞ policy ＞ 8192 MiB；设置唯一编辑入口。
- 开发 8998、生产 8999；禁止直接写生产 DB，禁止全局 pkill proxy.handler。
- 模型源 ModelScope；引擎回归基线 b12361；新引擎版本另冻；Gemma/Whisper 既有源与许可裁决不变。
- 原生 SwiftUI＋AppKit，不用 WebView；三张视觉样稿确认前不写 UI 实现。
- 保持鉴权开启；不保存/输出真实密钥到文档、测试证据或示例。
- 生产只吃已验证发布产物，App 和网关同一 manifest；生产迁移、重启、安装、下载预算、对外发送单独报备。
- 未获明确要求不 commit/push；未来各任务绿灯后可本地审查 diff，但不把计划中的检查点当提交授权。

## Review Focus

1. 已规范 served_name 与旧内部 fallback 重叠：只退役真正旧集合，不能封禁新 canonical ID（A2/A4）。
2. 迁移预览后配置/密钥并发修改或断电：CAS 拒绝、维护锁、恢复日志，权限不扩大（A3/A4）。
3. 改名或排序后同名变体操作：实例身份不变、动作不串行、历史不合并（B1/B3）。
4. App 网关失联、Keychain 拒绝或切 profile：不误报免鉴权、不泄漏生产 key（B2）。
5. 安装/卸载/取消跨生产 realpath、runtime 共享引用：启动先阻断，清理不误删（A1/C1/C3）。

## 1. 文件责任与子计划

| 子计划 | 职责与主要文件 | 出口 |
|---|---|---|
| [A 基础与硬切](2026-11-16-product-foundation.md) | `inferfabric/product/` 新身份/迁移域；config/manager/proxy/security；scripts 隔离 | 独立开发环境、统一资料、可恢复硬切机制及沙箱演练 |
| [B UI 与鉴权](2026-11-16-product-ui-auth.md) | `macfabric-app/Sources/` 按资料/主题/Keychain/表格拆分；全页接线 | 三张样稿确认、全页规范、真实鉴权和按类型试用 |
| [C 目录与扩展](2026-11-16-capability-catalog.md) | packs schema/template/transaction/runtime；catalog；语义 fixtures | 四类型适配与逐型号证据、统一官方/用户安装链 |
| [D 验收与发布](2026-11-16-product-release.md) | D1成对产物、D2验收runner、D3恢复、D4整版签收 | runner先服务逐型号验证，最终门禁通过后才请求生产晋升 |

所有相对 Python 路径在子计划中以仓库根 `macfabric_gateway/` 为准。新文件在执行时创建，本轮只创建本组 Markdown。

## 2. 顺序与审核闸门

```text
A1 隔离 → A2 产品资料 → A3 迁移领域 → A4 公开路由硬切
                 ├→ B1 资料与视觉样稿 → 用户确认 → B2/B3/B4
                 └→ C1 统一事务/依赖 → C2 模板 → C3 URL/本机导入
                                         └→ D2 验收runner → C4 型号晋级
D1 双端产物管线、D3 回滚演练可先在fixture上验证
A/B/C＋D1–D3证据 → D4 整版原生/语义签收与产物冻结 → 用户批准生产迁移点
```

A3/A4 在隔离数据上实现与验证，不立即改生产；客户端更新清单在生产迁移前签收。C2 先用小 fixture 验接口，再按批准的下载预算做真实模型验证。若 b12361 不支持目标，停该型号晋级，交升级报告，不私换引擎。

## 3. 测试与执行共同约定

执行前核实 `.venv/bin/python`、pytest、CLT/SDK、固定引擎和空闲8998端口；依赖缺失先报告，不自动安装。未来 Python 单测命令统一从仓库根运行：

```bash
PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests/unit/<file>.py -v
```

每个任务先写指定断言，运行同一命令观察正确 RED，再最小实现，再同命令 GREEN；任务结束运行 `PYTHONPATH="$PWD/macfabric_gateway" .venv/bin/python -m pytest macfabric_gateway/tests`。环境错误不算 RED；失败/告警必须原样记录；不得通过管道末端的成功掩盖失败退出码。

Swift 新增无 UI 依赖资料/状态/示例测试，用 CLT `swiftc` 直编断言程序，不假设已有 XCTest/Xcode；原生视觉另用 AppKit/AX 和人工检查。权限不可用时记阻塞，不用浏览器替代。

长链统一产出 `run_id`、阶段、heartbeat、终态 JSON 和进程退出码；监视器同时覆盖 succeeded/failed/cancelled/timeout/意外进程退出。超过180秒无 heartbeat 报停工（实际模型加载超时另以明示配置控制）；单次完成用后台退出通知，不无界轮询。临时证据写 `$CLAUDE_JOB_DIR/tmp` 独立子目录，用户需保留的脱敏报告归档 `docs/qa/product-v2/`。

## 4. 验收追踪

| 特性 | 任务 | 必须证据 |
|---|---|---|
| F1 统一资料 | A2、B1/B3/B4 | schema roundtrip、全页同名、同名变体操作 |
| F2 硬切 | A3/A4、D3 | 引用/权限不扩大、旧缓存404、崩溃恢复、成对回滚 |
| F3 全页面 UI | B1/B3/B4、D2 | 三样稿批准；原生多窗/主题/AX截图矩阵 |
| F4 鉴权 | B2/B4、D2 | enabled/unknown/stale、合法与拒绝链、Keychain隔离 |
| F5 四类12型号 | C2/C4 | 每型产物/许可/摘要/峰值/语义绑定证据，不凑数 |
| F6 扩展统一 | A1、C1/C3 | SSRF/限额/预检/恢复/热加载/引用卸载 |
| F7 安全与交付 | A1、D1–D4 | 生产零穿透、loopback/沙箱实测、双端manifest |
| 后续能力 | C4 报告 | OCR/ASR/TTS/aigc 分型再审，不启动新底座 |

## 5. 当前完成定义与自审

本轮完成仅指：裁决已入 spec、全页规范已写、PLAN 已同步、以下子计划接口与验收步骤可追踪。所有实现 checkbox 保持未勾选。

自审：F1–F7 均有任务；身份 resolver、scope、缓存和生命周期界线一致；权限/断电/同名/失联/共享资产五类输入已归属测试；新增运行时仍有独立批准门；全量单测、原生与语义验证不相互替代。源文件行号随实施变化，以列出的符号定位，不据旧行号机械修改。

本计划不包含自动 commit、对外发布、实际生产迁移或模型下载。执行方式未在本轮选择，先审核计划；建议分阶段执行并在硬切/原生验收处独立复核，不一次性跑完整生产长链。
