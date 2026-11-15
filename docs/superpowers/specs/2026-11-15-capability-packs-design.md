# MacFabric 本地能力包设计合同

> 状态：讨论稿，未进入实施。本文冻结需求、边界和架构方向；实施前仍需审阅并据此编写逐任务计划。

**日期：** 2026-11-15  
**范围：** MacFabric 第一阶段本地能力包  
**基线：** `docs/PLAN.md`、`docs/ISOLATION.md`、现有 `ModelConfig` / `EngineAdapter` / `ModelLifecycle`

## 1. 目标

MacFabric 能力包不是固定的单模型列表，也不是让用户自由组合模型、量化和框架的通用模型管理器。它是面向一个具体本地能力的、经过平台验证的固定预设：

```text
能力 + 具体开源模型 + 固定量化 + 固定框架/运行时 + 资源策略 + 隔离配置
```

用户选择一个预设包，执行一次安装或卸载；平台负责依赖准备、校验、隔离、生命周期、Gateway 注册和清理。

同一能力可以有多个预设包。例如端侧 LLM 可以同时提供通用基线、深度思考、多语种等包；用户选择包，不在安装过程中重新拼装实现。

## 2. 已确认的产品边界

### 2.1 第一阶段范围

- 只提供本地执行能力，不接入远端推理 Provider。
- 安装时允许从受信任的 HTTPS 来源下载模型和运行时；“本地”指推理执行位置，不指资源必须预置在 DMG 内。
- 以开源模型和可审查的运行时为主；每个包保存许可证、来源、版本和校验信息。
- 同一能力提供多个 SOTA/常用预设包，而不是把一个模型包装成一个固定能力卡。
- 一个模型一套独立环境：runtime、venv、引擎二进制、模型、临时目录、日志和进程组均不与其他包共享。
- 统一的是包格式、目录模板、安装事务、SandboxProvider、Supervisor、资源策略和状态机。
- 安装不等于启动；默认使用 `on_demand`，安装完成后只保证可发现和可启动。
- 4B 模型上限和 8GB 系统保留内存保持现有默认值，但作为高级设置可配置；修改设置不改变默认策略，也不绕过实际资源预检。
- 文生视频、图生视频不纳入第一阶段；轻量端侧不为此设计特殊例外。

### 2.2 第一阶段非目标

- 云端 OCR/ASR/TTS 或其他远端实现。
- 用户在安装时自由选择任意模型、量化、框架、Python 版本或依赖组合。
- Docker/OCI 容器作为第一阶段部署基础。
- 第三方插件市场、任意未审核包、动态执行外部安装脚本。
- 以模型参数量单独判断可运行性。
- 把所有规划中的 MLX/mflux/Paddle/NeMo 运行时一次性接入。
- 把安装成功宣传为模型已经常驻运行。

## 3. 术语与边界

### 3.1 能力 Capability

用户想完成的任务类别，例如：

- 端侧 LLM
- 视觉语言理解
- ASR
- TTS
- Embedding
- Rerank
- OCR

能力定义端点、输入输出契约、展示名称和可用预设，但不直接包含某个进程的路径。

### 3.2 预设包 Pack Preset

一个可安装的固定组合。包内固定一个模型、一个量化和一个运行框架，带有资源、许可证、来源、校验和健康检查定义。包是用户界面中的主要安装单元。

### 3.3 模型运行实例 Model Instance

安装包在 `models.d` 中生成的执行配置及其运行状态。现有 `ModelConfig`、`ModelLifecycle` 和 `EngineAdapter` 继续承担执行层职责；它们不取代 Pack Manifest。

### 3.4 运行时 Runtime

包自有的 Python、venv、引擎二进制、服务代码和依赖。第一阶段不在包之间共享运行时，避免卸载和升级的连带影响。

### 3.5 系统内置能力

