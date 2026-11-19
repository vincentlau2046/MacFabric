# M2 Dashboard 对齐实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan inline once approved. Steps use checkbox (`- [ ]`) syntax for tracking.

**状态：评审修订稿，待用户复核；未授权开始实施。**

**Goal:** 在 Dashboard 承接 App 的五项操作或观测能力。顺序不变：T1 packs → T2 security → T3 deploy autostart → T4 cloud 属性浮窗 → T5 overview 账本。

**Architecture:** 保留上游 fragments/JS 模式、现有 store 和管理态请求方式；新增页面只在 `base.html` 与 `dashboard/__init__.py` 注册，现有页做局部增量。后端不新增路由：T2 只给既有明文响应加防缓存头，T5 只给既有 `/api/snapshot` 加只读账本投影。

**Tech Stack:** 原生 JS/HTML/CSS、pytest、Playwright 浏览器行为验收（不引入前端构建链或生产依赖）。

**Spec:** `docs/superpowers/specs/2026-11-18-python-gateway-refocus-design.md` §6.3、§9、§10、§12；本稿落实 M2 方案评审意见。实际接口以当前 fork 代码为准；历史计划基线为 `06d4a26`，以实施前的实测结果为回归基线。

## Global Constraints

- 不新增 HTTP 路由，不改鉴权策略、模型准入策略或压力处置逻辑。账本是真实的**准入账面占用**，不是设备实测用量。未知值显示 `—`，不伪造 0；真实 0 原样显示。
- 沿用同源请求、`UI.adminHeaders()`、既有组件与页面风格；新增事件用监听器或委托，动态内容按不可信数据处理。严格模式下管理接口的 GET 和写请求均可返回 401，提示查看顶栏 admin token，禁止自动重试写请求。
- 实施获准后在独立功能分支 `feat/m2-dashboard` 上按顺序执行；阶段提交只包含对应任务的文件。任何推送、合入主线、打 tag、部署生产均不由计划复核自动授权。
- 本文的产品路径均相对 `macfabric_gateway/`，计划、QA 和 manifest 路径相对仓库根。

## Review Focus

1. **T1 误导或误删**：真实阶段完整覆盖；预览失败或用户取消时零写入；确认明确说明最终候选引用以服务端执行时为准。
2. **T2 登录态与明文**：策略 off 不等于旧鉴权 off；全吊销不等于首次启用；切页后迟到的明文响应不能重新弹出；两条可能返回明文的响应均 `no-store`。
3. **T3 旧轮询回写**：提交前发出的轮询就算最后到达，也不能在保存成功后覆盖已确认的值。
4. **T4 未编辑字段**：空表单、显式清空、价格 0 和能力解除打标是不同操作；保留原有的显式 `false`，不被打开再保存抹掉。
5. **T5 账本口径漂移**：活跃成员与基线计算同准入；设备预算和压力来自 handler 已有快照；不把推算的卸载顺序显示成实际动作。

## 前置检查与共用验证约定

- [ ] **核实基线。** 确认分支、工作树与 Python 环境；检查 :8998 是否空闲，确认可用的浏览器验收工具与临时数据路径；不占用现有服务端口，不停止无关进程。
- [ ] **跑全量基线。** 从仓库根执行 `cd macfabric_gateway && ../.venv/bin/python -m pytest tests/ -q`，记录命令、提交、退出码、用例数和已知失败。后续每任务用同一命令回归；历史绿灯不能代替本次基线。
- [ ] **准备隔离验收。** 每次沙箱使用独立私有临时根，设置 `MACFABRIC_STATE_DIR=<tmp>/state`、`MACFABRIC_MODELS_DIR=<tmp>/models.d`、`EDGE_PROXY_HOST=127.0.0.1`、`EDGE_PROXY_PORT=8998`；`IFF_DATA_DIR` 已由 `config.py` 从 `MACFABRIC_STATE_DIR` 派生。启动前核验实际配置路径、监听、包目录及测试模型/缓存是否在隔离边界；清掉继承的生产凭据，不复制生产 DB 或 YAML，不启动真实生产模型或执行宿主清理。真实安装集成测试使用本机小包与桩引擎；不能确保隔离则停在可控桩测试，不把未跑路径记为通过。

