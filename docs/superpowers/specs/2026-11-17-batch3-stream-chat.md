# 批 3：TOP3a — 试聊 SSE 流式 + 停止 + 选模型

日期：2026-11-17 · 状态：已裁决实施（6 项任务清单批 3）

## 问题

审计 TOP3a：试聊是阻塞式非流式（最长 180s 白屏等待）、无法中途停止、
模型自动挑第一个活跃 LLM 无从选择。体验断层：输入→卡住→一次性吐全文。

## 方案

1. **SSE 流式**：POST /v1/chat/completions 带 `"stream": true`，
   URLSession.bytes 逐行读 `data:` 帧，`choices[0].delta.content` 增量拼进回复；
   `data: [DONE]` 终止。网关侧 pipe_stream_response 已支持，零网关改动。
2. **停止**：Task 取消（chatTask.cancel()），停止后保留已到部分 + 如实标注
   「（已停止 — 部分回复）」；busy 复位。UI 发送键旁加停止键（busy 时可用）。
3. **选模型**：活跃 LLM 菜单（Menu），选中记 chatModelID；选中项失活自动
   回退第一个活跃 LLM（不静默选错）。无活跃 LLM 提示不变。
4. **可测性**：SSE 行解析（SSEParser.delta）、目标模型选择
   （ChatTargetPicker.pick）、停止收尾文案（ChatStop.finalText）抽为纯函数
   入 GatewayClient.swift，契约测试可钉；UI/Task 编排留在 main.swift。

## 边界

- 网关零改动（SSE 透传既有）；推理鉴权沿用 InferenceRequestAuthorizer；
- 错误提示沿用批 1 语义（401/403 → 鉴权指引，不误导装模型）；
- 思考模型吃满预算无正文 → 如实提示（沿用现状文案语义）。

## 验收

1. 契约测试新增 SSE 解析/选模型/停止文案断言，全过；
2. 双档构建 exit 0；
3. dev e2e：真实流式请求逐字到达 + 停止保留部分回复（需 dev 网关 + 活跃模型）；
4. QA 落 docs/qa/batch3-stream-chat.md。
