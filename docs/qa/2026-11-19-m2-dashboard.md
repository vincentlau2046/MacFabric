# M2 Dashboard 对齐 — QA 记录

日期：2026-11-19
计划：`docs/superpowers/plans/2026-11-19-m2-dashboard.md`（评审修订版，用户批准）

## 约定

- 单元/合同测试：`pytest tests -q`（每次任务收尾全量跑，435 passed 基线）。
- 真实 HTTP 验收：隔离沙箱网关（私有 mktemp 临时根，
  `MACFABRIC_STATE_DIR` + `MACFABRIC_MODELS_DIR` + `EDGE_PROXY_*` 指向本地），
  **不使用** `scripts/sandbox-gateway.sh`（其软链生产 packs/池/云配置，
  与本批破坏性操作验收互斥）。隔离核验：写入只落沙箱 state，生产
  `~/.inferfabric` 无新写入。
- 浏览器行为验收：Playwright（playwright-core + headless Chromium）路由拦截，
  全程文本断言（模型 >8 张图 payload 不可用，截图只存档不读入上下文）。
  拦截仅覆盖 `/admin/packs/*`；页面与 `/api/snapshot` 走真实后端。

## T1 packs 页（能力包生命周期）

### 单元/合同测试（tests/unit/test_dashboard_packs_page.py，4 tests）

- 组装契约：`packs` 同时出现在 `dashboard.JS_MODULES` 与 fragment 元组；
  `<!-- FRAGMENT:packs -->` / `<!-- JS:packs -->` 不残留；
  无 "Fragment packs 加载失败"。
- 源码契约：端点全集（catalog/status/install/custom/uninstall-preview/
  uninstall/policy）、`UI.adminHeaders`、`tabRenderers['tab-packs']`、
  `UI.confirm` + `confirmed:true`、10 阶段标签全集、
  禁词（`downloaded+`/`total_bytes`/`percent` — 不伪造下载进度）、
  无 inline `onclick=`。
- RED→GREEN 记录在案；全量 `pytest tests -q` → **435 passed**。

### 真实 HTTP 验收（沙箱网关 127.0.0.1:8998）

- GET Dashboard HTML 含 `tab-packs` 容器（nav + fragment + JS 注入三处）。
- catalog 200 返回真实目录；policy GET → POST（8192）→ GET 回读一致；
  install / uninstall / uninstall-preview 未知包 404。
- 隔离核验：`policy.json` 只落 `$ROOT/state/packs/`；生产 `~/.inferfabric`
  在验收窗口内无新写入。

### 浏览器行为验收（路由拦截，14 项断言全绿，exit 0）

| 场景 | 断言 | 结果 |
|---|---|---|
| 导航与渲染 | tab-packs 可见、目录/策略卡渲染、策略表单回填 | ✅ |
| 预览失败 | toast「卸载预览失败，已取消：preview boom」，无 uninstall POST | ✅ |
| 确认框披露 | 含「最终候选引用以服务端执行时重新计算为准」+ 受影响池列表 | ✅ |
| 取消 | 无 uninstall POST | ✅ |
| 确认执行 | 恰好 1 次 POST，`confirmed:true`、`pack_id` 正确，toast「已卸载」 | ✅ |
| 阶段指示 | status 切 `verifying` → 轮询后徽标「校验中」 | ✅ |
| 401 | toast 精确等于「401：需要 admin token — 请在右上角输入后重试」，无自动重试 | ✅ |

验收中发现并修复 1 个问题：`_fetch` 统一弹出 401 专用提示后，各回调
error 分支的通用 toast 会立即覆盖它 —— 修复为回调遇
`err.unauthorized` 直接返回（不覆盖、不重试）。修复后重跑全部 14 项断言
通过；全量回归 435 passed。

脚本存档：`~/.claude/jobs/f1f58533/tmp/m2t1-browser-acceptance.js`（会话临时件）。

沙箱已停止（pid kill 确认）。

## T2 security 页（鉴权状态 / 密钥 / 一次性回显）

### 单元/合同测试（test_dashboard_security_page.py + test_dashboard_security_responses.py，11 tests）

- 组装契约：tab-security 真实装配（nav/容器/JS 内联），占位符与失败替身不残留。
- 源码契约：四端点全集、UI.adminHeaders、tabRenderers['tab-security']、
  UI.confirm、明文只经 textContent、禁浏览器存储/URL sink、tab_active 监听、
  无「免鉴权」措辞、401 提示、无 inline onclick。