**验证方式：** 每个任务先写回归断言并看到预期 RED，再实现、定向 GREEN、全量回归。页面组装用 `get_html()` 合同测试；交互用真实浏览器加载沙箱 Dashboard 并操作 DOM，必要时用 Playwright 路由拦截精确控制延迟、状态码和数据。拦截用例验证 UI，不能代替真实 HTTP 合同验收。实施时在 `docs/qa/2026-11-19-m2-dashboard.md` 保存复跑步骤、请求/界面断言、结果及未覆盖项；不保留任何明文 key、admin token 或含秘密的 trace。长链验收以实际 pytest 摘要、浏览器断言结果和 QA 记录为终态，并设置失败、超时或进程退出提醒。

---

### Task 1: packs 页（能力包生命周期）

**Files:** 新增 `inferfabric/dashboard/fragments/packs.html`、`inferfabric/dashboard/js/packs.js`；修改 `inferfabric/dashboard/base.html`、`inferfabric/dashboard/__init__.py`，必要时改 `inferfabric/dashboard/fragments/style.css`；测试 `tests/unit/test_dashboard_packs_page.py`。

**Interfaces:** `GET /admin/packs/catalog`、`GET /admin/packs/status`、`POST /admin/packs/install {pack_id}`、`POST /admin/packs/custom {name,url,capability,sha256?}`、`GET /admin/packs/uninstall-preview?pack_id=…` 返回 `{affected_pools:[{pool,candidate_id,model_name}]}`、`POST /admin/packs/uninstall {pack_id,confirmed}`、`GET|POST /admin/packs/policy`（`max_model_parameters_b`、`system_reserved_memory_mb`）。新页为 `tab-packs`，注册 `window.tabRenderers['tab-packs']`。

- [ ] **写回归用例。** `test_packs_page_is_assembled`：nav、真实容器和脚本均在 `get_html()` 产物中，且没有残留占位或加载失败替身。浏览器用例：严格模式管理 GET/POST 401 有提示；卸载预览失败或用户取消时没有 POST；确认时仅发送一次带 `confirmed:true` 的 POST，并正确处理错误响应。
- [ ] **验 RED。** 运行 `../.venv/bin/python -m pytest tests/unit/test_dashboard_packs_page.py -q`；确认页面组装/入口断言因功能缺失而失败。
- [ ] **实现页面。** 展示 catalog、装机/自定义安装、状态、policy 和卸载；status 只在 tab 激活时每 2 秒刷新，不叠加请求。按服务端真实阶段显示 `preflight`、`staging`、`downloading`、`verifying`、`preparing_runtime`、`writing_config`、`isolated_healthcheck`、`gateway_reload`、`installed`、`failed`；未知阶段中性回退。不显示下载百分比或字节数。卸载先 GET 预览，再显式确认，列出当前候选并告知执行时以服务器重新计算的引用为准；预览失败不提交，提交期间防双击，不自动重试。
- [ ] **验定向 GREEN。** 重跑本任务 pytest，预期退出 0。
- [ ] **验沙箱行为。** 浏览器跑预览失败／取消／确认、401 恢复、安装阶段与失败态；对隔离包验安装之后状态变化、卸载与列表回读，policy 做 GET→POST→GET 回读，确认所有写操作只影响临时目录。
- [ ] **验全量回归。** 跑共用 pytest 命令，预期无新增失败。
- [ ] **做本地阶段提交。** `feat(dashboard): add packs lifecycle page`。

### Task 2: security 页（状态、密钥、一次性回显）

