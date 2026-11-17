# 批 3 QA 记录 — TOP3a：试聊 SSE 流式 + 停止 + 选模型

日期：2026-11-17 · spec：docs/superpowers/specs/2026-11-17-batch3-stream-chat.md

## 改动清单

| 项 | 实现 |
|---|---|
| SSE 流式 | sendPrompt 重写：stream:true + URLSession.bytes 逐行 + SSEParser 增量拼帧 |
| 停止 | chatTask.cancel()；部分回复保留 + 如实标注（ChatStop.finalText） |
| 选模型 | 活跃 LLM 菜单（chatModelID）；选中失活回退首个活跃 LLM（ChatTargetPicker） |
| 可测性 | SSEParser / ChatTargetPicker / ChatStop 纯函数入 GatewayClient.swift |
| 错误语义 | 401/403 → 鉴权指引（不误导装模型）；非 2xx 读 body 前 160B 详情 |

## 验证证据

1. 契约测试 102 断言全过（新增 12：SSE 6 + 选模型 4 + 停止 2）——
   sseDeltaContent / sseRoleFirstFrameNil / sseDoneFrame / sseCommentIgnored /
   sseMalformedFrameHonest / sseUsageTailFrameNil；chatTarget 四态；chatStop 两态；
2. 双档构建 exit 0（--debug 与正式）；
3. dev e2e（:8998，glm-5 云端流式）：真实 SSE 管道逐帧到达——
   role 首帧 → delta.content 增量（收到）→ finish_reason:stop → usage 尾帧，
   与 SSEParser 解析契约一一对应；本地 LLM 未装载，dev 池路由云端验证同一管道；
4. 网关零改动（pipe_stream_response 既有能力，未触碰网关代码）。

## 已知边界

- 人工「逐字滚屏」视觉验收待 TCC 截图权限路径裁决后补（与截图矩阵同根源）；
- 停止按钮在本地大模型首 token 前取消，网关侧行为为断开连接（上游自行终止），
  App 侧保留空部分 → 「（已停止 — 未收到内容）」如实呈现；
- chatModelID 持久化未做（会话内有效），跨启动记忆属批 4 走查范畴。
