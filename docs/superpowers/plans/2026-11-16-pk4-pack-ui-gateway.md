# PK4 能力包页 + 卸载生产接线 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** App 能力包页由真 Catalog 驱动（移除违反 Catalog-only 的静态 URL 流），网关卸载状态机接入生产回调，4B/8GB 策略进设置页，真包端到端验收。

**Architecture:** 网关侧一小步（装配适配器 + 请求路径 503 挂载，复用已测 uninstaller）；App 侧 GatewayStore 增 pack API 方法 + PacksView 重写（复用 Card/Chip/SmallBtn/confirmationDialog 既有模式与 3s 轮询）。

**Tech Stack:** Python http.server 网关（pytest）；SwiftUI 单文件 App（swiftc build.sh，无 XCTest）。

**Spec:** docs/superpowers/specs/2026-11-16-pk4-pack-ui-design.md（七项裁决）

## Global Constraints

- Catalog-only：App 只提交 pack_id，不携带任何 URL/hash（spec §6.1）
- 无 PGID 绝不盲杀；生产接线 pgid_fn=None（drain-only）
- 测试命令：`env PYTHONPATH=macfabric_gateway:macfabric_gateway/tests/unit timeout 500 .venv/bin/python -m pytest macfabric_gateway/tests/unit -q`（当前 234/234 绿）
- App 构建门禁：`bash macfabric-app/build.sh` 退出 0
- 侧栏术语不动；LocalDiscoverCard（用户导入流）不动
- commit 尾行 `Co-Authored-By: Claude Code <noreply@anthropic.com>`

## Review Focus

1. 卸载在途的并发请求：503 判定必须在路由禁用后、删除前生效 — T1 的测试须模拟"卸载线程持锁中"窗口。
2. status 轮询与安装线程竞态：App 3s 轮询读 status_payload 时 in_progress 合并不得抖动（后端已测，App 侧验证轮询渲染不崩）。
3. policy 输入非法值：App 侧非数字/越界 → 依赖后端 400 回显，UI 显示错误不静默。
4. 真包下载被网络阻断（huggingface.co 直连 reset）：安装失败路径必须在 UI 显示阶段化错误并可重试，不得卡死轮询。
5. 卸载 409 受影响池列表：确认框必须原样展示池名，不允许空列表静默通过。

---

### Task 1: 网关卸载生产接线 + 请求路径 503

**Files:**
- Modify: `macfabric_gateway/inferfabric/packs/uninstaller.py`（is_alive_fn 契约）
- Modify: `macfabric_gateway/inferfabric/packs/uninstaller.py` 测试同步：`macfabric_gateway/tests/unit/test_packs_uninstall.py`、`macfabric_gateway/tests/unit/test_packs_e2e_fake.py`
- Modify: `macfabric_gateway/inferfabric/proxy/pack_handlers.py`（新增 `attach_pack_uninstaller(pm)`）
- Modify: `macfabric_gateway/inferfabric/proxy/chat_handlers.py:209` 附近（handle_chat 模型解析后）
- Modify: `macfabric_gateway/inferfabric/proxy/handler.py`（/v1/messages 本地模型路径 + main 启动装配）
- Test: `macfabric_gateway/tests/unit/test_packs_wiring.py`（NEW）

**Interfaces:**
- Consumes: `PackManager.attach_uninstaller(registry, disable_route_fn, stop_pack_fn, is_alive_fn, pgid_fn=None, reload_fn=None)`；`is_model_disabled(model_name)`；`pm.mgr.status()["active_services"]`；`pm.mgr.stop_independent(name)` / `stop_service(name)`；`pm.mgr.reload_models()`
- Produces: `attach_pack_uninstaller(pm) -> None`（main() 调用）；`pm.pack_manager` 属性（chat/messages 503 检查用）；`is_alive_fn(model_names: set[str]) -> bool` 新契约

- [ ] **Step 1: RED** — 新建 `test_packs_wiring.py`：fake pm（mgr.stop_independent/stop_service/status/reload_models 记录调用；pool_registry=FakeRegistry）→ `attach_pack_uninstaller(fake_pm)` 后断言 `fake_pm.pack_manager` 已挂、uninstaller 已装配；`uninstall(pack_id, confirmed=True)` 全流程回调命中（stop_independent 被调、reload_models 被调、registry purge）。is_alive_fn 契约：先改 `test_packs_uninstall.py` 的 env（`is_alive_fn=lambda names: ...`）与 e2e 的 `is_alive_fn=lambda names: False`，watch FAIL。
- [ ] **Step 2: GREEN** — uninstaller `uninstall()` 内 `alive_fn(model_names)`；`attach_pack_uninstaller(pm)` 按上方接口实现（is_alive: `set(names) & set(status().get("active_services", []))`，异常吞掉返回 False）。
- [ ] **Step 3: RED** — 503：测试 `chat_handlers.handle_chat` + handler messages 路径：fake pm.pack_manager.is_model_disabled("m") = True → POST /v1/chat/completions {"model":"m"} → 503 `pack_uninstalling`；False → 不拦截。
- [ ] **Step 4: GREEN** — chat_handlers.handle_chat 在 model 提取后、池/本地分发前检查；handler messages 路径同样检查；`main()` 内构建 pm 后调 `attach_pack_uninstaller(pm)`。
- [ ] **Step 5: 全套绿 + Commit** — `feat(packs): 卸载生产接线 attach_pack_uninstaller + 请求路径 503 — PK4 T1`

