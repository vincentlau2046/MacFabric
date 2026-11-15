# MacFabric 实施基线（PLAN）

> 版本 v1.0 · 2026-11-14 · 状态：已定版（七轮讨论结论合并）
> 本文档是唯一实施基线。任何偏离需先改此文档再动代码。
> UI 设计稿：`design/ui-design-v0.html`（11 个画面 + 设计令牌，随本仓库演进）

---

## 0. 一句话定位

**MacFabric**：Apple Silicon 上的小模型多协议聚合平台——本机端侧能力（对话/看图/嵌入/重排/ASR/TTS/OCR/文生图/图生图，本地 LLM 默认 ≤4B、高级设置可配置）+ 云端大模型聚合，统一经 `:8999` 网关以 OpenAI/Anthropic 双协议暴露；原生 SwiftUI App + 菜单栏常驻，单 dmg 安装、零终端。

上游血统：定制自 [InferFabric](https://github.com/vincentlau2046/InferFabric)（Atlas 本地推理底座），保留其网关内核设计，退役其 CUDA 部署线。

## 1. 已裁决结论（D1–D14）

| # | 决策 | 结论 |
|---|---|---|
| D1 | 架构路线 | 保留 Python 网关内核（aiohttp，上游 ~12k 行 + 近 2000 测试的资产）+ 原生 SwiftUI 壳。不做全 Swift 重写 |
| D2 | 协议翻译层 | 接受。**只做 Anthropic→OpenAI 单向**；范围：messages / tools / 流式事件映射 / 图像块→image_url；不做 prompt caching 映射（`cache_control` 透传忽略）。测试金标 = 录制 Claude Code 真实会话回放 |
| D3 | UI 形态 | 菜单栏常驻（状态灯+微缩织物条+即停即睡）+ 主窗口，双形态 |
| D4 | 本地 LLM 档位 | **默认 ≤4B**（纯文本与 VL 同限），作为高级设置可配置（2026-11-15 修订，原"封顶"）。参数量门禁仅作用于对话类 LLM/VL；ASR/TTS/Embedding/Rerank/OCR 按内存门禁，不设参数门槛。任何放宽都必须经设置 + 实际资源预检，默认配置行为不变。大模型需求默认走云端聚合。候选：Qwen3-4B/1.7B、LFM2-2.6B、Gemma-3-4B、Phi-4-mini、Qwen3-VL-4B |
| D5 | 机型适配 | 状态机按 RAM 参数化；36GB 为开发基准，预设分 36/24/16GB 三档 |
| D6 | 项目形态 | 独立新仓库 MacFabric；models.d YAML schema 与上游兼容（能力包可互通）；上游保持通用定位 |
| D7 | 内存状态机 | **三规则版**（见 §3）。腾挪策略降级为安全网；`B = RAM − 8G` 唯一公式，**无第二道上限**（128GB 机型天然放宽；引擎真被系统拒分配时按引擎失败路径呈现，产品层不做预判） |
| D8 | 安装分发 | **单一 dmg 路径**：拖拽安装 → 首启三步向导 → 零终端。Python 运行时（python-build-standalone）内嵌 .app；llama.cpp/whisper.cpp Metal 二进制随包或首用下载；MLX 轮子首用经内置 uv 装入托管 venv；模型文件首用下载到 App Support。公证需 Apple Developer ID（$99/年），否则首开右键→打开 |
| D9 | OCR 桥 | 打包 ~200 行 Swift CLI（`ocr-helper`）：stdin 收图、stdout 吐 JSON，子进程调用。不用 pyobjc |
| D10 | TTS 兜底 | 系统语音通道 = `say` 命令（`-o` 落文件，内置中文语音），Kokoro 未加载时兜底；能力包命名"系统语音兜底" |
| D11 | 监控范围 | v1 = 内存账本 + memory_pressure + 请求级 token/TTFT/TPOT（复用上游 DB 链路）。**功耗/电费/GPU 利用率后移 v2**（需 root 特权助手） |
| D12 | 配置编辑权 | App 表单全生命周期 CRUD，落盘永远是 `models.d` YAML（schema 兼容上游）；`iff` 式 CLI 与 headless 用户共享同一真相源 |
| D13 | 网关归属 | **端口即单例**：App 发现 8999 已有健康网关则收养（adopt），绝不双实例；"开机自启"开关在 LaunchAgent / App 子进程两种托管间切换 |
| D14 | 局域网/鉴权 | 默认仅本机监听；关闭"仅本机"强制启用 API 鉴权（复用上游 PR-23a 体系）；局域网共享功能放 v1.5 |

### 仍待裁决（不阻塞 P0/P1）

1. 界面语言：跟随系统（默认简中）还是锁中文 —— 建议跟随系统
2. 菜单栏"快速对话"入口：v1 不做（保持纯控制面）
3. 局域网共享：v1.5（v1 设置页出现开关但标注"v1.5 启用"）

## 2. 系统架构

```
┌──────────────────────────────────────────────────────┐
│  SwiftUI 原生 App                                     │
│  菜单栏 MenuBarExtra + 主窗口 NavigationSplitView      │
│  Swift Charts · Liquid Glass · 亮/暗双主题 · 无 WebView │
└──────────────┬───────────────────────────────────────┘
               │ localhost:8999 admin API（上游 37 端点 + §6 扩展）
┌──────────────┴───────────────────────────────────────┐
│  Python 网关内核（保留改造，launchd agent 或 App 子进程）│
│  双协议 :8999 · 模型池 · 云聚合 · 治理链 · 内存账本      │
│  + Anthropic→OpenAI 翻译层（D2）                       │
├──────────────────────────────────────────────────────┤
│  Mac 引擎适配器                                        │
│  llama.cpp(Metal) · Ollama · MLX · whisper.cpp        │
│  mlx-audio(Kokoro) · say(系统语音) · Vision(ocr-helper)│
│  [退役门禁内保留] vLLM/NInfer/SGLang CUDA 线            │
└──────────────────────────────────────────────────────┘
```

进程模型（D13）：端口即单例；App 前台=子进程托管，自启=LaunchAgent（SMAppService）；Web Dashboard 保留为 headless 回退。

## 3. 内存账本规范（状态机）

macOS 哲学：没有显存状态机，只有**内存压力**和**按需加载/回收**。

### 三条规则（全部设计）

```
预算 B = RAM − 8G（唯一公式；"内存保留 8GB" 是设置页唯一入口）

规则1【准入】启动/加载：账本装得下 → 启动；装不下 → 拒绝，
            弹窗给出"差多少、停掉谁、然后怎样"，人点确认（不自动腾挪）
规则2【装载模式】每模型二选一：
            resident   常驻（能力包默认：嵌入/重排/判官/ASR/TTS/OCR）
            on_demand  请求到来自动加载，空闲 N 分钟自动卸（LLM/VL/生图默认，N=10）
规则3【安全网】系统内存压力过高（memory_pressure 实测）→
            只做一件事：卸载空闲中的 on_demand 模型，菜单栏黄灯通知
```

- 模型生命周期：`stopped → loading → ready ⇄ sleeping → stopped`（全局无状态机，只有 committed/B 两个数字 + 一盏压力灯）
- YAML 字段仅 3 个：`mem_baseline_mb`（预设预填） / `mode: resident|on_demand` / `idle_timeout_min`
- 基线校准：预设声明值 + UI 并排实测值（phys_footprint 采样，免 root）；偏差 >20% 亮黄点建议改 YAML——**人来改，不自动写**
- 拒绝弹窗复用织物条组件，文案钉死："安装「X」还差 N GB。停掉「Y」（M GB）就能装下。" + [停掉并继续]（Y 转入睡眠可唤醒）
- 睡眠唤醒是特性不是故障：监控台记黄不记红，模型卡显示"唤醒约 2s"

## 4. 引擎与能力矩阵

| 能力 | 引擎 | 默认模型 | 装载 | 协议端点 |
|---|---|---|---|---|
| 对话（本地） | MLX / llama.cpp(Metal) / Ollama | Qwen3-4B · Qwen3-1.7B · LFM2-2.6B | 按需 | /v1/chat/completions · /v1/messages(经翻译层) |
| 看图（本地） | MLX | Qwen3-VL-4B | 按需 | 同上（图像块映射） |
| 嵌入 | llama.cpp | bge-m3 GGUF | 常驻·静态直连 | /v1/embeddings |
| 重排 | llama.cpp | bge-reranker-v2-m3 | 常驻·静态直连 | /v1/rerank |
| 语音转写 | whisper.cpp(Metal) | large-v3-turbo | 按需 | /v1/audio/transcriptions |
| 语音合成 | mlx-audio（Kokoro-82m）+ `say` 兜底 | kokoro-82m | 常驻 | /v1/audio/speech |
| 文字识别 | Vision framework（Swift CLI 桥） | 系统内置 | 常驻·零模型 | /ocr（自定义） |
| 文生图/图生图 | MLX（mflux）| Flux-schnell 级 | 按需 | /v1/images/generations · /v1/images/edits |
| 云端 | 上游 9 预设 | glm-5 / glm-5-flash / seedream 等 | 常在 | 全端点一视同仁 |

镜像加速：HF 下载默认可切 hf-mirror.com（设置页开关，默认开）。

## 5. 模型池（默认五件套）+ 静态直连

```
iff/fast      快速对话   ① qwen3-4b(本机) ② glm-5(云端)
iff/small     轻量任务·意图分类  ① qwen3-1.7b(本机) ② glm-5-flash(云端)
iff/premium   长文写作   ① glm-5(云端)            [本地 ≤4B 不入此池]
iff/txt2img   文生图     ① mflux-schnell(本机) ② seedream-4.0(云端)
iff/img2img   图生图     ① mflux-schnell·编辑模式 ② seedream-edit(云端)
静态直连（不进池）：bge-m3 · bge-reranker-v2-m3 —— 按模型名直接路由
```

- 规则与上游一致：优先级尝试、已提交不重放、固定错误信封、跨本地/云回退显式开启、preview→apply 门禁
- 界面：分组列表 + 状态圆点 + 有序行（对齐 macOS"网络→服务顺序"范式）；调用中整行能力线色微染；管理器下拉切换池

## 6. 模型服务页（模型 Hub）与 API 面

**模型服务页** = 本机+云端全部可调用模型的统一接入目录：顶部接入条（唯一 Base URL + 鉴权状态）→ 类型筛选 → 每模型自带即拷即用配置（Base URL / 模型 ID / API Key 行 + 复制 cURL / JSON / 环境变量）。三条 UX 定则：

1. 所有模型一个地址（客户端不感知背后是谁）
2. 密钥永不外露（云端 Key 由网关持有）
3. 配置永远有效（已停止的按需模型首请求自动唤醒）

**统一调用面**：`/v1/chat/completions · /v1/messages · /v1/embeddings · /v1/rerank · /v1/audio/speech · /v1/audio/transcriptions · /v1/images/generations · /v1/images/edits · /ocr`

**网关改造清单**：退役门禁（vLLM/NInfer/SGLang/Docker/systemd/conda/nvidia-smi 路径，代码保留加平台门禁）；新增 MLX/whisper.cpp/mlx-audio/ocr-helper/say 适配器；统一内存状态机替换三态 GPU 状态机；翻译层；launchd/uv 打包。

## 7. 术语规范（UI ↔ 概念，钉死防漂移）

| UI 用词 | 概念 | 说明 |
|---|---|---|
| 模型服务 | 模型 Hub / 接入目录 | 统一接入配置出口 |
| 本地推理 | 模型生命周期管理 | 启停/睡眠/唤醒/基线实测 |
| 模型池 | iff/\<pool\> 逻辑路由 | 候选链/优先级/回退 |
| 监控台 | 运营观测 | token/延迟/请求日志 |
| 能力包 | YAML 预设 + 模型清单 | 安装即落 models.d |
| 云端接入 | 云服务商管理 | 预设/发现/打标/密钥 |
| 常驻 / 按需 | resident / on_demand | 装载模式 |
| 织物条 | 内存账本可视化 | 全局心脏组件 |

## 8. UI 设计令牌（详见设计稿页尾）

深色：desk `#101014` · panel `#17171c` · chrome `#1e1e25` · accent 织物蓝 `#5f7dff`（亮色 `#3d5ce5`）；八根能力线色（判官紫/对话蓝/看图粉/嵌入青/重排天蓝/转写琥珀/合成珊瑚/识别草绿/生图青）；状态色 Apple 系统色 ok/warn/err；字体 SF Pro + PingFang SC，数据 SF Mono；圆角 14/10/7；动效 0.15/0.25s，reduced-motion 全局降级。

## 9. 测试策略

- 网关：上游 pytest 全量迁移 + 新增内存账本仿真（超卖/压力/自愈）
- 翻译层：Claude Code 真实会话录制 → 金标回放
- App：Swift Testing；浏览器门禁不适用（无 WebView）
- 引擎版本全部 pin：llama.cpp（pin tag 自建 Metal 二进制脚本）、MLX、whisper.cpp

## 10. 里程碑

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P0 基线**（当前） | 仓库初始化；Mac 上跑通网关：Metal llama.cpp + Ollama 适配器；双协议、模型池回归 | Claude Code 指向 localhost:8999 正常工作 |
| P1 内核 Mac 化 | CUDA 线门禁退役、内存账本状态机、翻译层、launchd/uv 打包、ocr-helper | 全测试绿 + 免 sudo + 重启自愈 |
| P2 原生 App | SwiftUI 骨架 + 菜单栏 + 总览/模型服务/本地推理/模型池 + 监控台 | App 替代 Web Dashboard 日常操作 |
| P3 能力包 | ASR/TTS/OCR/嵌入/重排/生图 预设 + 新端点全通 | 每类能力一条 curl 可验 |
| P4 打磨 | 引导安装 dmg、Sparkle 更新、Shortcuts、文档、公证分发 | 非开发者可安装使用 |

## 11. 仓库与上游

- 本仓库：GitHub `vincentlau2046/MacFabric` + GitCode 镜像（public）
- 上游：[InferFabric](https://github.com/vincentlau2046/InferFabric)（MIT）——YAML schema 兼容，设计引用注明出处
