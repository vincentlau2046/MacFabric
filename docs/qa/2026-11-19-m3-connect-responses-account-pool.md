# QA — M3 Connect / Responses 合同 / 出站账号池占位（2026-11-19）

分支 `feat/m3-connect`（基线 main 31a4310 + 计划 8364e84）。
沙箱纪律：隔离 HOME / MACFABRIC_STATE_DIR、127.0.0.1:8998、合成 key、
浏览器全程文本断言（无截图进上下文）；真实账号、外网推理、生产配置零参与。

## Task 1 — ConnectManager 文件事务（platform/clients.py）

- RED→GREEN：`tests/unit/test_connect_clients.py` 9 用例
  （apply→rollback 字节还原 + 无关设置保留、missing_file/directory 只动托管件、
  stale revision/symlink 拒绝、畸形/重复 JSON/无效 TOML/保留 provider 名/
  既有 ANTHROPIC_API_KEY 冲突、os.replace 注入失败 → 原件完整 + 不宣称托管 +
  备份 0700/0600 私有模式）。
- 依赖：tomlkit==0.13.3 进入 requirements.txt（uv 装入 .venv，无全局安装）。

## Task 2 — /admin/connect/* 控制面（connect_handlers.py）

- RED→GREEN：`tests/unit/test_connect_admin.py` 13 用例：
  门禁（threaded/async 两路参数化）：非回环对端 + 伪造转发头 → 403、
  缺/错 admin token → 401、错端口/错 Host/跨站 Origin/缺 Origin → 403、
  对端信息缺失 → 403；F7 key：ID/token 交叉、撤销、admin token 冒充、
  未知 ID、store 缺失 → 统一 400 invalid_key（fail-closed）；
  confirmed 严格布尔 True；409/400 映射；no-store + 不回显 + 无日志。
- 回归：test_admin_auth + test_dashboard_security_responses +
  test_admin_models_remove 34 用例全过（其他 /admin 路由行为未动）。

## Task 3 — Dashboard Connect 页 + 沙箱真实验收

- 组装/契约单测：`tests/unit/test_dashboard_connect.py` 7 用例
  （三处装配、只读 /admin/security/status 不发 key、一次性密码输入、
  显式 confirmed、401 专用提示、409 无自动重试、四态文案、无 inline onclick）。
- 浏览器行为验收 `m3-connect-browser.js`（playwright-core + chromium headless，
  沙箱网关 8998）：**40/40 通过**。覆盖：状态加载（进入页面零写请求）、
  取消确认零 POST、错误 key 失败无成功提示、claude 托管（无关 env/插件保留）、
  回退字节还原、codex 托管（注释/model/history 保留，tomlkit 保格式）、
  回退字节还原、401 专用提示、外部编辑 → 409（无自动重试，状态重读）、
  key 明文不出现在 DOM/Toast、一次性输入清空。
- **真实 CLI 协议验收**（仅回环 recording 服务 127.0.0.1:8997，合成 key
  `sk-synthetic-cli-key`，服务只记录路径/次数/key 匹配布尔）：
  - Claude Code **2.1.328**：`HOME=<沙箱> claude -p "say ok" --model test-model`
    → `POST /v1/messages`（另有 `?beta=true` 流式探测）→ exit 0，
    `key_match: true`（env.ANTHROPIC_BASE_URL / ANTHROPIC_AUTH_TOKEN 生效）。
  - Codex **0.167.0**：`CODEX_HOME=<沙箱> codex exec --skip-git-repo-check "say ok"`
    → `POST /v1/responses`（SSE）→ exit 0、tokens used 2，
    `key_match: true`（model_provider + model_providers.inferfabric 的
    base_url/wire_api/requires_openai_auth=false/experimental_bearer_token 全部生效；
    recorder 未实现 output_item.added 事件仅产生一条无害告警，会话正常完成）。
  - 结论：ConnectManager 写出的两种配置形态被真实 CLI 加载并按预期协议发请求；
    无「字符串存在 ≠ 加载成功」风险残留。

## 过程修复记录

- `connect_handlers._read_json` 初版把 `_read_body()`（已解析 dict）当字节处理
  → 浏览器验收 C 场景暴露（invalid JSON body）→ 修正为形态守卫；
  测试假 `_read_body` 同步对齐真实契约（返回 dict）。
- 测试占位主机 `evil`/`elsewhere` 触发 test_no_network_dependency guard →
  改用白名单占位（evil.example / example.com），白名单未扩充。

## 全量与遗留

- 全量：`macfabric_gateway` 下 `../.venv/bin/python -m pytest tests -q`
  → **603 passed**（Task 4/5 完成后复跑数字见下文补记）。
- 沙箱残留：`~/.claude/jobs/f1f58533/tmp/m3-accept/`（合成 key、种子配置、
  recorder 日志），不含任何真实凭据；teardown 已停网关/recorder 进程。
- 未验平台：Linux（本机 macOS only）；CLI 验收仅覆盖 macOS arm64 本机版本。