不需要下载模型的能力，例如 macOS Vision OCR。它仍然可以出现在能力包目录中，但状态显示为“系统内置 / 无需安装”，不能伪造下载包。

## 4. 设计原则

1. **后端权威**：能力目录、包清单、安装事务和运行状态由 Gateway/Pack Manager 管理；Swift 不保存下载 URL 和引擎安装规则。
2. **预设优先**：平台筛选和验证组合，用户选包，不在安装时组装任意依赖。
3. **一模型一环境**：磁盘换隔离；不共享 venv、引擎目录或包内依赖。
4. **最小影响范围**：一个包崩溃、挂起、校验失败、卸载或升级，不应删除、覆盖或停止其他包及 OS 层资源。
5. **事务提交**：未完成校验、健康检查和 Gateway 注册的包不进入正式安装状态。
6. **诚实状态**：沙箱、资源、下载、健康检查和降级状态均显式展示；不以目录存在冒充服务健康。
7. **兼容执行层**：包管理器生成现有 `ModelConfig`，不在第一阶段重写所有模型生命周期代码。
8. **默认保守**：默认 `max_model_parameters=4B`、`system_reserved_memory=8GB` 不改；所有放宽都必须经过设置和实际预检。

## 5. 方案比较与选择

### 方案 A：继续扩展 Swift 静态预设

在 `PacksView.packPresets` 中增加更多模型和下载 URL。

- 优点：改动少。
- 缺点：能力、模型、框架、依赖、所有权和版本继续硬编码在 App；无法可靠实现事务回滚和独立卸载。
- 结论：不采用，仅保留兼容迁移期的旧入口。

### 方案 B：后端 Catalog/Manifest + 一模型一独立包环境

后端维护能力目录和固定包清单，安装器按清单准备独立环境，生成现有 `ModelConfig`，由统一 Supervisor 管理包进程。

- 优点：匹配固定预设和最小影响范围，最大化复用现有执行层。
- 缺点：需要新增清单、状态机、安装事务和沙箱适配层。
- 结论：采用。

### 方案 C：OCI/Docker/完整插件平台

每个能力包变成容器或第三方插件。

- 优点：隔离和扩展概念完整。
- 缺点：macOS 容器通常依赖 Linux VM，难以轻量使用 Metal；插件还需要签名、权限、ABI、升级和供应链体系。
- 结论：第一阶段不采用，为未来扩展保留 Manifest 演进空间。

## 6. 统一包模型

### 6.1 Catalog

Catalog 是后端可读取的能力目录，列出经过审核的包，不直接表示已安装状态。第一阶段可随应用发布或由受信任更新机制提供；不引入云端 Provider。

**安装入口收口（2026-11-15 已裁决）**：能力包安装只接受 Catalog 中的 `pack_id`，下载 URL/hash 全部由后端提供，App 不得提交任意 URL。现有 `/admin/packs/download` 任意 URL 路径收口为**用户导入模型**（本地扫描已有文件）专用，明确标记为"用户模型"，不进入包所有权，卸载语义沿用旧规则（含引擎引用计数）。

每个目录项至少包含：

- `pack_id`、显示名称、能力 ID、简介、特长标签
- 模型名称、模型版本、参数规模、量化、上下文能力
- 开源许可证、来源页面、下载来源、发布版本
- 固定引擎 ID 和运行时模板 ID
- Apple Silicon / macOS 兼容条件
- 磁盘大小、峰值内存、推荐内存、预计安装时间
- 输入输出协议、端点和能力声明
- 安装/健康检查/卸载模板版本
- 风险等级和是否允许沙箱降级

### 6.2 Manifest

Manifest 是安装事务的不可变输入，也是卸载所有权的依据。建议至少包含：

