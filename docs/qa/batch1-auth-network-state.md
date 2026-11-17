# 批 1 QA 记录 — TOP1 控制面鉴权 + TOP2 统一网络层 + TOP5 状态可信（2026-11-17）

Spec: docs/superpowers/specs/2026-11-17-batch1-auth-network-state.md（用户裁决：单键名
MACFABRIC_ADMIN_TOKEN，值按状态目录解耦；dev 8998 全量 token 化无灰度）。

## 验证结果

| 层 | 验证 | 结果 |
|---|---|---|
| 网关单测 | pytest tests/ 全量 | 289 passed（含批 1 admin auth 12 项：born-token 幂等/env 优先/fail-closed/Host·Origin） |
| App 契约 | scripts/test-app-contracts.sh | 90 断言全过（组 24：双账目 service 隔离 / born 迁移四态 / 注入分流 / 代际防乱序） |
| App 构建 | build.sh --debug 与 build.sh | 双档 exit=0 |
| dev e2e :8998 | born-token 全链路（下方证据） | 全过 |

## dev e2e 证据（:8998，状态 ~/.inferfabric-dev）

```
health=200
no_token_catalog=401          # fail-closed：无 token 拒绝
no_token_switch=401           # 顶层控制路由同门禁
bad_token=401                 # 错 token 拒绝
host_spoof=401                # 伪造 Host 拒绝（token 亦无）
valid_token_spoofed_host=403  # 有效 token + 伪造 Host → 403（Host 校验）
with_token_catalog=200
with_token_pools=200
admin_options_acao_headers: 0 # admin OPTIONS 不发 ACAO:*
v1_options_acao_present: 1    # 推理面 CORS 保持原状
prod_untouched=200            # 生产 :8999 全程零接触、健康
```

born-token 写回 `~/.inferfabric-dev/secrets.env`，权限 600，键名 MACFABRIC_ADMIN_TOKEN；
生产侧同键名在 `~/.inferfabric/secrets.env`（值不同，按状态目录隔离）。

## 本批修复的既有缺陷（超出原 TOP 清单）

1. **App 测试基建盲区**：契约测试失败汇总在文件中部执行，后置断言失败不显示且 exit 0 —
   组 24 两条 born 迁移断言曾静默未过。已把汇总移到文件末尾。
2. **Keychain 账目写丢**：GatewayCredentialStore 协议为 mutating，值类型拷贝后写副本
   （m1=migrated 但账目空、幂等检查失效）。协议改非 mutating + 测试账目改引用语义，
   契约测试从 88 条真实执行增至 90 条。
3. **批 0 遗留编译错误**：main.swift（daemon enable 路径）NSString/createDirectory/guard
   贯穿 + packDetailFields 未定义标识符 — 契约测试不编 main.swift 所以批 0 未暴露，
   本批双档构建强制暴露并修复。
4. **网关 CORS 过宽**：send_json/do_OPTIONS 对 /admin/* 不再发 Access-Control-Allow-*。

## 环境状态

- 生产 :8999（launchd）全程未动（红线遵守：无 bootout/restart/写生产 DB）。
- dev :8998 由 scripts/dev-gateway.sh 拉起（验证期存活；会话结束即停，随用随起）。
- 验证前发现 :8998 残留一个旧 QA 沙箱实例（MACFABRIC_STATE_DIR=~/.inferfabric-sandbox，
  旧代码），已按 PID 精确终止（非全局 pkill）。

## 语义修订（用户裁决 2026-11-17 晚）：门禁默认翻转 + 池名 v2

### 1. 管理面鉴权默认关闭（默认开放回环）

生产 App 报障「管理凭据未就绪 (401)— 重启 App 重试 born 迁移」根因：发布重启时
secrets.env 的 MACFABRIC_ADMIN_TOKEN 轮换（20:43:08），App Keychain 存的旧 token
未同步（born 迁移只在 Keychain 为空时读文件），attachAdminToken 见 Keychain 非空
即沿用 → token 失配 401。本地回环网关的使用门槛不应由管理 token 构成。

语义翻转（用户裁决：API-KEY 是云请求认证路径，不是软件功能门槛；默认体验优先）：

- **默认**（未设 MACFABRIC_ADMIN_REQUIRED）：管理面不做 token 校验；Host/Origin
  校验保留（防 DNS rebinding / 浏览器跨站，与开关无关恒生效）。
- **严格模式**：显式 MACFABRIC_ADMIN_REQUIRED=1/true/yes/on 启用；原 fail-closed
  逻辑完整保留（无 token / 错 token 401；空 token 拒绝启动）。
- 默认模式空 token 只告警不阻断启动（born-token 仍会生成备用值）。
- App：迁移失败后非严格模式不再拦截本机管理动作；17 处「管理凭据未就绪」
  文案改为严格模式语境。

### 2. 池名 v2：flash / lite / max（旧名保留入站别名）

用户裁决：更贴合中国模型档位命名。

| 旧名（入站别名，仍可调用） | 新名（正名，配置/界面/日志） |
|---|---|
| fabric-fast | fabric-flash |
| fabric-small | fabric-lite |
| fabric-premium | fabric-max |

- 网关 dispatch 加 canonical_pool_name：旧名解析到新池（日志/摘要记新名），
  已分发客户端（AtlasCode 实测 fabric-small/fast 在用）升级不断流。
- 配置键（model_pools.yaml pools.*）、dashboard 角色、App 池卡/调用示例全部切新名。
- API key 模型作用域按对外名匹配：旧 key 只在走旧别名入站时鉴权用旧名，
  建议升级后重建 key（or 直接用新名调用）。

### 验证（本次修订后）

| 层 | 验证 | 结果 |
|---|---|---|
| 网关单测 | pytest tests/（309 项） | 全过（含别名解析、门禁翻转 15 项） |
| App 契约 | scripts/test-app-contracts.sh | 111 PASS（含 adminAuthPolicyDefaultOff） |
| 双档构建 | build.sh --debug / build.sh | exit=0 |
