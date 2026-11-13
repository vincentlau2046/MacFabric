# MacFabric 实施状态日志

> 供晨间校验用。按 PLAN.md 里程碑推进，每阶段完成后更新本文件。

## P0 内核跑通 — ✅ 完成（2026-11-14 凌晨）

### 验收结果（全部实测通过）

| 项 | 结果 |
|---|---|
| 网关核心 macOS 启动 | ✅ :8999，10 项 DB migration 全部应用，无 CUDA 依赖报错 |
| Metal 推理引擎 | ✅ llama.cpp b12361 (arm64 Metal)，Qwen3-4B Q4_K_M，`-ngl 99` 全量 offload |
| 模型加载 | ✅ `switch qwen3-4b` 约 3~6s 转 healthy |
| OpenAI 协议 `/v1/chat/completions` | ✅ 非流式 + 流式（SSE chunk）均正确 |
| Anthropic 协议 `/v1/messages` | ✅ 非流式 + 流式均正确，含 thinking 块（llama-server 原生支持，免翻译层） |
| 分叉包 `macfabric_gateway/` | ✅ 已建立，含 Mac P0 补丁，vendor 回归纯参考 |

### 关键改动

1. **建立 Mac 分叉包 `macfabric_gateway/inferfabric/`**（自 vendor 拷贝，P1 起在此演进；vendor/ 只读参考、已 gitignore）。
2. **MacFabric P0 补丁** `proxy/chat_handlers.py`：`is_llama_cpp` 聊天请求不再误路由到 Ollama 原生通道（上游 llama.cpp 只跑 embedding/rerank 所以聊天路径从未触达；Mac 上 llama_cpp = llama-server 是对话主力），改走标准上游转发。仅真 Ollama 模型走 `handle_ollama_native`。
3. **零改动 Metal 集成**（临时 workaround，P1 收编）：symlink `~/llama-cpp/build-cuda/bin/llama-server` → `engines/llama-b12361/llama-server`，绕开 process_manager 中硬编码的 CUDA 构建路径。
4. 模型基线 `macfabric_gateway/models.d/qwen3-4b.yaml`（P1 起迁移为 mem_baseline_mb/mode/idle_timeout_min 三字段账本模型）。

### 已知遗留（记入 P1）

- `model` 字段回显 GGUF 绝对路径（llama-server 行为）——P1 设 `served_name` 规范化。
- llama-server 二进制路径硬编码 —— P1 增加配置字段 + Metal 构建为第一公民。
- Anthropic→OpenAI 翻译层：P0 依赖 llama-server 原生 /v1/messages 透传；P1 按计划补翻译层（覆盖 vLLM/MLX 等无原生能力的引擎）+ Claude Code golden replay 测试。

## P1 内核 Mac 化 — 🔜 进行中

## P2 原生 App — ⏳ 未开始

## P3 能力包 — ⏳ 未开始

## P4 打磨 — ⏳ 未开始
