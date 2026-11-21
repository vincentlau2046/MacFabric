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

## Task 4 — Responses 原生优先合同（responses_bridge）

- 录制件 `tests/golden/responses_native_stream.sse`（created / output_text.delta /
  completed 三事件确定性 SSE，非网络录制）。
- RED→GREEN：`tests/unit/test_responses_bridge.py` 20 用例（含既有迁移用例）：
  - 非流式/SSE 双场景：`/v1/responses` 直连原生（200/committed 不落兜底）；
    SSE 帧重组与 golden 逐事件一致（chunked）。
  - `RESPONSES_UNSUPPORTED_STATUSES`（400/404/422/501）→ 恰好一次 Chat 兜底，
    封装断言走 `json_errors`；committed 后失败**永不**兜底（探测 committed=True
    + 404，monkeypatch `_probe_native`）。
  - 两个文本突变负对照（importlib 加载临时突变副本）：翻转原生优先锚点 /
    打开兜底 gate 锚点 → 各自锚定用例失败，证明合同被钉住。
- 回归：既有 responses 兜底行为全部保留（SSE 透传、封装格式不变）。

## Task 5 — 出站账号池占位（F6 stub）

- RED→GREEN：`tests/unit/test_outbound_credentials.py` 7 用例：
  恒等透传（普通/空字符串）、keyword-only 固定参数面（无 extras）、
  双协议真实回环 stub（OpenAI Bearer / Anthropic x-api-key 原样出站）、
  每转发恰好调用一次、重试沿用同一选定值、入站 F7 标记不入参、
  空 key header 语义不变（空 Bearer）。
- 设计文档 `docs/superpowers/specs/2026-11-19-outbound-account-pool-design.md`：
  F7 入站 / 模型池 / F6 出站三层分清表、接入点、未来方向（配额路由/
  账号隔离/会话亲和，均需另立评审）、硬约束（同 attempt 不换 key、
  committed 不可重放、空 key 语义不变）。

## 过程修复记录

- `connect_handlers._read_json` 初版把 `_read_body()`（已解析 dict）当字节处理
  → 浏览器验收 C 场景暴露（invalid JSON body）→ 修正为形态守卫；
  测试假 `_read_body` 同步对齐真实契约（返回 dict）。
- 测试占位主机 `evil`/`elsewhere` 触发 test_no_network_dependency guard →
  改用白名单占位（evil.example / example.com），白名单未扩充。

## 独立评审与修复通道（收尾门）

独立评审（fresh reviewer，范围 8364e84..88e3e7d）判定 No，2 Critical /
4 Important / 3 Minor。重定级与处置：

**已修（RED→GREEN + 全量绿，commit 见 fix 提交）**：
- **C1 事务内重验 + 跨实例串行**：模块级 per-client 锁（threaded/async 各自
  new 的 manager 全部串行）；一次 lstat+read 同取 revision 与字节；构建后
  `_recheck` + `os.replace` 前 `expect_rev` 双重重验；外部编辑在事务中被
  检测即 conflict，绝不覆盖。
- **C2 备份私有性/崩溃安全**：original.bin O_EXCL 首次创建绝不截断（权限
  放宽自动收紧）；record.json 原子替换；回退前 sha256 完整性校验（损坏
  备份拒绝回退不写垃圾）；记录新增 `prior_post`（当前磁盘托管 revision）—
  重应用在替换前中断后，inspect 仍识别 managed、一键回退可用；新建目录
  fsync 父目录链。
- **I1 Origin 同源收紧**：Origin 必须与请求自身 Host（已验证回环 authority）
  全等且 scheme 为 http — 别名交叉（127.0.0.1 vs localhost）与 https 全拒。
- **I2 适配器合同收口**：body 层已发响应（read_body 400/413 / shim 锁头）
  时路由层不再发第二个响应（`_responded` 标记 + `_headers_locked` 守卫）；
  threaded read_body 错误响应与 async `_json_response` 统一 no-store；
  status/apply/rollback 的非门禁异常统一映射带 code 的单响应，不泄漏内部
  细节。
- **I4 按计划对齐缺目录语义**：apply/rollback 前置校验，客户端目录缺失即
  conflict、零副作用（不建目录/不写状态）— 计划原文"只创建已存在客户端
  目录下的配置"；原"缺目录自动创建"测试替换为拒绝测试。

**裁定不修（Ruling）**：I3 direct Responses 云路由 `cloud:` 前缀 provider
查注册表失配 + 未提交无响应两处为**基线缺陷**（Task 4 之前已存在，非本
分支回归）；计划 Task 4 明确要求"记录此类差异、单独修复"。已记录，修复合入
另行立项；Codex CLI 验收证明配置加载与池路径请求完成，直连云分支验收随之
补齐。

**Deferred minors（ledger 台账）**：合同套 overstate pinning（transport
closure 直调非 run_attempts / priority 突变锚点）；test_connect_admin 不断言
被拒 key 后目标字节（已补 rejected_rollback 侧）；outbound 参数化仅 OpenAI；
manifest #9 行含 T4/T5 文件（已有单列说明）；浏览器 harness 不在评审范围 +
Linux 未验；dashboard 401 提示丢失 enable-auth hint。SSE golden 尾部空行 =
事件终止符（逐字节断言的一部分），`.gitattributes` 对 golden/*.sse 显式
豁免 whitespace 检查。

**修复后全量**：`../.venv/bin/python -m pytest tests -q` → **634 passed,
4 warnings in 51.67s**（存档 fix-suite.txt；623 + 11 个评审修复新测试）。

## 全量与遗留

- 最终全量（评审修复后）：`macfabric_gateway` 下
  `../.venv/bin/python -m pytest tests -q` → **634 passed, 4 warnings in 51.67s**
  （存档 `.superpowers/sdd/2026-11-19-m3-connect-responses-account-pool/fix-suite.txt`；
  此前基线 623 passed 见 final-suite.txt；warnings 为既有 pytest 弃用提示）。
- `git diff --check` clean（工作树与 8364e84..HEAD 提交范围均无空白错误；
  golden SSE 尾部空行为 SSE 事件终止符，经 .gitattributes 显式豁免）。
- 沙箱终态：网关（8998）与 recorder（8997）进程均已停止、端口无监听；
  `~/.claude/jobs/f1f58533/tmp/m3-accept/` 留存合成 key、种子配置、recorder
  日志，**不含任何真实凭据**。
- 未验平台：Linux（本机 macOS only）；CLI 验收仅覆盖 macOS arm64 本机版本
  （claude 2.1.328 / codex 0.167.0）。无硬件依赖合同（单测）不依赖平台。
