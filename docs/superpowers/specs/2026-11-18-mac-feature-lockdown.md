# MacFabric 关键特性锁定（整体方案基线）

> 日期：2026-11-18 · 状态：待用户锁定确认
> 上游设计：[2026-11-18-python-gateway-refocus-design.md](2026-11-18-python-gateway-refocus-design.md)
> 本文档的用途：把 STATUS.md 里十几轮补丁攒出的功能，**重组为一个连贯的三层整体架构**并逐条锁定行为语义。锁定后，后续重构（Plan 1–4）以本文为特性清单，补丁历史仅作溯源，不再作为认知入口。

## 0. 开发流程（全程不变，用户裁决）

```
修改 → 沙箱验证（临时 state dir / 非生产端口） → 回归测试（tests/ 全量 + 双协议冒烟）
     → 提交 & push（gitcode + github 双远端） → 生产合入（:8999 安装版网关重启生效）
```

任何特性未走完全链不得视为完成；生产合入前沙箱与回归必须有绿色记录（docs/qa）。

## 1. 整体架构（三层）

```
┌────────────────────────────────────────────────────────────┐
│ 控制面层  Web Dashboard（:8999 同端口，上游 fragments/js 模式）│
│ overview · deploy · inference · monitor · model-pools(v2)    │
│ cloud · anomaly + 新增 packs · security · connect            │
├────────────────────────────────────────────────────────────┤
│ 网关核心层（与上游 InferFabric 同构，最小触碰）                 │
│ 双协议入口 · 模型池 v2 · 云聚合 · 治理链 · jobs · 安全         │
├────────────────────────────────────────────────────────────┤
│ 平台层（唯一感知 OS/硬件的层，cherry-pick 的主体）             │
│ 资源账本(两后端) · 进程守护 · 引擎矩阵 · 客户端托管(Connect)   │
└────────────────────────────────────────────────────────────┘
```

## 2. 特性锁定清单（按域）

### F1 双协议统一入口（网关核心）
- **锁定语义**：`:8999` 单端口三入口——OpenAI `/v1/chat/completions`、Anthropic `/v1/messages`、Responses `/v1/responses`（原生优先，无原生能力引擎走桥）。
- **子特性**：① Anthropic→OpenAI 翻译桥 `anthropic_translate.py`（请求/响应/SSE 三块，金标=录制回放）+ `proxy/anthropic_bridge.py` 旁路（`anthropic_native` 开关：llama-server 透传，vLLM/MLX 走桥）；② Responses 桥 `proxy/responses_bridge.py`；③ 斜杠模型（`provider/model`）全名优先解析；④ usage 双 chunk 取 max 不取 sum。
- **代码锚点**：`proxy/chat_handlers.py`、`proxy/handler.py`、`anthropic_translate.py`、`proxy/responses_bridge.py`
- **回归锚点**：tests/golden 录制件、双协议手动冒烟。

### F2 平台资源账本（平台层核心，cherry-pick 主件）
- **锁定语义**：三规则不变（D7/PLAN §3）——准入拒绝（人确认）、resident/on_demand 空闲休眠（N=10min）、memory_pressure 只卸空闲 on_demand；唯一公式 `B = RAM − reserve`（默认 8192 MiB；env > policy > 默认）。
- **现状**：`memory_ledger.py`（纯逻辑）+ `mac_platform.py`（lsof 端口探测、vm_stat 水位、budget 计算）。
- **重构目标形态**：`platform/` 抽象层（ResourceLedger 接口 + resource_umem/resource_vram 两后端 + procguard + engines），旧模块名留 shim 一个周期。上游 CUDA 三态状态机包装为 resource_vram 后端。

### F3 模型生命周期与进程管理（平台层）
- **锁定语义**：引擎适配器接口（start/stop/health_check/validate）；Mac 引擎矩阵 = llama.cpp Metal（对话主力）、Ollama、kokoro TTS（ONNX CPU）、whisper ASR（Metal）、Vision OCR（零模型，Swift helper）；停止 = lsof 定 PID → SIGTERM → 校验 → SIGKILL（fuser 旧路径废弃）。
- **autostart（D19）**：网关启动钩子 best-effort 拉起，失败只记日志；`POST /admin/models/set-autostart` 改 YAML 热重载；每模型 `autostart: false` 默认。
- **环境隔离范式**：所有部署自包含（engines/ 独立二进制 + venv，`python_bin` 显式路径）；卸载=容器化拆除（停服务→删yaml→热重载→删模型→引擎引用计数归零 rmtree→池候选联动清除，响应带清理审计字段）。

### F4 能力包 packs（网关核心 + 平台层）
- **锁定语义**：统一合同进模型（catalog/download/install/uninstall_preview/uninstall/status + policy + custom + 下载进度快照）；`model_type` 标签（embedding/rerank/vl 线色）；包模型直连不进聊天池，按 `api_model_id` 路由；首请求自动唤醒。
- **代码锚点**：`packs/`（catalog/config_gen/custom/installer/policy/runtime_prep/sandbox/schema/store/supervisor/uninstaller）+ `proxy/pack_handlers.py`。
- **Dashboard 承接**：新增 packs 页（纯前端，API 已齐）。