**Files:** 新增 `inferfabric/dashboard/fragments/security.html`、`inferfabric/dashboard/js/security.js`；修改 `inferfabric/dashboard/base.html`、`inferfabric/dashboard/__init__.py`、`inferfabric/proxy/handler.py`（仅响应头）；测试 `tests/unit/test_dashboard_security_page.py`、`tests/unit/test_dashboard_security_responses.py`。

**Interfaces:** `GET /admin/security/status` → `{active,policy,enforced,key_count,keys:[{id,name,created_at,revoked}]}`；`POST /admin/security/enable {enforce,key_name?}`、`POST /admin/security/keys {name?}` 可能返回 `key`，这两条路由的成功响应使用 `Cache-Control: no-store`；`POST /admin/security/keys/revoke {id}`。新页为 `tab-security`，注册 `window.tabRenderers['tab-security']`。`active` 表示密钥存储可用，`policy` 表示新策略，`enforced` 表示实际鉴权状态；`key_count` 仅表示未吊销记录数，不承诺密钥一定有效。

- [ ] **写回归用例。** `test_security_page_is_assembled`；`test_security_secret_responses_are_no_store`（隔离临时密钥库，分别断言首次启用与主动创建的响应头，状态/列表不含明文）。浏览器用例：首次启用后只回显一次；关闭、Esc、切页、迟到响应均不留明文在 DOM；`policy=off` 与 `enforced=true` 同时存在时不显示“免鉴权”；全吊销时引导创建替换 key；最后一把未吊销 key 的吊销有警告；严格模式 401 有提示。
- [ ] **验 RED。** 运行 `../.venv/bin/python -m pytest tests/unit/test_dashboard_security_page.py tests/unit/test_dashboard_security_responses.py -q`；预期失败在新增页面与 `no-store` 断言。
- [ ] **实现页面与响应头。** 策略变更后重读 status，不凭 `/enable` 的返回值推断实际是否鉴权。已初始化且未吊销数为零时，启用前引导先建新 key；从未初始化时走后端已有的首次发 key 流程。明文使用 `textContent` 临时显示，仅主动复制，不写浏览器存储、全局状态、toast、日志或 URL；所有离开路径清空并丢弃迟到的回显。只为两条既有成功响应加 `no-store`，不改后端策略。
- [ ] **验定向 GREEN。** 重跑本任务 pytest，预期退出 0。
- [ ] **验沙箱行为。** 全新临时库走浏览器首次开启→回显→关闭/切页→状态回读；验证临时推理请求未带 key 被拒，带新 key 通过鉴权；再覆盖创建、吊销及旧鉴权仍生效的分支。浏览器测试只记录非秘密断言。
- [ ] **验全量回归。** 跑共用 pytest 命令，预期无新增失败。
- [ ] **做本地阶段提交。** `feat(dashboard): add security settings and one-time key reveal`。

### Task 3: deploy 页 autostart

**Files:** 修改 `inferfabric/dashboard/js/deploy.js`、`inferfabric/dashboard/fragments/deploy.html`、`inferfabric/dashboard/js/store.js`（仅快照回写时序），必要时改 `inferfabric/dashboard/fragments/style.css`；测试 `tests/unit/test_dashboard_deploy_autostart.py`。

**Interfaces:** snapshot `models[].{name,autostart}`；`POST /admin/models/set-autostart {name,enabled:bool}` → `{status:"ok",model,autostart}`。按钮注明“下次网关启动生效”；即时 switch/stop 复用推理页操作，从部署页提供导航，不再造一套按钮。

