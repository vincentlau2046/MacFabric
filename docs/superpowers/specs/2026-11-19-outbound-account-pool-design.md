# 出站账号池设计（F6 占位，2026-11-19）

状态：**占位设计，未实现账号池**。本期只交付 `inferfabric/outbound_credentials.py`
的恒等透传接口（`select_outbound_api_key`）+ forwarder 单点接线；
本文描述未来演进方向，行为均需另立评审，不预先冻结实现细节。

## 1. 三层分清（与 F7 / 模型池的边界）

| 层 | 职责 | 代码位置 | key 方向 |
|---|---|---|---|
| F7 入站鉴权 | 验证调用客户端的 IFF key（摘要存储、撤销/过期、模型 scope） | `inferfabric/security/key_store.py` | 入站（客户端 → IFF） |
| 模型池 | 选模型 / 物理目标（本地引擎 or 云 provider+model） | `inferfabric/model_pool/*` | 不涉及账号 |
| **F6 出站选账号** | 决定 IFF 用哪个云账号调云端 provider | `inferfabric/outbound_credentials.py` | 出站（IFF → 云） |

两种 key 绝不互传：入站 F7 key 不出站，出站云 key 不下发客户端；
`select_outbound_api_key` 的参数面固定为 `{provider_name, configured_api_key}`
（test_selector_signature_is_keyword_no_extras 钉住），入站标记无入口。

## 2. 当前接入点（已接线，行为不变）

- `forwarder.forward_to_cloud`：协议能力/端点校验通过后、首次组装鉴权
  header 前调用一次；Chat Completions 与 Anthropic Messages 双协议共享；
  重试沿用首次选定值（headers 在重试循环外组装）。
- 默认实现恒等透传：出站 key、请求路径、重试次数、空 key header 语义
  与既有行为逐字节一致（test_outbound_credentials.py 全绿 + 既有回归）。
- **本期不迁移**：responses_bridge 原生探测 / Chat 兜底、discovery、
  管理探测 — 各自有独立出站装配，迁移另立任务。

## 3. 未来可选方向（均需另立评审）

1. **配额路由**：按 provider 侧配额/余量在多个 `api_key` 间选择；
   需要配额观测源（响应头/管理 API）与降级策略。
2. **账号隔离**：不同账号绑定不同模型 scope/端点指纹；需与
   `cloud_provider.yaml` 的 provider 结构共同演进（配置键不动现有语义）。
3. **会话亲和**：同会话粘住同账号，避免服务端缓存/限速状态分裂；
   需定义会话标识来源与失效边界。

## 4. 硬约束（沿用至任何后续实现）

- **同一次 attempt 内不换 key**：选定值在整次转发（含重试）中不变 —
  换 key 即换重试语义，属行为变更。
- **跨账号重放**：已 committed（响应已开始输出）后失败不可重放、不可
  换账号重试（§6.4 既有边界，forwarder 已钉）。
- 不读取会话内容、不做遥测上报；失败可见（fail visible），不静默换道。
- 空 key：既有 header 语义保持（Bearer 空 / x-api-key 空），选择器不得
  把空 key 替换为任何默认值。
