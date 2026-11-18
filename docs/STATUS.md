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

## P2 原生 App — ❌ 已整体删除（2026-11-18 D17 裁决；下文 2026-11-14 的 ✅ 记录为历史存档，不再代表现状。功能由 Web Dashboard 承接，映射见 specs/2026-11-18-python-gateway-refocus-design.md §6.3）

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

## 2026-11-14 下午补丁 3 — O 批次（agent 输入输出模型）+ 隔离 + 图标

### OCR（零模型方案）
- `POST /ocr {image_path}`：macOS Vision 框架（tools/ocr-helper，只读调用系统能力）
- 不下任何模型、不吃内存账本 — 端侧 OCR 的 Metal 时代最优解

### TTS（已落地、实测通过）
- 引擎：kokoro-onnx v1.1-zh（82M ONNX CPU），venv 隔离在 engines/kokoro/
- `engines/kokoro/server.py`：OpenAI 兼容 /v1/audio/speech → WAV 24kHz
  （中文音色 zf_001；lang 码修正 cmn 而非 zh — espeak backend 约束）
- `models.d/kokoro-82m.yaml`：tts_server 块 + on_demand；经 :8999/v1/audio/speech
  网关转发实测中英双语 RIFF WAV

### 环境隔离（用户要求：不影响 macOS 系统层面）
- docs/ISOLATION.md：Docker 否决理由（macOS Docker=Linux VM，无 Metal 直通，
  推理慢 5–15 倍 + 双倍内存与账本冲突）→ 用户态自包含（engines/ 独立二进制与 venv）
- TTSConfig/ASRConfig 新增 `python_bin` 显式路径字段（process manager 不再探测 conda）；
  移除 ~/miniconda3/kokoro symlink；系统级安装为零

### 云端接入 UI（用户四问收口）
- 统一转换出口**早已实现**（anthropic_translate 桥 + :8999/v1/messages）；缺的是表单字段
- 添加服务商表单新增「Anthropic Base URL（可选，原生直连）」→ POST anthropic_base
- 服务商卡：OAI/ANT 原生 chip + 「拷贝配置」按钮（双协议统一入口 env 块进剪贴板）
- 模型 curation 行：OAI / ANT 原生 chip（网关 model_specs 新增 anthropic 字段，
  与注册表 anthropic_available 同源 = bool(cfg.anthropic_base)）

### 模型池修复（用户报告三项）
- 顺序调整失效根因：App 缓存 _poolsRawCache 陈旧 → mutatePools 改为每次变更
  fresh GET raw + expected_revision CAS
- 候选「换模型」Menu（云端已启用模型任选）+ 移除 + ↑↓ + ＋添加候选
- 协议/VL 标签修正：OAI/ANT 按 anthropic_native（本地）/anthropic_base（云），
  VL 按 model_type/supports_vision 真数据

### macOS 进程停止真化
- `_pkill_by_port_macos`：lsof 定位 PID → SIGTERM → 校验 → SIGKILL
  （原 fuser 是 Linux 命令，Mac 上静默失效导致孤儿进程被 reconcile 收养成"假自启"）

### App 图标（用户要求：告别空白图标）
- scripts/make-icon.swift：CoreGraphics 矢量绘制 — 深蓝 squircle + 四色渐变
  编织线（fabric 意象）+ 中央芯片轮廓 + 发光枢纽（统一入口）→ iconset → icns
- build.sh 接线 CFBundleIconFile + Resources/AppIcon.icns；Dock 已生效

### 待办
- ASR：engines/whisper/build-server.sh 就绪（Claude Code 权限分类器拦截执行），
  用户运行后 → whisper ggml-large-v3-turbo 下载 → models.d yaml → ASR 能力包解禁

## 2026-11-14 下午补丁 4 — 隔离成为部署底层范式 + 池候选联动 + ASR 端到端

### 部署范式化（用户裁决：所有部署方式统一，存量已审计合规）
- 卸载=容器化拆除：停服务→删yaml→热重载→删模型文件（仅项目 models/）→
  引擎单元引用计数归零整目录 rmtree → 池候选联动清除；响应带清理审计字段
- `_collect_engine_refs`：dataclass 递归收集绝对/相对路径，engines/<unit> 归属判定
- 范式文档化：docs/ISOLATION.md 第四章（三单元生命周期表 + 验收标准）
- 存量审计：bge-m3/qwen3-4b/kokoro 三 yaml 全部合规（项目内模型+引擎+显式路径）

