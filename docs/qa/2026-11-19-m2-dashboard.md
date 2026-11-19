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
