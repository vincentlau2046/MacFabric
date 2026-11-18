# 批 6 — Admin Token 存储迁移（钥匙串 → 本机受控文件）

日期：2026-11-18

## 问题（用户视角）

正式版 App 反复弹出 macOS 登录密码框（钥匙串授权），读取
io.macfabric.gateway-admin 条目。原因：Admin Token 存在登录钥匙串，
而 App 每次发布都是 swiftc 重新编译 + adhoc 签名，macOS 视新签名为
陌生程序，旧的"始终允许"授权全部作废；3 秒控制面轮询把一次性授权
放大为反复抢占。

## 用户裁决

- 弹窗不可接受，清理掉（2026-11-18）。
- 默认模式零触碰：Admin Token 是可选凭据，不得进入默认请求路径。
- 存储语义不变：仅设置页主动录入后才有用户配置的 token；网关侧
  secrets.env 自动生成的备用 token 仍为软件默认（固定位置自动读取）。

## 实现

- 新增 FileCredentialStore（macfabric-app/Sources/AdminTokenFileStore.swift）：
  ~/Library/Application Support/MacFabric/admin-token-<profile>.token，
  目录 0700 / 文件 0600，先写临时文件再原子替换。
- AdminTokenCredentialStore 改挂 FileCredentialStore；钥匙串 service
  常量保留为 legacyKeychainService（仅清理/兼容提示用）。
- 设置页文案同步：不再声称"存进钥匙串"。
- 登录钥匙串中 2 条 io.macfabric.gateway-admin 旧条目已删除（prod/dev）。

## 验证

- App 契约测试全过（含新 adminLegacyServiceConstant 断言）。
- 正式版构建 + promote-install.sh 晋升成功，App 正常读取 :8999 状态（200）。
- 钥匙串查询确认条目清零；推理 key 条目（io.macfabric.gateway-api-key）
  从未写入过，不受影响。

## 遗留说明

推理 API key 仍走钥匙串（KeychainCredentialStore）。当前无已存条目、
不触发弹窗；若未来用户在设置页保存推理 key，adhoc 重签后同样会出现
读取授权弹窗，届时应一并迁移到文件存储（未授权，仅备查）。