### 模型池 ↔ 源模块自动联动（用户要求）
- `PoolRegistry.purge_candidates(predicate)`：RLock 重入复用 update() 校验+
  原子写盘+发布路径；无命中不写盘；单测覆盖（local清除/provider清除/无操作/持久化）
- 挂钩三处：pack 卸载（local 候选）、云模型 remove（provider+model_id）、
  provider 删除（该 provider 全部云候选）

### 池候选 schema 修复（用户截图的 400 根因）
- 加候选/换候选此前写 `target` 字段（网关不认识）→ cloud 必须 provider+model_id，
  local 必须 model_name；换候选保留原 id（身份稳定）；加候选 id 唯一化
- 实测：add/replace/remove 三链路 200，终态校验通过
- 替换/移除挂 NSAlert 确认弹窗（用户裁决：只拦确认，不校验可用性 —
  可用性是本地推理/云端接入模块的职责）；↑↓ 非破坏性直接执行

### ASR 能力包端到端（不再依赖手工构建）
- `/admin/packs/download` 新增 engine 阶段：engine=whisper → 项目内构建
  whisper-server（engines/_tools 内置 cmake，Metal）→ 下载 ggml-large-v3-turbo
  → 写 asr_server yaml（python_bin=二进制路径显式声明，OpenAI 兼容
  /v1/audio/transcriptions）→ 热重载；进度状态 building/downloading/installing
- App 卡片接线：ASR 从"v1.5 待接入"转为可安装，构建阶段实时文案
- 注：端到端触发验证被 Claude Code 权限分类器拦截（下载+构建动作），
  功能已接线，待用户在 App 内点击安装验证全链路

### 图标（上条补丁遗漏记录）
- scripts/make-icon.swift CoreGraphics 绘制 → AppIcon.icns，Dock 生效

## 2026-11-14 晚间补丁 — 安装版/调试版分离（用户裁决）

- 双档位：安装版(/Applications, :8999, ~/.inferfabric) vs 调试版(build/MacFabric-dev.app,
  :8998, ~/.inferfabric-dev)，bundle id/显示名/状态目录/模型配置全隔离
- 网关：MACFABRIC_STATE_DIR / MACFABRIC_MODELS_DIR 环境变量覆盖（默认零变化）
- App：build.sh --debug 写 DEV_PROFILE 标记 → 全局 GW_PORT/GW_BASE（21 处调用面）
- 配置：dev-gateway.sh 首次一次性快照复制安装版配置；promote-install.sh 晋升流程
- 实测：双网关并行 8998/8999 双 200；调试版配置快照含 qianfan；
  MacFabric-dev.app 进程与 :8998 ESTABLISHED；安装版状态目录零污染
- 文档：docs/DEV-INSTALL-SEPARATION.md

## 2026-11-14 晚间补丁 2 — 千帆接入 + Anthropic 双约定
- qianfan 服务商（双协议端点+key），glm-5.3/deepseek-v4.1-flash 手填
- forwarder 修 Anthropic 路径拼接：base 尾带 /v1 拼 /messages，裸 base 拼 /v1/messages
- 双协议经 :8999 实测：glm-5.3（openai）、deepseek-v4.1-flash（anthropic 原生直连）

## 2026-11-14 深夜补丁 3 — Atlaswork 接入 + 云路由三缺陷修复 + 网关守护

- atlaswork 服务商接入安装版（双协议同 base 尾带 /v1）：发现 6 模型，
  按用户裁决启用 4 个（Qwen38-27B-VL / glm-5 / gpt-6.1-sol / kimi/k3.1-pro；
  glm-5.3 与 deepseek-v4.1-flash 归千帆，且 atlaswork 上游不允许其走 anthropic）
- 缺陷1 斜杠模型 404：注册表短名查表用 split("/")[-1]，kimi/k3.1-pro 两种
  形态全查不中 → CloudDiscovery.resolve_cloud_model 按条目精确比对，
  handler(:8999 messages) 与 chat_handlers(:8998 chat) 两处调用点统一换用
- 缺陷2 floor 兜底被吞：provider 列表瞬态失败时其 spec 模型短键被先发现
  者占用后连前缀键都不注册 → _register_spec_only_models 短键占用时仍补注册
  "provider/model" 前缀键
- 缺陷3 前缀请求被劫持：resolve_route 短名优先于全名，多 provider 同名时
  "qianfan/glm-5.3" 可能路由到他家的 atlaswork → 改全名优先
- 隔离漏洞：handler/async_server 日志目录硬编码 ~/.inferfabric/logs →
  改用 DEFAULT_LOG_DIR（跟随 MACFABRIC_STATE_DIR，调试版不再污染安装版日志）
