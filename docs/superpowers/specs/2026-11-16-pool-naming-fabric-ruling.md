# 裁决记录 — 模型池逻辑名前缀 iff/ → fabric-（硬切）

日期：2026-11-16 · 裁决人：用户 · 方案：B（硬切，不留 iff/ 别名）

## 背景

逻辑池对外模型名为 `iff/<池名>`（InferFabric 时代遗产）。slash 命名在部分
客户端 SDK/工具上有兼容问题（model 字段被当路径段处理）。用户提出改用
`fabric-` 前缀；备选 A（双前缀过渡）/ B（硬切）中用户裁决 B：单用户场景，
自己改调用方即可，避免保留技术债。

## 裁决内容

- `POOL_PREFIX = "fabric-"`，全链路只认新前缀；`iff/` 不再识别为池
  （按普通模型名走直连/云路径 → 404/直连语义）。
- 调用方示例：`iff/fast` → `fabric-fast`，`iff/small` → `fabric-small`，
  `iff/premium` → `fabric-premium`。

## 改造面（已完成）

| 层 | 文件 | 改动 |
|---|---|---|
| 路由核心 | model_pool/dispatch.py | POOL_PREFIX 常量 + docstring |
| 池入口 | proxy/chat_handlers.py、proxy/handler.py | startswith 检查 2 处 |
| 池校验 | model_pool/config.py | 禁池引用池前缀 + 错误文案 |
| 安全层 | security/admin.py、security/auth_facade.py | key 池作用域签发校验 / 匿名访问触发判断（同一套 API key，机制不变，仅作用域字符串跟名） |
| App | MacFabricApp.swift | 16 处文案/示例 |
| Dashboard | model-pools.js / model-pools.html | 11 处 |
| 文档 | docs/PLAN.md、STATUS.md、FEATURES.md、qa/monitor-pools-v2.md | 同步 |

## 边界核查（免返工事实）

- `model_pools.yaml` 存裸池名，前缀运行时拼接 → **无数据迁移**。
- `security.db` api_keys 表为空 → **无存量 key 作用域迁移**。
- `IFF_DATA_DIR`/`IFF_CONSOLE_ORIGINS` 等内部环境变量与模型名无关 → 不动。
- 池名与本地模型撞名会被池路由遮蔽（现有无撞名；池名校验另立项）。

## 测试

- 新增 test_pool_prefix_fabric.py：新前缀识别 / iff/ 硬切 / 禁池自引用。
- 既有池测试 19 处 `iff/` → `fabric-` 同步；全套 250/250 绿；App build.sh 过。
