# M3 Connect, Responses and Account Pool Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让本机 Dashboard 能安全接入和回退 Claude Code、Codex，补齐 Responses 原生优先合同，并留下可运行但不改变线上行为的出站账号池接口。

**Architecture:** Connect 的文件事务在 `platform/clients.py`，管理接口只负责请求门禁、F7 校验与转发；Dashboard 复用现有 fragments/js，无前端构建链。Responses 只补合同测试，账号池只接入原样返回现有 provider key 的默认实现。三块按 F10 → F1 → F6 顺序独立交付，不互相绑定为一笔上游改动。

**Tech Stack:** Python、pytest、PyYAML（现有依赖）、`tomlkit==0.13.3`（拟新增，仅用于 Codex 的保留格式编辑）、原生 Dashboard JS、Playwright 文本断言。

**Spec:** [Mac 特性锁定 F1/F6/F9/F10](../specs/2026-11-18-mac-feature-lockdown.md)、[纯 Python 网关设计 §8–10](../specs/2026-11-18-python-gateway-refocus-design.md)、[上游对账清单](../../upstream/CHERRY-PICK-MANIFEST.md)。2026-11-19 用户裁决：复用 F7 已有 key，不增发；账号池采用设计文档 + 可跑接口 stub；顺序 T1 Connect → T2 Responses 合同 → T3 账号池。

## Global Constraints

- 「UI = 上游式 web dashboard，挂在 :8999，不引入构建链」；「改写前显式确认 + 可一键回退」。端口取本实例可信绑定配置（生产默认 `8999`，验收 `8998`），不使用 HTTP Host、Forwarded 或浏览器提交的 URL 拼接客户端地址。
- F7 是入站网关鉴权，F6 是出站云账号选择，两种 key 不互传。F7 数据库只存摘要，`/admin/security/status` 只列元数据；选 ID 无法取回明文。Connect 在确认后由用户一次性粘贴自己保存的 F7 key，服务端校验所选 ID 与 key 匹配且有效；遗失明文回 Security 页处理，Connect 不发 key、不找回、不回显。不会把 admin token 写入客户端。
- Connect 只托管运行网关的同一用户、同一主机的客户端。接口只接受真实回环连接、准确的当前实例 Host、同源 Origin（POST 必须有 Origin）及现有有效 admin token；Connect 不继承无 token 兼容放行。没有 token 时显示启用现有管理鉴权的指引；不修改全局鉴权策略。反代/Tailscale/远程主页、任意路径、自选 URL、账号迁移和 OAuth 登录均不在范围内。
- 明文仅经过确认后的本机请求并写入客户端要求的受保护文件。不得出现在预览、响应、日志、快照、浏览器持久存储、计划记录或共享验收产物；Connect 响应带 `Cache-Control: no-store`。只用合成 key、临时 HOME/CODEX_HOME、临时 `MACFABRIC_STATE_DIR`/`MACFABRIC_MODELS_DIR`、`127.0.0.1:8998` 验收；浏览器只用文本断言，不把截图读入模型上下文。
- 生产客户端配置、服务与凭据不参与验收；依赖通过 `requirements.txt` 进入现有 CI/安装链，不执行全局安装。每个交付单元保留 RED→GREEN；全量和独立评审通过才进入合并裁决，本计划不授权 commit/push、合入或部署。

## Review Focus

1. **同名 key 与失效 key**：仅知道 ID 无法写入；错误 key、另一个 ID 的有效 key、撤销/过期 key、admin token 均拒绝且不落盘（Task 2）。
2. **误改用户文件**：预览后目标变了、回退前用户另有修改、文件或中间目录是符号链接时，均拒绝覆盖；匹配当前版本才写，回退保留原始字节（Task 1）。
3. **来源授权**：本机兼容模式、跨站来源、伪造 Forwarded、非回环对端都不能触发写入；两种 server 的 Connect 路由走同一门禁（Task 2）。
4. **协议降级边界**：Responses 已提交输出、429/5xx 非约定错误或无状态传输错误均不走 Chat fallback；四个约定状态的 fallback 不多扣一次 attempt（Task 4）。
5. **占位不偷改行为**：账号池 stub 不读取会话/配额，不改变出站 key、请求路径、重试次数或空 key 语义；两套鉴权不会串用（Task 5）。

---

路径以下相对于仓库；有 `tests/` 和 `inferfabric/` 的代码块均在 `macfabric_gateway/` 下。命令在 `macfabric_gateway/` 执行，除非另行注明。Task 1–3 是批准的 T1（F10），Task 4 是 T2（F1），Task 5 是 T3（F6）；QA/manifest 是收尾门。

### Task 1: Connect 配置事务与两种客户端适配