- 网关守护：scripts/gateway-launchd.sh（com.macfabric.gateway LaunchAgent，
  KeepAlive=true 进程死 10s 拉起 + 开机自启；仅管安装版 :8999，调试版仍手工）
  — 安装执行待用户放行持久化权限
- 实测（:8999 全量）：atlaswork 4 模型双协议 200；qianfan/glm-5.3 floor 场景
  200；atlaswork/glm-5.3 移除后干净 404；Qwen38-27B-VL 上游 502（服务方问题，
  保留观察）

## 2026-11-14 深夜补丁 4 — VL 打标可见性修复（用户反馈：找不到在哪加 VL 标签）
- 根因：发现模型 enable 只进白名单不建 model_specs，云端接入页模型列表
  只渲染 specs → 已启用模型整行隐身，VL 打标按钮无从触达
- 修复：UI 策展行 = specs ∪ 已启用未建 spec（合成行，含 anthropic 协议标记）；
  点「标 VL」走 tag 动作即落真 spec（spec 缺失时网关本就自动创建）
- 顺带：_merge_model_spec 查找兜底短名键（落盘后 spec key=短名，含斜杠
  模型重启后打标属性漏合并）
- 池调度侧已有 VL 感知（无需改）：selector 排序键把 vision 请求的
  supports_vision 候选软优先（云模型读注册表 supports_vision，本地读
  model_type==vl），无 VL 配置时按优先级正常调度

## 2026-11-14 深夜补丁 5 — 池页云端候选菜单同源修复（用户反馈：模型池无法添加）
- 同一根因的第二入口：池页「＋ 添加候选 → 云端」菜单 cloudChoices 也只列
  model_specs → atlaswork 启用未建 spec 的模型全部缺席（API 直加 200 正常，
  纯 UI 数据源问题）
- 修复：cloudChoices = specs ∪ enabled_models（去重，kimi/k3.1-pro 前缀拆分
  正确）→ 晋升安装版

## 2026-11-14 深夜补丁 6 — 网关守护上线（用户批准执行）
- scripts/gateway-launchd.sh install 成功（com.macfabric.gateway，KeepAlive+自启）
- 修复脚本 bug：$LABEL 后跟全角括号被 bash 吞进变量名 → ${LABEL}
- 端到端实测：杀网关进程 → 3s 离线（ThrottleInterval 窗口）→ 12s 自动拉起
  （pid 26498→26534）→ :8999 恢复 200；"一杀就永久离线"根因闭环

## 2026-11-15 夜间审计轮 1-7（用户通宵授权：功能/性能/UX 三角度，≥10 轮）
- R1 端点核实（曲线/预设 200）+ 池行 anthropic 徽章 + 工具打标 + 跨池同候选校验移除
- R2 池页：云端候选状态点按注册表点亮 + 空池指引
- R3 云端页：发现超时 150s 防误报 + ANT/OAI 简写残留清零
- R4 本地推理：qwen3-4b 全生命周期实测（启动/双协议对话/睡眠/唤醒/停止）全过
- R5 能力包：ASR 包端到端装机实测（cmake 引擎构建→1.6GB 下载→写配置→
  首个请求自动唤醒→真实转写 200）；/v1/audio/transcriptions 补自动唤醒通道
- R6 监控台：指标表窄窗口横向滚动
- R7/R11 light 主题默认：NSApp.aqua + 全 token 翻转 + 12 处白叠加改黑叠 + 线色加深
- R8 性能：主窗口关闭即暂停 3s/30s 轮询（菜单栏常驻不再空转打点）
- R9 UX：反馈横幅 5s 消退、双击确认 6s 复位、busy 防抖给提示不静默、
  试聊动态选活跃 LLM + 思考模型空回复如实提示
- R10 终版回归 18/18（池 CAS/跨池候选/云端策展/幂等删除/本地/监控/能力包/
  双协议入口含斜杠模型与 qianfan 前缀）

## 2026-11-15 专项交付（Task #12）：云端模型属性浮窗 + 池拖拽排序 + 鉴权使能 — 2b5fb1d
- **云端模型属性浮窗**：模型行点开 sheet — VL/工具 toggle + 上下文窗口/最大输出/输入输出价格编辑 + 单独删除（两击确认）。
  网关 `update_model_spec` 扩展接受 context_window/max_output_tokens(int)、price_input/price_output(float)（None=清除）；
  `model_specs`/`routable_caps` 序列化透传属性供浮窗回填。实测：tag 带属性 200 → 回读一致 → NSNull 清除生效。