- 响应契约（隔离临时密钥库，假 handler 直调 ProxyHandler 方法）：
  首次启用 / 关闭 / 主动创建三类成功响应均 `Cache-Control: no-store`；
  status/列表无明文且字段白名单 `{id,name,created_at,revoked}`；
  库内只存摘要（security.db 字节不含明文）；重名创建 → 400 带指引
  （RED→GREEN：未捕获 IntegrityError 曾沿 do_POST 吞异常路径无响应关闭连接）。
- 全量 `pytest tests -q` → **447 passed**。

### 真实 HTTP + 浏览器行为验收（隔离沙箱，两阶段，23 项断言全绿）

Phase A（默认模式，真实后端 + 一次性迟到响应拦截）17 项：
首次启用一次性回显、三态状态回读（不凭 enable 返回值推断）、已有密钥
再开启不回显、已保存关闭/Esc/切页均清空明文、迟到响应被代次守卫丢弃
（迟到 token 不出现在 DOM）、推理鉴权边界（无 key → 401，带 key → 非 401，
经 POST /v1/chat/completions）、吊销警告（最后一把有「最后一把」警告，
非最后无）、全吊销后开启被本地拦截（无 enable POST）+ 引导创建替换 key、
关闭新策略后 off 显示迁移宽限且无「免鉴权」。

Phase B（严格模式 MACFABRIC_ADMIN_REQUIRED=1 + 预置 legacy api_keys.yaml）6 项：
无 admin token → 401 toast 且状态不渲染；输入 token 切页恢复 →
policy=off 与 enforced=true 并存（legacy 仍在拦截），显示迁移宽限、
无「免鉴权」；无 key 推理请求被拒（legacy 生效）；legacy key 通过鉴权。

隔离核验：security.db / api_keys.yaml / security.enabled 只落沙箱
`$ROOT/state/`；生产 `~/.inferfabric` 在验收窗口内无新写入
（token-stats.json 的 mtime 为生产网关 pid 73943 的例行写，与沙箱无关）。
验收用临时 token 文件已删除，QA 记录不含任何明文。

验收中发现并修复 2 个问题：
1. security.js 初版在 tab 激活分支漏调 loadStatus（渲染入口是
   store.on('tab_active')，tabRenderers 仅 forceRefresh 调用）。
2. 后端 `_handle_security_create_key` 只 catch ValueError，重名触发
   IntegrityError 后沿 do_POST 通用路径被吞、连接无响应关闭（浏览器侧
   表现为请求挂起）——补 catch 返回 400（RED→GREEN）。

遗留（不在本任务修）：`do_POST`/`do_GET`/`do_DELETE` 通用异常路径吞异常
不发响应是既有模式（handler.py:663/681/695），建议后续统一补 500 响应。

脚本存档：`~/.claude/jobs/f1f58533/tmp/m2t2-browser-phaseA.js`、
`m2t2-browser-phaseB.js`（会话临时件）。沙箱已停止（pid kill 确认）。

## T3 deploy 页 autostart 开关

### 单元/合同测试（test_dashboard_deploy_autostart.py，5 tests）

- 组装契约：`depAutostart` 容器入 fragment、`snapshot_seq` 序号守卫内联。
- 源码契约：set-autostart 端点、UI.adminHeaders、每模型单写在途
  （_inflight）、写后 forceRefresh 确认读、「待回读确认」、不一致提示、
  「下次网关启动生效」、推理页导航、无 inline onclick。
- 全量 `pytest tests -q` → **452 passed**。

### 浏览器行为验收（隔离沙箱 + QA 模型 YAML，18 项断言全绿）

Group 1（真实 HTTP）：初始关 → 开（YAML `autostart: true` 回读）→ 关
（YAML `autostart: false`）→ 页面重载回读一致；「去推理页启停」导航生效。
测试模型为 llama_cpp 指向不存在路径，未触发任何真实模型启动。

Group 2-4（stopPolling + 显式响应队列，逐请求确定性控制）：
- 乱序不反跳：写前旧请求的响应（关）最后到达 → store 序号守卫整包丢弃，
  界面/store 保持开，恰好 1 次 POST。
- 失败回滚：POST 500 → toast + 显示回滚到快照值；随后成功路径正常。
- 连点防重复：250ms 在途窗口内第二击命中禁用按钮，仅 1 次 POST。
- 确认读暂时失败：force 500 → 「待回读确认」保持；再失败仍保持
  （快照失败不作确认）；成功且一致 → 解析为开；确认读与写值不一致 →
  「服务端回读与写值不一致」提示 + 按服务端值显示。

验收中发现并修复 1 个实现 bug：`snapshot_seq` 最初在 `models` 写入前
set，确认读事件回调读到旧 models，匹配/不一致判定失真（探针阶段暴露，
非脚本问题）——已把序号推进移到快照状态全部应用完成之后。