```yaml
pack_id: llm.qwen3-4b-instruct-2507
pack_version: 1.0.0
capability: llm
model:
  id: qwen3-4b-instruct-2507
  parameter_count_b: 4
  quantization: q4_k_m
  license: apache-2.0
runtime:
  engine: llama_cpp
  runtime_template: llama-cpp-macos-arm64-v1
resources:
  download_mb: 3200
  disk_mb: 3400
  peak_memory_mb: 4800
  gpu_role: shared
lifecycle:
  mode: on_demand
network:
  listen: loopback
  allowed_upstream: []
artifacts:
  - id: model
    kind: model
    source: https://...
    sha256: ...
  - id: engine
    kind: runtime
    source: https://...
    sha256: ...
execution:
  model_config_template: llama_cpp_chat_v1
  healthcheck: openai_chat_ready_v1
sandbox:
  policy: verified-local-pack-v1
  degraded_install_allowed: true
```

实际字段和版本化方式需在 PK0 契约任务中冻结。Manifest 不允许包含任意安装脚本；运行时准备只能调用平台已审核的模板动作。

### 6.3 包目录

```text
~/.inferfabric/packs/<pack_id>/<pack_version>/
├── manifest.yaml
├── runtime/
│   ├── python/
│   ├── venv/
│   └── bin/
├── models/
├── work/
├── logs/
├── tmp/
├── sandbox/
└── state/
```

包的正式执行配置由 Pack Manager 生成到受控的 `models.d` 区域，并带有 `managed_by_pack`、`pack_id`、`pack_version` 标记。用户导入模型保留在独立的用户模型区域，不与包所有权混合。

## 7. 安装与卸载生命周期

### 7.1 安装

```text
available
  → preflight
  → staging
  → downloading
  → verifying
  → preparing_runtime
  → writing_config
  → isolated_healthcheck
  → gateway_reload
  → installed
```

安装前预检：

- Apple Silicon 和最低 macOS 版本
- Catalog/Manifest 版本和许可证
- 磁盘空间
- `max_model_parameters` 和 Manifest 资源要求
- 8GB 保留内存后的可用预算
- 当前运行包的并发和 GPU/统一内存闸门
- 端口、目录和配置冲突
- artifact SHA256
- SandboxProvider 能力与降级策略

事务规则：

- 所有下载和构建先放 staging。
- `.part` 文件不得被执行或注册。
- hash、运行时准备、健康检查、配置写入和 Gateway reload 全部成功后才 commit。
- 任意阶段失败删除 staging，不修改已安装包，不写半成品 `models.d`。
- 健康检查失败记录阶段化错误并允许重试。

### 7.2 卸载（2026-11-15 已裁决）

```text
installed
  → disabling_route
  → draining
  → stopping_process_group
  → removing_generated_config
  → purging_pool_candidates
  → deleting_pack_directory
  → gateway_reload
  → removed
```

卸载删除包自有 runtime、模型、临时文件、日志和状态；不删除用户导入模型，不影响其他包。

- 被模型池引用时：卸载确认框**列出受影响的模型池候选**，用户确认后自动移除这些候选再继续（不静默、也不阻止卸载）。
- 在途请求 drain 上限 **10 秒**，超时强杀进程组，在途请求按 **503** 返回。

### 7.3 失败恢复（2026-11-15 已裁决）

所有状态都必须可恢复：

- 下载中断：从 staging 清理或按实现支持续传
- 校验失败：删除该 artifact，不进入安装状态
- 引擎启动失败：保留安装文件但标记 `failed`，允许重试或卸载；**失败包默认保留供诊断**，设置中可开启自动清理
- Gateway reload 失败：不把包标记为可用，保留诊断信息
- 进程异常退出：Supervisor 标记 `degraded/failed`，不得自动污染其他包

### 7.4 升级（2026-11-15 已裁决）

同一 pack_id 升级采用**新版本目录健康检查通过后原子切换**（`packs/<pack_id>/<new_version>/` 全链路成功后切换 `current` 指针，旧版本保留一个回退窗口后清理）；不做原地替换。

### 7.5 安装目录（2026-11-15 已裁决）