### F5 模型池 v2（网关核心）
- **锁定语义**：池名 v2（flash/lite/max）；候选链有序（priority=index*10，CAS 回写，409 重试）；跨本地/云回退显式开启；preview→apply 门禁；selector 证据门槛 = 编译期自动推导（启用 provider+模型入池=管理员声明，显式声明优先，accept_declared 默认 true）；池页"如何调用"指引（Base URL 双方言/model 填池名/key 来源）。
- **回归锚点**：池 CAS/同 priority 脏写 400/move+rebuild 200 单测。

### F6 云端聚合（网关核心）
- **锁定语义**：服务商 CRUD + 发现（超时 150s）+ 启用白名单 + model_specs 属性（VL/工具/上下文/最大输出/价格）；Anthropic 双约定（base 尾带 /v1 拼 /messages，裸 base 拼 /v1/messages）；floor 兜底注册（短键占用时补前缀键）；协议 chip 数据源 = anthropic_native（本地）/ anthropic_base（云）。
- **opencodex 吸收②③**：Responses 入口已并入 F1；**账号池 + 配额路由 + 会话亲和**列为 F6 增强接口占位（本期只留接口，实现另立）。

### F7 安全与门禁（网关核心）
- **锁定语义**：API key 鉴权 enable/disable（密钥保留）、首把 key 一次性回显、撤销留痕最多 3 条；marker 存在但 security.db 缺失时补建不 crashloop；管理门禁默认开放（b812899），关闭"仅本机"强制启用鉴权（D14）。
- **Dashboard 承接**：新增 security 设置页（纯前端）。

### F8 运维与守护（平台层）
- **锁定语义**：`com.macfabric.gateway` LaunchAgent（KeepAlive 10s 拉起 + 开机自启）管安装版 :8999；`MACFABRIC_STATE_DIR`/`MACFABRIC_MODELS_DIR` 隔离；日志目录跟随 state dir；双远端 push（gitcode+github）。
- **已收缩**：安装版/调试版双档位随 App 删除收缩为**单安装版**（D17）；D13 的 LaunchAgent/App 子进程托管切换废止（autostart 归网关自管，D19）。

### F9 控制面 Web Dashboard（控制面层）
- **锁定语义**：UI = 上游式 web dashboard，挂在 :8999，不引入构建链；上游 7 页（overview/cloud/deploy/inference/monitor/model-pools/anomaly）+ 分叉池 v2 改动为基线；**新增三页**：packs（F4）、security（F7）、connect（F10）+ overview 内存账本增强（committed/B/压力灯）+ deploy 页 autostart 开关。
- **上游化单元文案随上游风格；fork 自用部分可中文（manifest 标注）**。

### F10 Connect 客户端托管（平台层，opencodex 吸收①）
- **锁定语义**：Dashboard connect 页一键把客户端工具（先行：Claude Code、Codex）的 base_url/auth 指向 :8999；改写前显式确认 + 可一键回退；实现于 `platform/clients.py` + dashboard fragment。
- **后置**：账号池增强（F6）、菜单栏薄壳（可选，另立）。

## 3. 明确退役/不保留

| 项 | 处置 |
|---|---|
| SwiftUI App（全部功能面） | 已删除（D17），功能由 F9 承接（映射表见上游设计 §6.3） |
| 安装版/调试版双档位 | 收缩为单安装版（F8） |
| fuser 停止路径 | 已被 lsof 路径取代，代码移除 |
| HF 镜像直装旁路 | 不恢复（模型产物源统一 ModelScope） |
| CUDA 部署线 | 平台层 resource_vram 后端保留接口，Mac 侧不部署 |

## 4. 与 opencodex 的吸收对照（整体方案的一部分）

| opencodex 设计 | 吸收方式 | 归属 |
|---|---|---|
| 纯 proxy + web dashboard 形态 | 即 F9（方向一致，非新增） | F9 |
| 三协议入口互译 | F1 已实现 Responses 原生优先；合同测试补齐后入摘取清单 | F1 |
| Connect 托管客户端配置 | F10 新建 | F10 |
| 账号池/配额路由/会话亲和 | F6 接口占位，实现另立 | F6 |
| 桌面壳=薄 wrapper | D18 后置可选 | — |

## 5. 锁定的验收基线（M0 记录入 docs/qa）

1. `macfabric_gateway/tests`（unit + golden）全量绿；
2. `:8999` 双协议手动冒烟（OpenAI chat + Anthropic messages，含流式）；
3. 池路由冒烟：池名调用命中候选链首选；
4. F1–F10 每条锁定语义在 tests/ 有对应锚点（缺失的补入 Plan 1 任务）。