脚本存档：`~/.claude/jobs/f1f58533/tmp/m2t3-browser-acceptance.js`
（会话临时件）。沙箱已停止（pid kill 确认）。

## T4 cloud 策展属性浮窗

### 单元/合同测试（test_dashboard_cloud_attrs.py，7 tests）

- 组装契约：属性入口（`cpm-attrs`）随 cloud.js 真实装配进页面。
- 源码契约：入口同时出现在发现候选（仅可路由）/ 已声明 spec 行 /
  事件分派（≥3 处）；tag 动作 + 无变更短路（「无变更」不发 POST）；
  能力回填以原始声明为准（`=== true`，显式 false 与 null 同渲染、
  不动即保留）；数值显式清除发 `null`；空串判定 `trim() === ''`
  （0 ≠ 未设置）；token 数 `Number.isInteger`、价格 `isFinite`；
  保存失败内联错误 `cpAttrsErr`（输入保留可更正）；无 inline onclick。
- YAML 落盘回读契约（序列化六键 round-trip，RED→GREEN 见下）。
- 全量 `pytest tests -q` → **459 passed**。

### 真实 HTTP + 浏览器行为验收（隔离沙箱 + 预置 qa-cloud provider，
发现关闭、openai_base 指向不可达地址，不连真实 provider；27 项断言全绿）

POST 拦截记录请求体后放行到真实后端（route.continue）——请求体断言与
GET/YAML 回读同源验证 update_model_spec 真实语义：

- 回填：六键原始声明正确（含 qa-model vision=true 全值回填、qa-x 显式
  false 渲染为未勾选 + 显式排除提示）。
- 无改动保存：不发 POST + 「无变更」提示 + 浮窗关闭。
- 价格改 0：请求体恰为 `{provider,action,model,price_input:0}`（数字 0），
  GET 回读 0。
- 重开回填 "0" 后清空：提交 `price_input: null`，GET 回读 null。
- 非法输入（"abc"）：内联报错、浮窗不关、输入保留、无 POST；
  更正为 4096 后成功提交并回读。
- 视觉解除打标：提交 `supports_vision: false`，GET 回读 null（键移除）。
- 取消：不提交，值不变。
- 只改价格（qa-x 显式 false）：请求体仅含 price_input 键（不含
  supports_vision/tools/context/max_output），GET 回读显式 false 保留。

### 验收中发现并修复 1 个后端序列化缺陷（RED→GREEN）

计划验收要求 GET/YAML 双回读。首轮浏览器验收暴露：
`CloudDiscovery._serialize_providers` 从不写 `context_window` /
`max_output_tokens`（在 known 排除集内挡住兜底循环，却无显式写出分支），
且价格用 truthy 门（0 被当未设置丢弃）→ 属性经 save_config 后重启静默
蒸发。修复：数值属性改 `is not None` 门并补两个 int 键的显式写出；
新增 `test_cloud_attrs_yaml_roundtrip`（含 0 价 / 0 max_output_tokens /
显式 false）先失败后通过。修复后浏览器验收重跑 27/27，YAML 回读逐键核对
正确（写入的 4096 落盘、清除的键消失、qa-x 显式 false 保留）。

### 遗留记录（不在本任务修，均既有行为）

1. `discovery_enabled` 序列化/加载不对称：save_config 写平铺
   `discovery_enabled: false`，加载只读嵌套 `discovery.enabled` → 关闭
   发现的 provider 经 save_config 后重启发现重新开启（本轮验收实测复现）。
2. 序列化 `timeout`/`discovery_interval` 等同样 truthy 门（0 不落盘）——
   属性编辑器不管这些键，与 T4 无交互。
3. 前端对 `supports_tools` 无面板入口（7.9.0 退役，字段格式兼容保留），
   浮窗同样不提供——显式排除唯一入口仍是手编 YAML。

隔离核验：写入只落沙箱 `$ROOT/state/`；生产 `~/.inferfabric` 在验收窗口
内无新写入（token-stats.json mtime 为生产网关 pid 73943 例行写）。

脚本存档：`~/.claude/jobs/f1f58533/tmp/m2t4-browser-acceptance.js`
（会话临时件）。沙箱已停止（pid kill 确认）。

## T5 overview 内存账本卡（只读投影）

### 单元/合同测试（test_memory_ledger_snapshot.py，11 tests + 既有
test_device_api_contract.py 12 tests 保持原行为）

- 投影：活跃模型全额记账（baseline 缺省回退 peak_vram_mb）；不在活跃
  集合的模型不入账（已退出进程的 llama.cpp sleep）；无 25% 睡眠折扣；
  统一内存但采样字段缺失保留 null、committed 仍可计算；空闲 committed=0；
  非 unified / 无快照 → None；准入路径不变（目标排除 — 否则会
  「已在运行」放行；预算探测走原探针）。
