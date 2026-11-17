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