- **池排序根因修复**：↑↓ 旧实现交换相邻 priority 值，两候选同 priority 时 = 静默 no-op（用户实测报障）。
  新实现交换位置后全量重建 priority=index*10；API 实测：move+rebuild 200、同 priority 脏写 400（服务端校验拒绝）、重建修复合法。
  新增行拖拽排序：onDrag/onDrop + PoolRowDropDelegate，落点即移位 + CAS 回写。
- **API Key 鉴权使能**：GET /admin/security/status 补挂 GET 路由表（此前只挂 POST 表 → 404）；
  `build_auth` 修复 marker 存在但 security.db 缺失时启动即崩 crashloop（KeyStore provision 补建）；
  enable 热替换 pm.auth/SecurityAdmin + 首把 key 明文仅回显一次；设置页静态 mock → 真开关 + 一次性密钥复制面板。
  实测链路：status → enable（401 无 key / 200 带 key）→ disable（policy off，密钥保留）。
- 测试遗留：~/.inferfabric/security.db 存一把名为 selftest 的测试密钥（policy=off 不拦截，可在 /admin/keys 撤销）。

## 2026-11-15 专项：池排序 UI 不实时刷新 — edb11fd
- **根因**：页面视图（PoolsView/PoolCard/CloudView 等 13 个）持普通 `var store` —
  引用类型字段 diff 恒等，不订阅 @Published；store.pools 已更新但视图不重渲染，
  只有切卡片（结构重建）才刷新。与此前云端页"切卡片才生效"同根因；
  InferenceView 一直有 @ObservedObject 所以模型列表实时 — 全部页面对齐该模式。
- **排序三层保障**：① 乐观更新 — 点击/拖拽本地 pools 立即重排，CAS 后台回写，
  失败 fetchPools 自动回滚；② 409 自动重试一次（连点不丢点击）；③ priority
  全量重建 index*10（前日 no-op 根因修复保持）。
- 网关侧已实测 POST 后 pools[*].candidates 立即按新序返回 — 服务端无问题。
- 遗留：GitHub push 连接超时（gitcode 已推成功），待网络恢复补推 origin。

## 2026-11-15 三项：池路由死锁修复 + 池调用指引 + 密钥留痕折叠 — 7c9d857 后
- **池路由死锁（根因级）**：用户配好的 fabric-fast 恒 no_compatible_target。排查：
  selector 证据门槛要求 PROBED/DECLARED，但 EvidenceStore.record 全运行时**无任何
  调用方**、管理员探测端点也不存在 — 所有池永远无法路由。修复：
  ① registry 编译期对未声明 declared_protocols 的云候选从服务商配置自动推导
  （启用 provider + 模型入池 = 管理员声明，显式声明仍优先）；
  ② accept_declared 默认 true（显式 false 尊重）。
  实测：fabric-fast → atlaswork/glm-5 ✅、fabric-premium → qianfan/glm-5.3 ✅。
- atlascode 查证：无此服务商 — 用户实指 atlaswork，glm-5 直连/池路由均通。
- 池页：删每池"复制池配置"按钮 → 底部新增「如何调用这些池」指引卡
  （Base URL 双方言 / model 填池名 / API Key 来源 + 可复制 curl 示例）。
- 设置页：已撤销密钥最多留 3 条痕（更早的折叠提示，防列表无限拉长）。

## 2026-11-18 — 战略转向 + M1 平台抽象层（纯 Python 网关回归）

- **产品裁决（D15–D22）**：放弃 SwiftUI App 线（App/安装版/dev 版/状态目录/缓存已彻底删除，D17）；UI 回归上游式 Web Dashboard（D15）；上游合入走 cherry-pick，由 peer session `inferfabric-pr` 承接 PR 事务（D16）；autostart 维持网关自管（D19）；34 个演进 diff 分级整理（D20）；main 不冻结（D22）。特性面以 F1–F10 锁定（specs/2026-11-18-mac-feature-lockdown.md）。
- **M0**：基线 316 tests 绿 + 沙箱冒烟（qa/2026-11-18-m0-baseline.md）。
- **M1**：`inferfabric/platform/` 抽象层落地（detect/ResourceLedger/umem+vram 双后端/probe/procguard/engines）；`memory_ledger.py`+`mac_platform.py` 转 shim；核心装配点 5 处切换；全量 345 tests 绿；生产双协议冒烟通过（glm-5 双通道 "ok"，qa/2026-11-18-m1-platform-layer.md）。
- **D20 审计**：34 演进文件 A/P/M 三级归类 + CHERRY-PICK-MANIFEST 首批 10 条目（docs/upstream/），inferfabric-pr 已接管对账。