- 接线：handler 把已获取的 dev_snap 显式传入（同一快照对象、不新增探针，
  dev.calls==1）；旧 mgr 测试桩（无该方法）缺省兼容 memory_ledger=null；
  memory_ledger 变化进 ETag。
- 前端契约：store 透传；overview 压力四级文案（正常/警告/严重/未知）、
  预算未知/零不算百分比、账本卡只读（renderLedger 窗口无 data-action）。
- RED→GREEN 记录在案；全量 `pytest tests -q` → **470 passed**。

### 真实 HTTP + 浏览器行为验收（隔离沙箱，16 项断言全绿）

Group 1（真实后端，macOS 统一内存 + 播种夹具）：models.d 放 QA 模型
YAML（mem_baseline_mb 3100，指向不存在路径，未拉起任何进程），StateDB
直接播种 active_services —— 不为验收重启或拉起宿主模型。卡片展示
committed 3,100 / 预算 28,672 MB，压力徽章与同响应 device.snapshot
pressure_level 映射一致，条目行含 qa-ledger-model，卡内无 data-action。

Group 2（stopPolling + 显式响应队列，逐快照定制）：压力 2→警告、
3→严重、null→未知；预算 0 / null →「预算未知」且不出现百分比、
committed 原值仍展示；超预算 26,000/24,576 → 原值不掩盖（106% 如实
给出）；memory_ledger null → 「不可用」空态；非 unified（vram）→
同样空态。递增 ts 规避 store 乱序守卫（T3 同款坑，脚本侧修正）。

验收中发现的过程性事实（非缺陷）：网关 health_monitor 每 60s reconcile
会清掉「DB 有但实际未运行」的播种活跃服务 —— Group 1 验收窗口用
「重启网关 + 立即播种」获得确定性（首跑曾撞上 reconcile 清种）。

隔离核验：写入只落沙箱 `$ROOT/state/` + `models.d/`；生产
`~/.inferfabric` 在验收窗口内无新写入。

脚本存档：`~/.claude/jobs/f1f58533/tmp/m2t5-browser-acceptance.js`
（会话临时件）。沙箱已停止（pid kill 确认）。

## 全分支终审（fresh reviewer）与修复轮

### 终审结论：approve-with-fixes（2 Important + 2 Minor；评审者独立跑全量 470 绿）

### 修复轮（每项 RED→GREEN，全量 471 绿）

1. **Important — packs.js loadCatalog 漏 401 守卫**（QA T1 修过 5 个写回调，
   GET 路径漏网）：目录加载失败 toast 毫秒级覆盖 401 专用提示。修复为
   `if (!err.unauthorized)` 守卫；合同测试加 `err.unauthorized` 计数 ≥6 钉住。
2. **Important — deploy 确认读门槛允许写前在途轮询充当确认读**：
   `minSeq = appliedSeq()+1` 时，写前已发出在途的轮询（序号恰为 +1）先于
   确认读应用 → 误报「不一致」+ 界面闪回关。修复：store 新增
   `fetchSnapshotEx(force, onSeq)`（返回 `{seq, snap}`，onSeq 在请求发出前
   同步回调）+ `forceRefreshEx`；deploy 以确认读请求自身序号为 minSeq；
   `fetchSnapshot`/`forceRefresh` 旧签名不变。**浏览器 RED→GREEN 闭环**：
   专用交错场景脚本先在修复版上绿、临时还原旧实现后精确复现评审描述的
   失败（误结算 + 误报 toast）、恢复修复并重启网关（dashboard HTML 进程内
   缓存——改 JS 后必须重启）再绿。
3. **Minor 4 重定级入修复（计划符合性）**：计划要求「两条路径共享活跃模型
   登记逻辑」，此前 helper 仅观测路径消费、`_admit_memory` 留有内联副本
   （漂移风险正是账本功能要防的口径错位）——回接到共享 helper，既有准入
   测试（目标排除 + 探针策略）作门，保持绿。

### 遗留（deferred minors，未修）

- packs.js `stageLabel` 未知阶段回退 `String(stage)` 未经 escHtml 进
  innerHTML —— 今天 stage 为服务端枚举无实际注入面，违反自家「动态内容
  按不可信处理」约定，后续顺手修。

隔离核验：修复轮浏览器验证写入只落沙箱；生产 `~/.inferfabric` 无新写入。
脚本存档：`~/.claude/jobs/f1f58533/tmp/m2fix-browser.js`（会话临时件）。