### Task 2: App 能力包页 Catalog 驱动重写

**Files:**
- Modify: `macfabric-app/Sources/MacFabricApp.swift`（GatewayStore 增方法；PacksView/PackCard 重写；删 packPresets/静态 packs 表）
- Verify: `bash macfabric-app/build.sh`

**Interfaces:**
- Consumes: GET /admin/packs/catalog|status|policy、POST /admin/packs/install {pack_id}、GET /admin/packs/uninstall-preview?pack_id=、POST /admin/packs/uninstall {pack_id, confirmed}
- Produces: GatewayStore 方法 `fetchPackCatalog/fetchPackStatus/startPackInstall/previewPackUninstall/uninstallPackConfirmed/fetchPackPolicy`；PacksView 卡片状态机（未安装/进行中[阶段文案]/已安装/失败[重试]/待接入[模板未实现置灰]）

- [ ] **Step 1: GatewayStore 增 pack 数据**（@Published packCatalog/packStatus/packPolicy；stage→中文映射：preflight=预检中 staging=准备中 downloading=下载中 verifying=校验中 preparing_runtime=准备运行时 writing_config=写入配置 isolated_healthcheck=健康检查中 gateway_reload=重载中 installed=已安装 failed=失败）；轮询并入现有 3s timer（仅当 tab==5 拉取，降开销）。
- [ ] **Step 2: PacksView 重写** — 卡片数据 = catalog packs；卡上：display_name/summary/disk_mb→GB/risk_level Chip；按状态渲染（见 Produces）；安装按钮 → startPackInstall(pack_id)；失败显示阶段化 error + 重试；`runtime_template` 不在 `{llama-cpp-macos-arm64-v1}` → "待接入" 置灰（禁用安装）。
- [ ] **Step 3: 卸载流** — 卸载按钮 → previewPackUninstall → store.confirmText/confirmAction confirmationDialog（列 affected_pools 池名；空列表也要走确认框，Review Focus 5）→ uninstallPackConfirmed(confirmed:true)；409 时把 affected_pools 弹回确认框。
- [ ] **Step 4: 移除旧流** — 删 PackCard.packPresets 与静态 packs 元组表、uninstallConfirm 旧两击逻辑；LocalDiscoverCard 原样保留。
- [ ] **Step 5: 构建门禁 + Commit** — `bash macfabric-app/build.sh` 退出 0 → `feat(app): 能力包页 Catalog 驱动重写 — PK4 T2`

### Task 3: 设置页能力包策略区

**Files:**
- Modify: `macfabric-app/Sources/MacFabricApp.swift`（SettingsView 增区块）
- Verify: `bash macfabric-app/build.sh`

- [ ] **Step 1: 设置页"能力包策略"Card** — 两个输入（max_model_parameters_b ≥1、system_reserved_memory_mb [1024,65536] MiB）+ 说明"仅影响后续安装，不自动重装"；保存 → PUT /admin/packs/policy → 400 时 FeedbackBanner 显示后端 error 原文（Review Focus 3），200 回显新值。
- [ ] **Step 2: 构建 + Commit** — `feat(app): 设置页能力包策略区 — PK4 T3`

### Task 4: 真包端到端验收 + 生产合入 + QA 记录

**Files:**
- Create: `docs/qa/packs-ui.md`（GUI 冒烟清单 + 真包验收证据）

- [ ] **Step 1: 网关生产合入** — 全套 pytest 绿 → `launchctl kickstart -k gui/501/com.macfabric.gateway` → 验证 uninstall-preview 对真实 catalog pack 返回 200（不再 404，F5 闭合证据）。
- [ ] **Step 2: GUI 冒烟**（用户可见状态记录进 docs/qa/packs-ui.md）— 能力包页 5 卡渲染；安装 Qwen3-4B：阶段文案流转；失败/成功两分支 UI 表现。
- [ ] **Step 3: 真包验收** — 真装 Qwen3-4B（~3.2GB 下载；网络被阻断则记录失败路径证据并注明 spec §14 已知风险）→ chat 冒烟（pack 模型名）→ 卸载（确认框列池）→ 零残留断言（目录/YAML/store）。
- [ ] **Step 4: Commit + 收尾** — `docs: PK4 验收记录`；SDD 台账 Rulings/Deferred 汇总进最终报告。
