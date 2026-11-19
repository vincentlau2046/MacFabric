# M2 Dashboard 对齐实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App 功能在 Dashboard 有等价操作路径（§6.3 五项）：packs 页、security 页、deploy autostart 开关、cloud 属性浮窗、overview 内存账本卡。

**Architecture:** 沿用上游 fragments/js 模式（无构建链）：fragment 只放容器卡、JS IIFE 注入 DOM、事件委托、`UI.adminHeaders()` 鉴权、`window.tabRenderers` 注册。新页只进新文件（上游摘取零冲突）；`base.html`/`dashboard/__init__.py` 仅注入点级注册改动；overview 账本走真账本快照（manager 只读方法 + `/api/snapshot` 扩字段，用户裁决 2026-11-19）。

**Tech Stack:** 原生 JS（ES5 风格 IIFE）+ 既有 style.css 通用类；Python 侧 pytest（source-contract 模式 + 账本快照单测）。

**Spec:** docs/superpowers/specs/2026-11-18-python-gateway-refocus-design.md §6.3/§9/§10；差距盘点（2026-11-19 Explore 报告，五项端点/文件级证据）。

## Global Constraints

- M2 不新增后端端点（裁决 6）；overview 账本=扩既有 `/api/snapshot` payload（用户裁决 2026-11-19），非新端点。
- 面向上游化：文案跟上游既有风格（中文注释/标签，上游即中文）；新功能进新文件；触碰上游文件限注入点级并在 manifest 标注。
- 前端无构建链：ES5 兼容 IIFE、`'use strict'`、字符串拼接 + `escHtml`、事件委托（无 inline onclick）。
- 鉴权：packs/security 全部写操作经 `UI.adminHeaders()`（`X-Admin-Token`）；一次性回显（security key、明文）只展示一次，UI 提示"立即复制保存"。
- None 语义：账本/遥测数据缺失显示 `—`，绝不显示 0 或伪造百分比（DeviceTelemetry 契约延续）。
- 测试：每任务先写失败测试（source-contract 或单测），RED→GREEN；沙箱验证 `MACFABRIC_STATE_DIR=<tmp> EDGE_PROXY_PORT=8998`；全量回归 `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/ -q`。
- 回归基线：当前 main `3f3f392`，431 tests 绿。

## Review Focus

1. **账本快照语义漂移**：snapshot 的 committed 必须 = `resident_total_mb()` 同一算法（SLEEPING=baseline//4、STOPPED 不计）；快照重建若与 `_admit_memory`（manager.py:307-336）的注册口径不一致（如把非 active 模型记为 READY），UI 数字会与准入行为矛盾——Task 5 测试必须钉住两者共用同一构造路径。
2. **`dashboard/__init__.py` 硬编码清单漏改**：JS_MODULES 与 fragment 元组任一漏加 → 占位符静默残留或 JS 不加载（graceful degradation 会掩盖错误）——每新页任务的合同测试须断言两清单含新名。
3. **admin token 缺失时的失败形态**：严格模式下 packs/security 写操作无 token → 401，页面须 toast 明确"需要 admin token"，不得静默空转。
4. **一次性回显的复制安全**：security key 明文若被 innerHTML 注入后可再次读取（DOM 残留），关闭浮层须清空节点。
5. **autostart 开关竞态**：snapshot 3s 轮询回填会覆盖用户刚点的开关状态——乐观更新后须以本地 pending 状态压制下一次轮询回填（或以响应值为准 + 失败回滚）。

---

### Task 1: packs 页（能力包生命周期）

**Files:**
- Create: `macfabric_gateway/inferfabric/dashboard/fragments/packs.html`
- Create: `macfabric_gateway/inferfabric/dashboard/js/packs.js`
- Modify: `macfabric_gateway/inferfabric/dashboard/base.html`（nav 按钮 + `<!-- FRAGMENT:packs -->` + `<!-- JS:packs -->` 占位）
- Modify: `macfabric_gateway/inferfabric/dashboard/__init__.py`（`JS_MODULES` + fragment 元组各加 `"packs"`）
- Modify: `macfabric_gateway/inferfabric/dashboard/fragments/style.css`（进度条/包卡类，仅当通用类不够）
- Test: `macfabric_gateway/tests/unit/test_dashboard_packs_page.py`

