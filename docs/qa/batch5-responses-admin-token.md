# 批 5 QA — /v1/responses 原生优先入口 + Admin-Token 主动录入（2026-11-18）

## 交付物

### 1. Issue #1 修复：/v1/responses（codex CLI 兼容）

设计契约（用户裁决 2026-11-17 两轮确认）：
- **原生能力优先**：Responses 请求体零改写透传上游 /responses
  （云端 openai_base + /responses；本地引擎 /v1/responses），
  不做能力标注预判、不配置任何新字段。
- **转换仅兜底**：只有上游明确返回失败（400/404/422/501 且未向客户端
  提交任何字节）才对该次尝试降级 Responses→chat 翻译，非流式探测后
  翻译回 Responses 形状交付。401/403/429/5xx 不属于"不支持"，
  交既有池动作表（冷却/等待/回退）。
- 池路径：每候选"原生→兜底"封装在单个 transport 回调内，
  run_attempts 只记一次 attempt，预算/冷却/回退全链路复用。
- 直连路径同优先级（云路由/本地活跃模型/404 unknown_model）。
- 翻译层覆盖：instructions→system、input 字符串/数组、
  function_call/function_call_output 历史 ↔ tool_calls、tools 双向、
  max_output_tokens→max_tokens、tool_choice 双向；reasoning 项跳过
  （会话历史不可迁移守卫，与池 spec §7 一致）。

### 2. Admin-Token 主动录入（用户裁决：替代被动 born 迁移的唯一路径）

- 删除 AdminTokenBootstrap（GatewayClient.swift 整体 + main.swift 的
  init 调用 + attachAdminToken 兜底重试 + 契约测试 4 项 born 断言）。
  理由：读 secrets.env 的动作会被系统拦截（TCC），且用户明确"不要启动"。
- 设置页新增"Admin Token"录入卡：SecureField → Keychain
  （service io.macfabric.gateway-admin，按档位隔离账目），
  保存/清除/状态行（已录入/未录入语义）/严格模式说明。
- 默认开放模式（门禁关）无 token 功能零门槛不变；严格模式
  （MACFABRIC_ADMIN_REQUIRED=1）下该录入值即管理凭据来源。

## 验证记录

| 项 | 结果 |
|---|---|
| pytest（网关全量 316 项，含新增 7 项桥接单测） | ✅ 316 passed |
| App 契约测试（scripts/test-app-contracts.sh） | ✅ CONTRACT_TESTS_OK |
| 双档构建（build.sh / build.sh --debug） | ✅ exit=0 |
| 发布 tag gateway-v7.10.12 → prod（release-install.sh） | ✅ SMOKE OK |
| 生产 App 晋升（promote-install.sh → /Applications） | ✅ 已重启 |
| 生产 /v1/responses 非流式（fabric-flash 池） | ✅ 200 Responses 形状 |
| 生产旧池名别名 fabric-small → lite 池 | ✅ 200（别名链路生效） |
| 生产流式 SSE（response.created/output_item/delta/completed 序列） | ✅ 事件序正确 |
| 临时冒烟 key 用后即撤销（security.db revoked_at 置位） | ✅ 已撤销 |

## 版本

- 网关：7.10.12（tag gateway-v7.10.12 已推 github）
- commit：199bd4c