**Files:** 新建 `macfabric_gateway/inferfabric/platform/clients.py`、`macfabric_gateway/tests/unit/test_connect_clients.py`；修改 `requirements.txt`。

**Interfaces:** `ConnectManager(*, home: Path, state_dir: Path, gateway_origin: str, codex_home: Path | None = None)`；`inspect(client: str) -> dict` 返回 `{client, state, target, revision}`（`state` 为 `missing_directory | missing_file | unmanaged | managed | conflict`；`target` 为 `this_gateway | other | unset | unknown`，仅分类，不读出原 URL/凭据）；`apply(client: str, *, expected_revision: str, api_key: str) -> dict`；`rollback(client: str, *, expected_revision: str) -> dict`。执行成功返回新 `inspect` 状态。`ConnectError` 提供固定 `code`：`invalid_request | unavailable | conflict | io_error`，错误消息不得拼接配置内容。

- [ ] **写测试：** `test_apply_then_rollback_restores_bytes_and_unrelated_settings` 参数化两客户端；对有注释的 TOML、含无关 env/插件的 JSON，断言仅托管字段语义变化，回退原始字节一致。`test_missing_file_rollback_removes_only_managed_file` 断言只创建已存在客户端目录下的配置，回退只移除本次创建的文件。`test_stale_revision_post_apply_edit_or_symlink_never_written` 断言变更、目标与父目录符号链接均拒绝且目标/链接另一端不变。`test_malformed_or_conflicting_config_leaves_original_untouched` 钉住无效/重复 JSON、无效 TOML、保留的 provider 名冲突、Claude 目标文件既有 `ANTHROPIC_API_KEY`；`test_atomic_failure_retains_recoverable_original_and_private_modes` 模拟 replace 失败，断言原文件完整、不宣称托管成功、凭据文件/备份不宽于 `0600`。
- [ ] **RED：** `../.venv/bin/python -m pytest tests/unit/test_connect_clients.py -q`；预期未实现接口导致失败（测试内延迟 import）。
- [ ] **实现：** 服务端固定 `~/.claude/settings.json` → `env.ANTHROPIC_BASE_URL=<origin>` 与 `env.ANTHROPIC_AUTH_TOKEN=<F7 key>`；固定 `$CODEX_HOME/config.toml`（未显式设置则服务用户 `~/.codex`）→ `model_provider="inferfabric"`，`model_providers.inferfabric` 配置 `name="InferFabric"`、`base_url="<origin>/v1"`、`wire_api="responses"`、`requires_openai_auth=false`、`experimental_bearer_token=<F7 key>`；不改 `auth.json`、项目级配置、环境变量或默认模型。检测保留 provider 名冲突，首次托管先备份；重复托管保留首次原件，不生成备份链。本机 Codex `0.167.0` 二进制含相应字段，但字符串存在不等于加载成功，Task 3 必须实测。CLI 字段不兼容则停在复核，不静默切换认证方式。Claude 的 shell/项目层 auth 或模型覆盖不擅自改写，文档提示重新启动客户端并检查优先级。
- [ ] **实现文件安全：** 仅允许固定客户端目标；可信服务 HOME/CODEX_HOME 根与后续路径不得经符号链接；用安全打开和文件类型/所属用户检查，不写其他用户目录。每客户端串行事务；每次变更在写前核对 revision，以同目录临时文件 + flush/fsync + 原子替换提交。状态目录中私有备份记录原始字节（或原先不存在）、预期前后 revision；备份持久化先于替换，重启后按前后 revision 识别未完成操作，无法识别则报冲突。合同不承诺能锁住所有外部编辑器；检测到外部改动不覆盖。回退成功后清除活动备份；备份目录 `0700`、文件 `0600`。若系统不满足安全打开前提，错误可见并不写文件。
- [ ] **GREEN：** 重跑 Task 1 命令，预期全部通过；保留测试名与红绿输出。

### Task 2: 本机 Connect 控制面

**Files:** 新建 `macfabric_gateway/inferfabric/proxy/connect_handlers.py`、`macfabric_gateway/tests/unit/test_connect_admin.py`；接线 `macfabric_gateway/inferfabric/proxy/{handler,async_server}.py`，最小修改 `macfabric_gateway/inferfabric/security/key_store.py`。

**Interfaces:** 消费 Task 1 `ConnectManager` 与 `ConnectError`；新增 `KeyStore.active_key_id(token: str) -> str | None`，复用 `_entry` 的撤销/过期判定，不新建 secret storage。`GET /admin/connect/status` → `{clients:[{client,state,target,revision},...]}`；`POST /admin/connect/apply {client,expected_revision,confirmed:true,key_id,api_key}`；`POST /admin/connect/rollback {client,expected_revision,confirmed:true}`；写操作成功 `{client,state,target,revision}`，失败 `{error,code}`。错误状态：输入/确认缺失 `400`、管理 token 缺失或错误 `401`、来源或对端拒绝 `403`、配置不可用 `422`、revision 冲突 `409`、文件 I/O `500`。F7 key 不匹配/失效统一 `400 invalid_key`，不区分命中情况。