**Interfaces:**
- Consumes: `GET /admin/packs/catalog`、`GET /admin/packs/status`（进行中条目含 stage 实时覆盖）、`POST /admin/packs/install {pack_id}`（202/409/404）、`POST /admin/packs/custom {name,url,capability,sha256?}`、`GET /admin/packs/uninstall-preview?pack_id=`、`POST /admin/packs/uninstall {pack_id,confirmed}`、`GET|POST /admin/packs/policy`（形状见 pack_handlers.py:184-564）。
- Produces: `window.tabRenderers['tab-packs']`；nav 第 8 项"能力包"。

- [ ] **Step 1: 失败测试** `test_dashboard_packs_page.py`：① `get_html()` 产物含 `tab-packs` 容器、nav 项、`packs.js` 内联（断言 `"packs" in dashboard.JS_MODULES` 且 fragment 元组含 packs，占位符 `FRAGMENT:packs`/`JS:packs` 不残留）；② packs.js 源含 `admin/packs/catalog`、`admin/packs/status`、`admin/packs/install`、`admin/packs/uninstall`、`admin/packs/policy`、`UI.adminHeaders`、`tabRenderers['tab-packs']`、`UI.confirm`（卸载双段确认）、stage→中文标签映射含全部 6 态（preflight/downloading/verifying/isolated_healthcheck/writing_config/installed/failed）；③ 无 inline `onclick=`。
- [ ] **Step 2: 跑测试确认 RED**（新页不存在 → ①②失败）。
- [ ] **Step 3: 实现**：fragment 容器卡（catalog 表 + status 进度区 + policy 卡 + 自定义包表单）；packs.js 轮询 status（仅 tab 激活时，2s）+ catalog 惰性加载；install/uninstall/custom 走 confirm→POST→toast；进度条用 stage 百分比映射（CSS 宽度）。
- [ ] **Step 4: 测试 GREEN + 全量回归**。
- [ ] **Step 5: 沙箱验收**（:8998）：catalog 200、policy GET/POST 往返、install 未知包 404 形态、Dashboard 页面 HTML 含 tab-packs。
- [ ] **Step 6: Commit** `feat(dashboard): packs page — catalog/install/uninstall/policy UI`。

### Task 2: security 页（安全密钥设置）

**Files:**
- Create: `macfabric_gateway/inferfabric/dashboard/fragments/security.html`
- Create: `macfabric_gateway/inferfabric/dashboard/js/security.js`
- Modify: `base.html`、`dashboard/__init__.py`（同 Task 1 注册模式）
- Test: `macfabric_gateway/tests/unit/test_dashboard_security_page.py`

**Interfaces:**
- Consumes: `GET|POST /admin/security/status`（`{active,policy,enforced,key_count,keys[]}`）、`POST /admin/security/enable {enforce,key_name?}`（首次启用明文 key 仅本次响应）、`POST /admin/security/keys {name?}`（同上）、`POST /admin/security/keys/revoke {id}`。
- Produces: `window.tabRenderers['tab-security']`；nav 第 9 项"安全"。