- [ ] **写回归用例。** `test_deploy_autostart_is_assembled`。浏览器用例：初始关，先扣住一个返回旧值的快照；点开并让 POST 成功，先交付一个写后新快照（开），最后交付被扣的快照（关），界面和 store 不得反跳。再覆盖 POST 失败回滚、连点防重复、写成功但确认读暂时失败。
- [ ] **验 RED。** 运行 `../.venv/bin/python -m pytest tests/unit/test_dashboard_deploy_autostart.py -q`；预期失败在入口/承载容器。
- [ ] **实现开关与确认读。** 每模型单写在途，POST 失败回滚并显示错误；成功以响应值暂时展示，发起无条件写后快照。store 为快照打客户端请求序号，轮询与强刷都不得把低于最近已应用序号的响应写回状态或 ETag；开关在拿到不早于写后请求的已应用 HTTP 200 快照前不被轮询覆盖；304 不作确认。写后读失败显示“待回读确认”，允许再次读取，不宣称回滚或自动重试写入；受信的新快照不同则按服务端回读值显示并提示不一致。
- [ ] **验定向 GREEN。** 重跑本任务 pytest，预期退出 0。
- [ ] **验沙箱行为。** 浏览器执行乱序与失败案例；使用临时模型 YAML 实测 `false→true→false`，强刷及页面重载回读一致；点击导航到推理页能找到既有 switch/stop。测试配置不触发真实模型启动。
- [ ] **验全量回归。** 跑共用 pytest 命令，预期无新增失败。
- [ ] **做本地阶段提交。** `feat(dashboard): add deploy autostart controls`。

### Task 4: cloud 策展属性浮窗

**Files:** 修改 `inferfabric/dashboard/js/cloud.js`，必要时改 `inferfabric/dashboard/fragments/style.css`；测试 `tests/unit/test_dashboard_cloud_attrs.py`。

**Interfaces:** 从 `GET /admin/cloud/providers` 的 `model_specs` 回填 `supports_vision`、`supports_tools`、`context_window`、`max_output_tokens`、`price_input`、`price_output`；调用 `POST /admin/cloud/provider-models {provider,action:"tag",model,...changedFields}`。请求字段缺省＝保留；数值字段显式 `null`＝清除；能力 `false`＝解除打标，而不是保存“明确不支持”。

- [ ] **写回归用例。** `test_cloud_attributes_entry_is_assembled`。浏览器用例：打开后无改动保存不发 POST；只改价格时原有显式能力 `false` 和其他属性不动；价格 `0` 按数字提交，显式清空提交 `null`；取消不提交，错误后保留输入可更正。
- [ ] **验 RED。** 运行 `../.venv/bin/python -m pytest tests/unit/test_dashboard_cloud_attrs.py -q`；预期缺少属性编辑入口。
- [ ] **实现浮窗。** 保留现有策展行和协议 chip，给可路由条目加属性入口。以原始声明回填，只发送变更；数值区区分未设置、0、显式清除，token 数为整数、价格为有限数字；能力复用“打标／解除打标”语义，已有显式 `false` 不动即保留，UI 不新增写入显式排除的途径。保存成功回读该 provider；失败显示错误，不宣称保存成功。
- [ ] **验定向 GREEN。** 重跑本任务 pytest，预期退出 0。
- [ ] **验沙箱行为。** 用禁用外部发现的临时 provider 在浏览器走不改、编辑、显式清空，检查请求体及 GET/YAML 回读；不连接真实 provider。
- [ ] **验全量回归。** 跑共用 pytest 命令，预期无新增失败。
- [ ] **做本地阶段提交。** `feat(dashboard): add cloud model attribute editor`。

### Task 5: overview 真账本快照（只读）

**Files:** 修改 `inferfabric/manager.py`、`inferfabric/proxy/handler.py`、`inferfabric/dashboard/js/store.js`、`inferfabric/dashboard/js/overview.js`、`inferfabric/dashboard/fragments/overview.html`，必要时改 `inferfabric/dashboard/fragments/style.css`；测试 `tests/unit/test_memory_ledger_snapshot.py`，复用 `tests/unit/test_device_api_contract.py` 的 handler 测试夹具。