第一阶段固定为 `~/.inferfabric/packs/`，不提供用户自选安装目录。

## 8. 隔离与 Supervisor

### 8.1 底线

每个包的引擎进程必须：

- 独立进程组
- 由 Supervisor 持有 PID/PGID 和状态
- 退出、超时、卸载时整组收割
- 工作目录、环境变量和端口指向包自身
- 只能通过 Gateway 的 loopback API 被调用

### 8.2 SandboxProvider

沙箱方案本身统一，实例配置按包生成：

```text
SandboxProvider
├── SBPL profile API 注入（产品优先路径）
├── sandbox-exec（仅开发/兼容诊断）
└── degraded process isolation（明确降级）
```

目标限制：

- 只读包目录和必要系统运行库
- 只写包目录、包 tmp 和必要日志路径
- 禁止访问用户凭证、其他包目录和任意系统配置
- 网络默认关闭或仅允许明确的本地 Gateway 端口
- 限制子进程派生到包模板允许范围

macOS 版本对 SBPL 工具和 API 的支持不稳定，不能把 `sandbox-exec` 命令存在作为产品前提。必须有能力探测和逐版本回归。

能力探测结果枚举（PK0 冻结）：`full`（SBPL API 注入可用）/ `degraded`（API 不可用，进程组 + 目录 + 网络约束能做到的部分仍启用）/ `unavailable`（探测本身失败，按 `degraded` 处理并记录诊断）。探测结果驱动 §8.3 降级策略与安装准入。

### 8.3 降级策略（已裁决）

采用分级降级：

- 官方已验证的内置预设：SBPL 不可用时允许安装，状态显示“隔离降级”，仍启用进程组、目录隔离、资源监控和网络约束能做到的部分。
- 未验证或未来第三方包：SBPL 不可用时拒绝安装。
- 不允许静默把降级状态显示为完整隔离。

### 8.4 资源约束现实

- CPU、文件描述符、进程数可使用 POSIX rlimit/继承式限制。
- macOS 内存 rlimit 不能作为可靠硬上限。
- Metal/统一内存没有可依赖的每进程硬上限。
- 内存控制采用安装/启动准入、包间并发闸门、RSS/footprint watchdog、超限收割和现有内存账本。
- `taskpolicy`/QoS 作为软调度，不作为安全边界。

## 9. 4B / 8GB 策略

默认设置保持不变：

```text
max_model_parameters = 4B
system_reserved_memory = 8GB
```

高级设置允许用户调整这两个策略，但每次安装/启动仍必须同时通过：

```text
参数规模策略（仅对话类 LLM/VL 门禁；ASR/TTS/Embedding/Rerank/OCR 不设参数门槛）
+ Manifest 峰值内存
+ 当前剩余内存预算
+ 包间并发/GPU 闸门
+ 健康检查
```

调整设置不自动重装包、不自动并行启动包；只影响后续安装和启动准入。超出默认值时必须是显式高级操作并显示资源风险。

## 10. 现有代码的接入边界

| 现有组件 | 目标职责 |
|---|---|
| `PacksView.packPresets` | 迁移为消费后端 Catalog，保留过渡兼容 |
| `ModelConfig` / `models.d` | 继续作为单模型执行层，由 Manifest 生成受控配置 |
| `EngineAdapter` | 复用现有引擎契约，新增引擎才补 adapter |
| `ModelLifecycle` / `ProcessManager` | 接入包级工作目录、环境变量和进程组 |
| `MemoryLedger` | 接入安装前分析、启动准入和超限收割 |
| `PoolRegistry` | 包安装/卸载时注册或清除本地候选 |
| `GatewayStore` | 展示 Catalog、安装阶段、运行状态和错误，不拼装安装命令 |
| 现有下载端点 | 收口到 Pack Manager 的事务 API，保留兼容映射 |