- [ ] **Step 1: 失败测试**：① 注册断言（同 Task 1 模式）；② security.js 源含四端点路径、`UI.adminHeaders`、enable 前有 `UI.confirm`（enforce=true 影响所有客户端）；③ 一次性回显契约：key 展示节点渲染后源码含"仅本次/复制"提示且有关闭清空逻辑（断言 `textContent=''` 或节点移除调用存在）；④ 无 inline onclick。
- [ ] **Step 2: RED。**
- [ ] **Step 3: 实现**：状态卡（active/policy/key_count + 密钥表格 id/name/created_at/revoked + 吊销按钮）、启用/停用卡（enforce 开关 + key_name 输入）、明文 key 模态（复制按钮 + 关闭清空）。
- [ ] **Step 4: GREEN + 全量回归。**
- [ ] **Step 5: 沙箱验收**：status 200；enable（enforce=false）往返；revoke 未知 id 404 形态。
- [ ] **Step 6: Commit** `feat(dashboard): security page — key lifecycle + one-time reveal UI`。

### Task 3: deploy 页 autostart 开关

**Files:**
- Modify: `macfabric_gateway/inferfabric/dashboard/js/deploy.js`、`fragments/deploy.html`、`fragments/style.css`（开关样式，如无通用类）
- Test: `macfabric_gateway/tests/unit/test_dashboard_deploy_autostart.py`

**Interfaces:**
- Consumes: snapshot `models[]`（`{name, autostart, ...}`，manager.py:249）；`POST /admin/models/set-autostart {name, enabled}`（`{status:"ok",model,autostart}` / 404 / 500）。
- Produces: deploy 页模型自启列表/开关列；`window.tabRenderers['tab-deploy']` 内新增渲染段。

- [ ] **Step 1: 失败测试**：① deploy.js 源含 `set-autostart`、`autostart` 状态回填（从 snapshot models[].autostart）、pending 压制逻辑（Review Focus 5：断言存在 pending-set 结构或在响应确认前不回填的分支）；② `UI.adminHeaders` 用于 POST；③ fragments/deploy.html 有承载容器。
- [ ] **Step 2: RED。**
- [ ] **Step 3: 实现**：deploy 页新增"自启动"卡：模型行 + 开关；点击→乐观置 pending→POST→成功以响应值落定/失败回滚+toast；轮询回填跳过 pending 项。
- [ ] **Step 4: GREEN + 全量回归。**
- [ ] **Step 5: 沙箱验收**：set-autostart 对真实/临时模型往返（enabled true→false），404 形态。
- [ ] **Step 6: Commit** `feat(dashboard): autostart toggles on deploy page`。

### Task 4: cloud 页属性浮窗

**Files:**
- Modify: `macfabric_gateway/inferfabric/dashboard/js/cloud.js`（浮窗 UI + tag-with-attrs 提交）、`fragments/style.css`（浮窗类）
- Test: `macfabric_gateway/tests/unit/test_dashboard_cloud_attrs.py`

**Interfaces:**
- Consumes: providers GET 回填的 `model_specs[{id,supports_vision,supports_tools,context_window,max_output_tokens,price_input,price_output,...}]`（handler.py:2929-2942）；`POST /admin/cloud/provider-models {provider, action:"tag", model, supports_vision?, supports_tools?, context_window?, max_output_tokens?, price_input?, price_output?}`。
- Produces: 策展面板行内"属性"按钮 → 浮窗（六字段表单，回填现值）→ 保存发 tag action。

- [ ] **Step 1: 失败测试**：① cloud.js 源含 `context_window`、`price_input`、`max_output_tokens`、`supports_vision`、`supports_tools`（现状零命中 → RED）；② tag 提交体含 `action:"tag"` 与六键；③ 浮窗复用 `UI.confirm`/模态既有模式或自绘（断言关闭清空）。
- [ ] **Step 2: RED。**
- [ ] **Step 3: 实现**：策展面板每个已启用模型行加"属性"入口；浮窗六字段（vision/tools checkbox，四个数值 number 输入，空=不修改）；保存 → tag → 刷新该 provider 面板。
- [ ] **Step 4: GREEN + 全量回归。**
- [ ] **Step 5: 沙箱验收**：对临时 provider 配置 tag 一个 context_window 值 → GET 回读一致。
- [ ] **Step 6: Commit** `feat(dashboard): model attribute editor popover on cloud curation panel`。