- [ ] **写测试：** `test_connect_admin_requires_token_and_real_loopback` 参数化 threaded/async 请求适配，断言非回环对端即使声明转发来源为回环仍 `403`，同源但无有效 token `401`，错误端口、Host 或 Origin `403`，同源且 token 正确才成功。`test_connect_only_accepts_matching_active_f7_key` 用真实临时 F7 store 验证 Review Focus 1，原文件不动。`test_apply_and_rollback_confirm_are_strict_true` 断言缺省、`false`、`"true"`、数字 `1` 都不执行。`test_connect_routes_no_store_and_do_not_disclose_token` 断言访问成功/失败均无回显、无 token 日志。
- [ ] **RED：** `../.venv/bin/python -m pytest tests/unit/test_connect_admin.py -q`；预期路由或校验接口缺失。
- [ ] **实现：** 两种 HTTP server 分别从 socket 对端（threaded `client_address`／aiohttp `request.transport.get_extra_info('peername')`）取来源，缺信息即拒绝，不相信转发头；Connect 门禁先于读含 key 的 body。只认有配置的管理 token（恒定时间比较）与精确的实例回环 authority；其他 `/admin` 路由行为不动。`apply` 校验 F7 通过后才调用 `ConnectManager`，`rollback` 仅需 admin 授权，不要求待撤销的 F7 key 仍可用。HTTP 层不接收路径、URL 或 HOME 参数。
- [ ] **GREEN：** 重跑 Task 2 命令及 `../.venv/bin/python -m pytest tests/unit/test_admin_auth.py tests/unit/test_dashboard_security_responses.py -q`；预期全部通过。

### Task 3: Dashboard Connect 与沙箱接入/回退验收

**Files:** 新建 `macfabric_gateway/inferfabric/dashboard/{fragments/connect.html,js/connect.js}`、`macfabric_gateway/tests/unit/test_dashboard_connect.py`、`docs/qa/2026-11-19-m3-connect-responses-account-pool.md`；修改 `macfabric_gateway/inferfabric/dashboard/{base.html,__init__.py}`。

**Interfaces:** 同 Task 2；Key 名称/ID 只取现有 `/admin/security/status`；使用 `UI.adminHeaders()`，一次性密码输入随弹窗/请求结束清空。

- [ ] **写测试：** `test_connect_tab_is_assembled` 断言两份注册清单与导航/fragment/JS 已装配；`test_connect_uses_f7_metadata_not_minting` 断言只读 Security 状态、不调用发 key API。Playwright 文本用例：加载状态 → 选已有 key → 取消确认（无写请求）→ 托管 → 本机沙箱客户端读到新配置 → 回退 → 原内容一致；另测错误 key、401、外部编辑后 409、响应不包含 key、失败时不提示成功。
- [ ] **RED：** `../.venv/bin/python -m pytest tests/unit/test_dashboard_connect.py -q`；预期 Connect 组装缺失。正式浏览器运行前检查沙箱 pid、端口、实际 HOME/状态目录、fixture 路径及 `/api/snapshot` 健康；由日志和终态断言文件监视，禁止健康检查失败后继续。
- [ ] **实现：** 展示目标客户端、当前托管状态与指向分类（本机网关／其他／未配置／未知）；页面状态保留最后一次预览 revision，不展示其原值。托管、回退都点击显式确认才 POST。进入页面不修改配置；409 要求重新读状态/确认，不自动重试；401 专用提示不可被通用错误覆盖。不要在 UI 显示原配置正文或旧 URL。配置写完说明需重启客户端，未提供的模型设置由现有客户端配置保留。
- [ ] **GREEN：** 重跑 Task 3 单测。浏览器用隔离 HOME 对两客户端执行真写、真回退，并用安装的 CLI 在沙箱对仅回环测试服务发最小真实协议请求，断言 Claude Code 命中 `/v1/messages`、Codex 命中 `/v1/responses`，认证使用合成 key；不使用真实账号、外网推理或执行工具。测试服务只记录路径、次数及 key 匹配布尔值。若客户端不可用或字段被拒，记录为未验收，不以解析配置或模拟 HTTP 冒充。QA 写明验证过的 CLI 版本、命令和结果。

### Task 4: Responses 原生优先合同（F1）

**Files:** 修改 `macfabric_gateway/tests/unit/test_responses_bridge.py`，新增小型确定性录制件 `macfabric_gateway/tests/golden/responses_native_stream.sse`（若需要）；不改生产路由。