第一阶段不要求重写所有模型服务；先让一个已验证 LLM 包完整走通，再抽象到 ASR/TTS/Embedding/Rerank/OCR。

## 11. 首批预设方向（2026-11-15 已收窄裁决）

首批（PK4/PK5 之前）冻结为当前已实测验证的 5 项：

- Qwen3-4B-Instruct-2507：通用基线、多语（中英为主）、工具调用 — **首个完整试点包**
- BGE-M3：多语 dense + 混合检索（Embedding）
- Whisper（large-v3-turbo）：多语 ASR
- Kokoro-82M（ONNX）：英语低延迟 TTS
- macOS Vision：内置 OCR，无下载包

以下移入 P5 后续批次，按运行时风险逐个独立验证后再纳入：
Qwen3-4B-Thinking-2507、Qwen3-VL-4B、SenseVoice-Small（中文 ASR）、
CosyVoice 2（中文/多语 TTS）、Qwen3-Embedding-0.6B、Qwen3-Reranker-0.6B /
BGE-Reranker-v2-M3。

**Gemma 3 4B 移出清单**，许可证复核完成前不进入任何批次。
PaddleOCR-VL、流式 ASR、8B 特档和其他新运行时必须在单独验证后进入后续批次。
每个 artifact（权重/二进制/依赖）分别记录 license、source 与 sha256；
带非商业限制的权重默认不进入发行包，除非另行完成发行许可裁决。

## 12. 分阶段实施门禁

### PK0：契约和风险验证

- 冻结 Catalog/Manifest/PackState schema
- 以 fake package/fake engine 验证安装事务和回滚
- 验证 sandbox 能力探测、降级标记、进程组收割
- 验证 RSS watchdog 和 4B/8GB policy

**门禁：** 不下载真实大模型；所有失败状态可重现、可清理、可解释。

### PK1：Pack Manager 底座

- Catalog 读取和 Manifest 校验
- staging、hash、commit、rollback
- 包目录与所有权记录
- 安装/卸载状态持久化
- API 和旧端点兼容映射

**门禁：** 假包安装/失败/重试/卸载后无残留且不影响第二个假包。

### PK2：隔离运行时

- 包级 runtime/venv/engine 模板
- Supervisor 和进程组
- SandboxProvider
- rlimit/QoS/watchdog
- 健康检查与异常恢复

**门禁：** 人为杀进程、超时、超内存、非法路径、越权网络均有明确结果。

### PK3：执行层接入

- Manifest 生成 `ModelConfig`
- 接入 EngineAdapter、ModelLifecycle、MemoryLedger
- 接入 PoolRegistry
- 安装不启动，首次调用按需启动

**门禁：** 一个真实 LLM 包从安装到调用、睡眠、唤醒、卸载全链路通过。

### PK4：App 能力包页

- 后端驱动 Catalog
- 固定预设卡片
- 资源/许可证/隔离状态展示
- 安装阶段、失败原因、重试、卸载确认
- 运行状态与模型服务页保持一致

**门禁：** App 不再硬编码下载 URL、框架安装逻辑或包路径。

### PK5：首批能力扩展

按运行时风险逐步接入 VL、ASR、TTS、Embedding、Rerank 和内置 OCR；每种新运行时必须独立验证，不把多种新栈混入同一提交或同一验收批次。

## 13. 验收重点

### 正确性

- 多个同能力预设可并存安装
- 模型身份、能力、包状态和执行状态不混淆
- 安装后可发现但不默认启动
- 卸载一个包不影响其他包和用户模型

### 安全与隔离

- 包进程崩溃只影响自身
- 子进程整组收割
- 不能写其他包和用户敏感目录
- SBPL 不可用时状态和安装策略正确
- 下载 hash 不匹配不会进入正式目录
- 日志不含凭证、完整请求体或上游敏感错误体

### 资源