### Task 5: overview 内存账本卡（真账本快照）

**Files:**
- Modify: `macfabric_gateway/inferfabric/manager.py`（新增只读快照方法）
- Modify: `macfabric_gateway/inferfabric/proxy/handler.py`（snapshot payload 加 `memory_ledger` 字段，注入点级）
- Modify: `macfabric_gateway/inferfabric/dashboard/js/store.js`（归一化）、`js/overview.js`（账本卡）、`fragments/overview.html`、`fragments/style.css`
- Test: `macfabric_gateway/tests/unit/test_memory_ledger_snapshot.py`

**Interfaces:**
- Produces: `ModelManager.memory_ledger_snapshot() -> dict | None`，返回 `{"available": True, "budget_mb": int|None, "committed_mb": int, "entries": [{"name","mem_baseline_mb","mode","state"}], "pressure_level": int|None, "eviction_plan": [str]}`；非 macOS 或探测不可用 → `None`（前端显示 `—`/空态，绝不伪造 0 预算——观测语义走 `probe.budget_given_total`，准入语义的 0 兜底不外泄）。
- Consumes: 与 `_admit_memory`（manager.py:307-336）同一构造路径（`UnifiedMemoryLedger` + `mac_platform.budget_mb()`/`mem_used_mb()`）；`pressure_level` 取自 device telemetry 快照（与 `/api/snapshot` device 信封同一读数——one probe one timestamp 契约）。
- snapshot 字段：`content["memory_ledger"] = getattr(pm.mgr, "memory_ledger_snapshot", lambda: None)()`（getattr 守卫，旧测试桩不受影响）。

- [ ] **Step 1: 失败测试** `test_memory_ledger_snapshot.py`：① macOS 桩下 `memory_ledger_snapshot()` 返回 dict：committed = active 模型 baseline 之和（READY 全额）、SLEEPING 记 baseline//4（register 后手动改 state 验证）、非 active 模型不出现在 entries；② `budget_mb` 缺失（mem_total None）→ None 而非 0；③ 非 macOS（IS_MACOS=False 桩）→ None；④ pressure_level 透传 device telemetry 读数，eviction_plan = `pressure_eviction_plan(level)`（level=2 → 空表，level=3 → on_demand 优先序列）；⑤ handler 合同：`/api/snapshot` payload 含 `memory_ledger` 键且 None 安全（沿用 test_device_api_contract 的 `_Shell` 模式）。
- [ ] **Step 2: RED。**
- [ ] **Step 3: 实现**：manager 快照方法（复用 _admit_memory 的 ledger 构造，抽取共享私有构造函数 `_build_memory_ledger()` 供两处调用，防口径漂移——Review Focus 1）；handler 注入一行；store 归一化 + overview 账本卡（预算条 committed/B、逐模型 resident 行、压力灯 <3 绿/3 橙/>3 红 + eviction_plan 提示行）。
- [ ] **Step 4: GREEN + 全量回归（重点：既有 manager/handler 测试无回归）。**
- [ ] **Step 5: 沙箱验收**：:8998 `/api/snapshot` 含 memory_ledger；macOS 真机 committed>0、budget=B；Dashboard overview 渲染账本卡。
- [ ] **Step 6: Commit** `feat(dashboard): memory ledger card on overview — true committed/B + pressure`。

---

## 验收（M2 完成定义）

§6.3 映射表逐条：packs 下载/装机/卸载/进度有操作路径；security enable/一次性回显可走通；switch/stop/autostart 在 deploy 页齐备；云策展含属性编辑；overview 有账本+压力灯。每项沙箱 HTTP 证据入 docs/qa；全量回归绿；生产发布随下一 tag（release-install 流程）。

## 明确不在本计划内

- Connect 页（M3）；账号池占位（M3）；legacy whisper 裸下载通道 UI；security `/admin/keys` Cookie 会话体系 UI（复用既有 keys 页入口即可）；后端新端点。
