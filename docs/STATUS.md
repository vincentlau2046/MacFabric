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

### 已落地（2026-11-14 凌晨，第一片）

| 项 | 结果 |
|---|---|
| Mac 平台层 `mac_platform.py` | ✅ lsof 端口探测（macOS 无 fuser）、统一内存水位（vm_stat）、预算 B=RAM−8G（`MACFABRIC_RESERVE_MB` 可覆盖） |
| 内存账本 `memory_ledger.py` | ✅ 三规则（R1 准入+人工确认超卖 / R2 resident/on_demand 空闲休眠 / R3 压力安全网）+ 四态生命周期，纯逻辑可单测 |
| 单元测试 | ✅ 19/19 通过（tests/unit/） |
| CUDA 线退役（第一刀） | ✅ `gpu_state._port_pid` 走平台层；`health.gpu_used/total_mb` macOS 映射统一内存口径（total=B 预算，`wait_gpu_free` 语义正确） |
| llama 二进制配置化 | ✅ `LlamaCppConfig.binary_path`；macOS 默认 `~/llama-cpp/build-metal/bin`，Linux 保持上游双目录 |
| model 回显修复 | ✅ `--alias qwen3-4b --jinja`，响应 `model` 字段规范；`enable_thinking:false` 经 chat_template_kwargs 生效 |
| 端到端回归 | ✅ switch 6.1s healthy，OpenAI/Anthropic 双协议仍通 |

### 已落地（第二片：翻译层）

| 项 | 结果 |
|---|---|
| `anthropic_translate.py` 纯翻译层 | ✅ 请求（system/多模态/tools/tool_use/tool_result/tool_choice/stop/stream_options）+ 非流式响应 + 流式 SSE 事件机（thinking/text/tool_use 三类块，增亮聚合） |
| `proxy/anthropic_bridge.py` 桥接 | ✅ 网关内旁路：Anthropic 入口 → OpenAI 上游 → 转回 Anthropic（chunked SSE 写回），不动 forwarder 核心 |
| 配置开关 | ✅ `ModelConfig.anthropic_native`（llama-server=true 透传；vLLM/MLX=false 走桥） |
| Golden replay 测试 | ✅ 用真实 llama-server 双协议录制件（tests/golden/）回放断言事件序列骨架一致 |
| 端到端验证 | ✅ 网关 :8999 打 /v1/messages：native 透传 ✅，translation 桥非流式+流式 ✅（临时翻转开关实测后恢复） |
| 单元测试 | ✅ 31/31 通过 |

### 已落地（第三片：OCR + 打包）

| 项 | 结果 |
|---|---|
| `tools/ocr-helper.swift` | ✅ Vision framework OCR CLI（中英准确级识别），swiftc 编译通过，`--selftest` 冒烟通过（渲染"MacFabric OCR 2026"→识别回读） |
| launchd/uv 打包 | ✅ `scripts/macfabric-gateway.sh`（唯一入口）+ `scripts/install-launchd.sh`（install/uninstall/status，RunAtLoad+KeepAlive 重启自愈）。**未激活**：开机持久化需用户亲自执行 `scripts/install-launchd.sh install` 批准 |
| 最终回归 | ✅ 网关重启后 OpenAI 通道 content 正常返回（"7"），翻译桥/透传双模式均验证过 |

### P1 剩余（低优先，不阻塞 P2）

- cli.py gpu-clear 文案 macOS 化（仅提示文案，无功能影响）
- power_stats macOS 化（功耗曲线，Mac 无 nvidia-smi 口径，需 IOKit 探索）

## P2 原生 App — 🔜 骨架完成（2026-11-14 凌晨）

| 项 | 结果 |
|---|---|
| SwiftUI App（无 Xcode） | ✅ `macfabric-app/build.sh` → swiftc 直编 `build/MacFabric.app`。绕开 CLT 缺 `SwiftUIMacros` 宏插件的硬限制：AppKit 引导（NSStatusItem + NSWindow）承载 SwiftUI，状态集中 ObservableObject + 手动 Binding |
| 界面 | ✅ 菜单栏常驻（网关状态图标）+ 三页：总览（统一内存织物条 + 网关状态）、模型服务（活服务列表）、本地推理（发消息走网关 OpenAI 通道） |
| 数据源 | ✅ `/api/snapshot` 3s 轮询（统一内存口径 B=RAM−8G 已直观呈现：实测 22.9/28.7GB） |
| 冒烟 | ✅ 启动存活、退出干净 |

**启动方式**：`open macfabric-app/build/MacFabric.app`（关窗后菜单栏常驻，菜单栏图标退出）。

### P2 剩余（下一晚）

- 模型池页（池树 + 候选链排序拖拽）、监控台页（Swift Charts 曲线）
- 模型服务页操作（switch/stop 按钮、内存不足弹窗、首启向导）
- DMG 打包在 P4

## P3 能力包 — ⏳ 未开始

## P4 打磨 — ⏳ 未开始


## 2026-11-14 下午补丁 — 停止失效根因修复 + 默认启动设置

### 停止失效（用户报"自动默认启动"的真因）
- `_pkill_by_port` 依赖 Linux `fuser`（macOS 无此命令），fallback pkill 模式只匹配 vllm/sglang → Mac 上"停止"从未真正杀过进程
- 孤儿 llama-server 占着端口 → 网关重启时 `gpu_state.reconcile()` 扫到真实端口收养回 active_services → 表现为"自动启动"
- 修复：darwin 路径走 `lsof -ti tcp:PORT` → SIGTERM → 校验存活再 SIGKILL；杀不掉记 warning
- 实测：停止后 PID 死亡、8010 释放、重启后 active_services=[] ✓

### 默认启动设置（每模型开关，默认不自动启动）
- YAML `autostart: false`（默认）— 独立于 ledger_mode（resident 是"常驻不睡"，autostart 是"开机即起"）
- 网关启动钩子：autostart 模型 best-effort switch（失败只记日志）
- `POST /admin/models/set-autostart {name, enabled}`：改 YAML + 热重载；/models 输出 autostart 字段
- App 本地推理行新增"默认启动"开关
- 全语义闭环实测：false→重启零自启；true→重启自动拉起；关回+停止→保持停止


## 2026-11-14 下午补丁 2 — 能力包"安装"按钮真化（一键下载+装机）

### 根因
- PackCard 的"安装"是空壳 Text（无动作、无端点）——之前的占位未接线

### 实现
- 网关 `POST /admin/packs/download {name,url,filename,model_type_label}`：
  文件在盘→直接装机；不在→后台流式下载（.part 原子改名，进度
  `GET /admin/packs/download-status`），完成后自动 install_model（不启动）
- install_yaml 支持 model_type 标签（embedding/rerank 线色）
- 源逐一 HEAD 验证：bge-m3/bge-reranker(gpustack 417/418MB)、
  qwen3-1.7b/qwen3-vl-4b(lmstudio-community 1.2/2.3GB)
- ASR/TTS 包诚实禁用（"v1.5"，引擎未接）；App 卡片实时进度/重试
- 实测：bge-m3 全链路 下载417MB→装机→/v1/embeddings 返回1024维
  （首请求自动唤醒生效）