**Interfaces:** 复用 `responses_bridge._transport_factory(...)(candidate, remaining)`、`handle_responses_direct`、`AttemptResult` 与现有 `tests/golden/openai_{plain.json,stream.sse}`；上游必须能在无云账号、GPU 与 key 下运行。

- [ ] **写合同：** `test_responses_native_nonstream_preserves_envelope`、`test_responses_native_sse_preserves_events` 验证真实本机 HTTP stub 请求路径/模型和原生 JSON/SSE 交付，不发生 Chat 请求；`test_unsupported_uncommitted_native_falls_back_once` 参数化 `400/404/422/501`，断言同候选、同一 attempt、一次 Chat 调用及正确的 Responses 封装；`test_committed_or_other_native_failure_never_falls_back` 覆盖已提交（哪怕状态码在集合内）、`429/500/503`、无状态错误，并断言零 Chat 调用。保留既有池别名与工具调用映射测试，不重新定义 Anthropic 合同。
- [ ] **验证合同有效性：** `../.venv/bin/python -m pytest tests/unit/test_responses_bridge.py -q`。这是测试补齐，不强行改生产代码制造 RED；在临时副本分别颠倒 native 优先和放开 fallback gate，预期对应新测试失败；还原后同命令 GREEN。若当前原样代码不能通过新合同，记录实际差异并单列修复，不夹带行为改动。
- [ ] **证据：** 记录临时副本的负对照、原样 GREEN，以及上游可复跑所需的测试/录制件路径，归 manifest #1。

### Task 5: 出站账号池文档与不改变行为的 stub（F6）

**Files:** 新建 `docs/superpowers/specs/2026-11-19-outbound-account-pool-design.md`、`macfabric_gateway/inferfabric/outbound_credentials.py`、`macfabric_gateway/tests/unit/test_outbound_credentials.py`；仅改 `macfabric_gateway/inferfabric/forwarder.py` 的出站 header 装配点。

**Interfaces:** `select_outbound_api_key(*, provider_name: str, configured_api_key: str) -> str` 默认原样返回 `configured_api_key`；在 `forward_to_cloud` 通过原协议能力/端点校验后、首次组装鉴权 header 前调用。在同次转发的重试中沿用该结果。Chat Completions 和 Messages 共享这个 forwarder；`responses_bridge.py` 的原生探测/Chat 兜底、discovery、管理探测有单独接线，本期不迁移。

- [ ] **写测试：** `test_default_outbound_selector_returns_configured_key_unchanged` 覆盖普通/空字符串；`test_forwarder_uses_selected_key_without_changing_route_or_retry` 对两种协议捕获现有路径和出站 headers（OpenAI Bearer / Anthropic `x-api-key`），验证选择器每转发一次调用、重试仍用同一选定值、入站 F7 标记从未被传给选择器。
- [ ] **RED：** `../.venv/bin/python -m pytest tests/unit/test_outbound_credentials.py -q`；预期接口缺失或 forwarder 未接线。
- [ ] **实现：** 仅透传，无新配置键、配额读写、账号轮转、粘连、重试策略、持久化、后台任务或遥测字段。文档分清 F7 入站、模型池选模型、F6 出站选账号；描述未来可选的配额、账号隔离和会话亲和方案，以及同一次 attempt、跨账号重放、已提交响应的约束；这些行为均需要另立评审，本期不预先冻结实现细节。
- [ ] **GREEN：** 重跑 Task 5 定向测试和 Task 4 Responses 合同，预期全绿；空 key 头行为保持既有语义。

### 收尾门：全量、评审与上游对账

- [ ] 在执行分支预检依赖、分支与沙箱后运行 `../.venv/bin/python -m pytest tests -q`，另从仓库根运行 `git diff --check`；保存完整输出，报告警告和失败。用独立评审核查 Review Focus（尤其 Connect 的权限与改写/回退事务），有阻断项先做回归钉再修。
- [ ] QA 记录实际测试计数、沙箱终态、真实 CLI 是否验过、未验平台／风险；不留密钥、token 或含认证值的备份样本。Apple Silicon 与 Linux 都跑无硬件依赖合同；真实 CLI 平台结果只在实际执行后注明。
- [ ] `docs/upstream/CHERRY-PICK-MANIFEST.md`：#9 记 F10 和 F7 实际依赖及 `tomlkit` 安装链；#1 单列 Responses 合同；F6 单列出站占位、不宣称账号池可用。各项保留独立 diff 和上游验收命令。M3 不作为其他已就绪 manifest 条目的上游化前置，也不增加 MacFabric 退役范围。提交、外发和部署按已批准的独立授权执行。
