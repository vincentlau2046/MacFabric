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