- 默认 4B/8GB 策略不变
- 高级设置修改后新安装/启动行为可解释
- 内存不足在启动前拒绝，不等运行中才发现
- 无 per-process 硬内存/Metal 限额的事实在 UI/文档中诚实表达

### 故障注入

- 下载中断
- hash 错误
- runtime 准备失败
- 健康检查超时
- 子进程崩溃
- Gateway reload 失败
- 卸载时请求仍在执行
- 模型池仍引用待卸载包
- 包目录或 Manifest 被篡改

## 14. 实施前确认（2026-11-15 已裁决，六组全部按推荐通过）

1. **隔离方案**：严格一模型一环境 — 每包复制引擎二进制/venv，不共享运行时，卸载 = 删目录，无引用计数；ISOLATION.md §五 已修订（引擎引用计数仅保留给用户导入模型旧路径）。
2. **4B 门禁**：PLAN.md D4 已修订为"默认 4B、高级设置可配置、默认配置行为不变"；参数量门禁仅作用于对话类 LLM/VL，其余能力按内存门禁。
3. **安装事务**：失败包默认保留 `failed` 供诊断（设置可开自动清理）；升级 = 新版本目录健康后原子切换；安装目录第一阶段固定 `~/.inferfabric/packs/`。
4. **卸载**：确认框列出受影响池候选，确认后自动清除；drain 10s 超时强杀进程组，在途请求 503。
5. **安装入口**：包安装只接受 Catalog pack_id（URL/hash 后端提供）；用户导入模型走旧路径并标记"用户模型"。
6. **首批冻结**：Qwen3-4B-Instruct-2507（首个完整试点）、BGE-M3、Whisper、Kokoro ONNX、macOS Vision 五项；其余移入 PK5 批次；Gemma 许可证复核前移出。

### 实现层裁决（builder check 已答复项，实现时遵循）

- Manifest → `ModelConfig` 映射沿用现有语义：`mode`（常驻/按需）、`ledger_mode`、`gpu_role` 等字段由 `model_config_template` 按现有 config.py 语义生成。
- 里程碑命名 PK0–PK5，与 PLAN.md 的 P0–P4 里程碑区分（本文 §11/PK 引用一致）。
- `resources` 单位沿用 MiB（与 mac_platform.py `mem_total_mb` 口径一致）。
- Pack 作用域 = 本地候选 only：包生成的 ModelConfig 只进本地池候选，不涉及云端 provider。

Manifest 最终字段/版本迁移策略、首批真实包的下载源/hash、SBPL API 注入可行性验证，分别在 PK0 任务内冻结与取证。

### 取证记录（Task 12，2026-11-15）

- **SBPL 探测实测**：本机（macOS 27.2, Darwin 27.2.0）`probe_sandbox()` →
  `full | SBPL C API available (macOS 27.2)`（libc `sandbox_init` 符号存在）。
  SBPL API 注入路径在本机可行；真实注入实现仍按计划于 PK3 后立项验证。
- **首批 Catalog hash 冻结**：模型 sha256 取自 HuggingFace LFS
  `x-linked-etag`（即 LFS oid，等价 sha256）：Qwen3-4B-Instruct-2507-Q4_K_M
  （lmstudio-community 镜像，官方 Qwen GGUF 仓未同步镜像）、bge-m3-Q8_0
  （gpustack）、ggml-large-v3-turbo（ggerganov/whisper.cpp）、Kokoro
  model.onnx fp32（onnx-community）；llama.cpp b12361 macOS arm64 引擎包
  sha256 由本机下载实测取得。下载源以 HTTPS 写入 Catalog artifact.source。
- **网络事实**：huggingface.co 直连被网络阻断（connection reset），取证经
  hf-mirror.com 元数据端点完成；产品下载路径（HttpArtifactFetcher）在用户
  网络下执行，PK3 真包验收时以实测 hash 复核。

本文不授权代码、依赖、安装版或发布操作；只有实施计划审阅通过后，才进入下一阶段。