**Interfaces:** `ModelManager.memory_ledger_snapshot(device_snapshot: DeviceSnapshot | None) -> dict | None`。统一内存平台返回 `{"budget_mb": int|null, "committed_mb": int, "entries": [{"name": str, "mem_baseline_mb": int, "mode": str}], "pressure_level": int|null}`；其他平台或无可用的平台快照返回 `null`。预算和压力直接取 `/api/snapshot` 已取得的 `dev_snap.memory_budget_mb`、`dev_snap.pressure_level`；支持统一内存但采样字段缺失时保留该字段 `null`，不抹掉可计算的账面占用。`committed_mb` 是**活跃模型基线账面合计**，新目标准入时原样排除目标本身；此字段既不是进程实测内存，也不是下一模型的可准入额度。

- [ ] **写回归用例。** `test_memory_ledger_projection_uses_admission_baselines`：活跃模型全额记账，`mem_baseline_mb` 缺省回退 `peak_vram_mb`；不在活跃集合的模型不入账（含已退出进程的 llama.cpp sleep）；不因 sleep 标记打 25% 折扣，准入的目标排除、结果及探针策略不变。`test_snapshot_memory_ledger_reuses_device_sample`：handler 传同一个快照对象、不新增探针调用，独立覆盖空闲真实 0、未知预算/压力、非 unified、旧 handler 测试桩和新增字段的 ETag 变化。
- [ ] **验 RED。** 运行 `../.venv/bin/python -m pytest tests/unit/test_memory_ledger_snapshot.py tests/unit/test_device_api_contract.py -q`；账本投影/接线断言失败，现有遥测测试保持原行为。
- [ ] **实现投影。** 抽出两条路径共享的活跃模型登记逻辑；`_admit_memory` 继续使用原预算探测、目标排除和准入规则；观测路径不调用准入或额外探测。handler 将已获取的 `dev_snap` 显式传入，结果加 `memory_ledger`；store 做缺省兼容，overview 展示账面 `committed / B` 和压力 `1 正常 / 2 警告 / 3 严重 / null 未知`。预算未知或为零不计算百分比；超预算时不掩盖原值。不上报或展示推算的卸载顺序，不触发任何控制动作。
- [ ] **验定向 GREEN。** 重跑本任务 pytest，预期退出 0。
- [ ] **验沙箱行为。** macOS 空闲快照比对 `memory_ledger.budget_mb/pressure_level` 与同响应 `device.snapshot`，空闲 `committed=0` 可正常显示；用隔离运行状态夹具提供非零占用，不为验收重启或拉起宿主模型。浏览器检查压力 1/2/3/未知、预算未知/零和非 unified 空态。
- [ ] **验全量回归。** 跑共用 pytest 命令，预期无新增失败。
- [ ] **做本地阶段提交。** `feat(dashboard): show admission memory ledger in overview`。

---

## M2 完成定义与交付边界

- [ ] QA 逐项记录：能力包阶段、安装和预览卸载；鉴权状态、首次发 key、创建/吊销；部署页 autostart 及到推理页 switch/stop 的路径；云属性保留/修改/清除；overview 账本与压力。注明真实沙箱与浏览器拦截各自的证据，缺项不算通过。
- [ ] 全分支评审与最终回归通过后，记录本地交付候选并单独报批合入和发布；不把发布或真实 CUDA 验收算作本计划的既成结果。
- [ ] 更新 `docs/upstream/CHERRY-PICK-MANIFEST.md` 的 UI 条目，记录每项改动与后端依赖。packs 依赖 F4 能力包 API；security 对照 F7 核对上游实际缺的路由/字段；autostart、cloud 属性和 ledger 也各验上游接口后再切 pick，不承诺能直接摘取。不要把 M3 Connect 写成 M2 产物。

**明确不在本计划内：** Connect 与账号池（M3）、legacy whisper 裸下载 UI、Cookie 版 `/admin/keys` 重做、InferFabric #8 的通用 `iff remove` Dashboard 入口、以调整准入策略或自动处置来配合账本展示、未经另行授权的共享分支推送和生产发布。
