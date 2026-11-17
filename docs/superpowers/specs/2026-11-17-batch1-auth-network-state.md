# 批 1：TOP1 控制面鉴权 + TOP2 统一网络层 + TOP5 状态可信（spec 2026-11-17）

> 用户裁决 2026-11-17：born-token 键名采用**单键名 MACFABRIC_ADMIN_TOKEN，值按环境解耦**——
> 生产写入 ~/.inferfabric/secrets.env，调试写入 ~/.inferfabric-dev/secrets.env
>（状态目录本就隔离，同键名不同文件不同值）；dev 实例 8998 同批 token 化，全量启用无灰度。
> 审计上下文：docs/HANDOVER-2026-11-17-full-audit.md（TOP1/2/5）；用户裁决 memory audit-2026-11-17-rulings。

## 事实基线（2026-11-17 核实）

- 网关已有 `IFF_ADMIN_TOKEN` env + `X-Admin-Token` 校验骨架（handler.py:52, _check_admin），
  但语义是**未配置 = 放行**（fail-open）——TOP1 核心。
- `SecretsManager` 默认路径硬编码 `~/.inferfabric/secrets.env`（cloud_discovery.py:158），
  **不跟随 MACFABRIC_STATE_DIR**——调试网关写云厂商 key 会漏进生产文件（既有隔离缺陷，本批修）。
- SecurityAdmin（/admin/keys console）已有 Host/Origin 白名单校验；散装 admin 路由没有。
- 生产网关只吃发布产物（红线）——本批生产零接触，dev 8998 + 测试层验证，发布由用户协调 release 流程。

## 设计

### 网关侧（macfabric_gateway）

1. **Secrets 路径跟随状态目录**：CloudDiscovery 用 config_path.parent/secrets.env
   构造 SecretsManager（替代默认硬编码）。dev（MACFABRIC_STATE_DIR=~/.inferfabric-dev）
   → ~/.inferfabric-dev/secrets.env；生产路径行为不变。
2. **born-token**：网关启动入口最先执行——读 secrets.env 的 MACFABRIC_ADMIN_TOKEN；
   缺失则 secrets.token_urlsafe(32) 生成并写回（600）；随后设置 IFF_ADMIN_TOKEN 生效。
   token 轮换语义：用户改 secrets.env 值 → 重启网关生效（启动时读，不缓存旧值）。
3. **fail-closed**：_check_admin 未配置 token → 401（born-token 保证正常运行时恒有值）；
   _validate_admin_token_safety 空 token 从 warn 改 RuntimeError（双保险）。
4. **admin 全路由套 _check_admin**：/admin/*（cloud/packs/security/metrics/models 管理操作等）
   未带有效 X-Admin-Token → 401。/v1/* 推理面不在此批（既有 SecurityAuth policy 机制）。
5. **Host/Origin 校验**：_check_admin 增加 Host 必须 loopback:port（PROXY_HOST 为回环时）；
   非 GET 且携带 Origin 头时必须为同源回环（原生 App 不发 Origin；浏览器跨站被拒）。
6. **CORS 收紧**：admin 端点响应不发 Access-Control-Allow-*；do_OPTIONS 对 admin 路径
   204 但不发 ACAO:*。推理面（/v1/*）的 ACAO 本批不动。

### App 侧（macfabric-app）

7. **GatewayClient（TOP2 统一网络层）**：新文件 Sources/GatewayClient.swift——
   泛型 get/post、自动分流注入（/v1/* → Authorization Bearer 推理 key；
   /admin/* → X-Admin-Token）、错误分类（offline/http(code)/unauthorized/malformed）、
   代际防乱序、超时统一。admin 调用面（18 处散装 URLRequest）迁移至 GatewayClient。
8. **admin token 凭据**：KeychainCredentialStore 支持 service 注入；
   admin token 用独立 service `io.macfabric.gateway-admin`（account=profile，
   与推理 key 的 `io.macfabric.gateway-api-key` 账目隔离）。
9. **born 迁移（读一次转 Keychain，不每次读盘）**：Keychain 无 admin token 时读
   secrets.env（路径随档位：prod ~/.inferfabric / dev ~/.inferfabric-dev）→ 转存 Keychain；
   失败如实呈现"凭据未就绪"，绝不假装已配置。
10. **TOP5 状态可信**：错误反馈持久化（不再 5s 自灭；新成功或用户清除才消失）；
    轮询失败不清空既有成功数据、不离线页误标"暂无数据"（统一 lastError 数据面 + 空态三态：
    有数据/离线/空）。

### 脚本侧

11. release-install.sh 冒烟 curl 从 secrets.env 读 token 注入 X-Admin-Token；
    dev-gateway.sh 同理（或依赖网关自 born）。

## 语义红线

- 生产网关本批零接触（不 bootout/restart/写生产 DB）；所有验证走 8998 + pytest + 契约测试。
- token 明文不进 git/日志/文档；示例用占位符。
- App 不把 admin token 用于推理注入；推理 key 不用于 admin（两本账目严格分离）。

## 验收（TDD）

- 网关 pytest 新增：secrets 路径派生随 config_path、born-token 生成/读取幂等、
  _check_admin fail-closed、Host/Origin 校验（跨站 Origin 403、无 Origin 放行、
  非回环 Host 403）、admin 401 面覆盖。
- App 契约测试新增：GatewayClient 注入分流/错误分类/代际防乱序、admin token 迁移
  （读文件成功→Keychain；文件缺失→诚实未就绪）、Keychain service 双账目隔离。
- dev e2e：重启 dev 网关（:8998）→ 无 token curl 401 → 带 token 200 →
  dev App 设置页/云端页正常（token 自动迁移）→ 生产 :8999 全程 200 不受影响。
- 调试/正式档构建 exit=0；QA 落盘 docs/qa/。

## 范围外

- /v1/* 推理面 CORS 与浏览器策略（后续批次评估）
- 生产发布与重启（用户协调 release 流程后单独执行）
