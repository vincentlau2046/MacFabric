# 双平台 DeviceTelemetry 统一设备遥测设计

> 日期：2026-11-18 · 状态：裁决完成，待用户终审批准（builder check 见 §13，用户裁决见 §14）
> 关联设计：`2026-11-18-python-gateway-refocus-design.md`、`2026-11-18-mac-feature-lockdown.md`
> 适用平台：Apple Silicon（macOS/统一内存）与 x86 + NVIDIA（Linux/CUDA/VRAM）

## 1. 意图与动机

当前 MacFabric 已完成第一阶段 `platform/` 抽象，但设备性能统计仍然是混合状态：

- `health.py` 已根据 macOS/NVIDIA 分支读取内存；
- `power_stats.py` 仍直接调用 `nvidia-smi`；
- `gpu_state.py`、CLI、监控 API 仍保留 GPU 专用语义；
- 引擎 `/metrics`、设备指标、请求级指标尚未形成清晰边界。

双平台使用的底层 API 和命令不同：NVIDIA 侧使用 `nvidia-smi`/未来可选 NVML，Apple Silicon 侧使用 `sysctl`、`vm_stat`，功耗/温度等能力也可能不可用或需要权限。因此不能继续在各业务模块中追加 `if darwin`，必须形成统一的设备遥测契约。

本设计把指标分成三类：

1. **设备遥测（Device Telemetry）**：平台硬件/OS 级资源和状态；
2. **引擎指标（Engine Metrics）**：vLLM、llama.cpp、Ollama 等推理引擎自身 `/metrics`；
3. **请求指标（Request Metrics）**：TTFT、TPOT、token、成本、延迟、错误率。

只有第 1 类进入 `DeviceTelemetry` 平台适配层；第 2、3 类不得伪装成设备指标。

## 2. 目标

1. 建立统一、只读、可测试的 `DeviceTelemetry` 契约。
2. 为 Apple Silicon 和 NVIDIA 分别实现平台后端。
3. 将 `health.py`、`power_stats.py`、设备 snapshot、CLI 展示等改为接线层，不再直接调用平台命令。
4. 明确 All-platform 通用层、Platform Adapter 层、Engine Adapter 层的文件归属。
5. API 和 Dashboard 使用 `memory_kind=unified|vram` 等正确语义，不能把统一内存冒充 GPU VRAM。
6. 不可获取的指标返回 `None`，前端显示“不可用”或 `—`，不伪造 `0`。
7. 保留 `gpu_used_mb()` / `gpu_total_mb()` 等旧接口一个兼容周期，内部委托统一遥测层并标记 deprecated。
8. 形成可独立 cherry-pick 的上游特性：核心契约与 NVIDIA/Apple 后端均可在平台无关测试中验证。

## 3. 非目标与反目标

### 非目标

- 不在本设计中实现引擎内部的 KV cache、batch、queue、吞吐等 `/metrics` 指标；它们属于 Engine Metrics Adapter。
- 不强求 Apple Silicon 提供 NVIDIA 同等的功耗、温度、频率、利用率字段。
- 不引入需要 root/sudo 的常驻特权助手；`powermetrics` 如需权限，只能作为可选探针，失败返回 `None`。
- 不改变模型调度三规则、默认不限速原则或模型池路由语义。
- 不把硬件采集命令散落到业务模块。

### 反目标

- Apple Silicon 继续用 `gpu_*` 语义显示统一内存；
- 功耗/温度取不到时返回 0 以“填满”图表；
- 在 `health.py`、`power_stats.py`、`manager.py` 中各自维护平台分支；
- 把引擎 `/metrics` 和设备利用率混成同一组字段；
- 为了采集指标改变本地网关默认不限速或增加默认等待。

## 4. 方案比较（已裁决：方案 A）

### 方案 A：统一 DeviceTelemetry 契约 + 两个平台后端（采用）

新增平台遥测契约与两个后端：通用核心消费 `DeviceSnapshot`，平台适配层负责命令/API 差异，旧 `gpu_*` 保留 shim。优点是边界清晰、后续可加入 AMD/Intel/NPU；代价是需要同步调整 health、功耗采样、API 和 Dashboard。

### 方案 B：分别平台化 health.py 与 power_stats.py（否决）

改动小，但平台判断分散；后续温度、利用率、压力、设备控制仍会重复加分支，继续制造补丁式架构。

### 方案 C：所有平台转换成 GPU 语义（否决）

实现最快，但统一内存、VRAM、功耗不可用等事实会被隐藏，导致调度和用户界面语义错误。

## 5. 三层归属规则（本设计的核心）

### 5.1 All-platform 通用层

这些模块不能直接 import `nvidia-smi`、`vm_stat`、`sysctl` 或平台专用库：

- `DeviceSnapshot`、`DeviceCapabilities`、`DeviceTelemetry` 数据契约；
- `TelemetryHub`、`MetricsAggregator`、请求级 token/延迟/成本聚合；
- SQLite 持久化与时间分桶；
- `/api/snapshot`、新增 `/api/device_metrics` 的序列化与兼容字段；
- Dashboard 通用卡片和“不可用”渲染；
- Prometheus 文本解析器（解析协议，不负责判断硬件平台）。

### 5.2 Platform Adapter 层

只有此层可以感知操作系统和硬件：

- `platform/profile`：平台识别与装配；
- `platform/telemetry.py`：抽象协议、快照和能力类型；
- `platform/nvidia_telemetry.py`：NVIDIA 后端；
- `platform/apple_telemetry.py`：Apple Silicon 后端；
- `platform/probe.py`：`sysctl`、`vm_stat`、端口和预算等基础探针；
- `platform/procguard.py`、设备控制/重置能力；
- 平台专用命令/API 的错误、超时和权限处理。

业务侧只依赖 `DeviceTelemetry` 和 `DeviceControl`，不依赖具体后端。

### 5.3 Engine Adapter 层

引擎指标保持独立：

- `VllmMetricsCollector`；
- `LlamaServerMetricsCollector`；
- Ollama/SGLang 等引擎的 `/metrics` 适配器；
- KV cache、batch、queue、engine throughput、engine-level utilization。

例如：设备利用率属于 DeviceTelemetry；KV cache 使用率属于 Engine Metrics；TTFT 属于 Request Metrics。

## 6. 统一契约

### 6.1 数据类型

```python
@dataclass(frozen=True)
class DeviceCapabilities:
    memory: bool
    utilization: bool
    power: bool
    temperature: bool
    clock: bool
    pressure: bool
    reset: bool

@dataclass(frozen=True)
class DeviceSnapshot:
    platform: str                  # darwin | linux | other
    accelerator: str               # apple_silicon | nvidia | unknown
    memory_kind: str               # unified | vram | unknown
    memory_used_mb: int | None
    memory_total_mb: int | None
    memory_budget_mb: int | None
    utilization_pct: float | None
    power_w: float | None
    temperature_c: float | None
    clock_mhz: int | None
    pressure_level: int | None
    timestamp: float
    sources: dict[str, str]        # per-field source: vm_stat/nvidia-smi/...
```

字段语义：

- `memory_total_mb` = 设备物理可见内存总量；Apple 为物理统一内存，NVIDIA 为 VRAM 总量；
- `memory_budget_mb` = 调度可使用预算；Apple 为 `RAM - reserve`，NVIDIA 为显存策略预算；
- `memory_kind` 决定 UI 文案与调度解释；
- 无法获取的值一律 `None`，不得用 0 伪造；
- `sources` 让诊断页能说明数据来自哪个 API/命令；
- `timestamp` 由采样后端生成，通用层不重新解释。

### 6.2 只读遥测与设备控制分离

设备遥测不得承担有副作用的 reset：

```python
class DeviceTelemetry(Protocol):
    def snapshot(self) -> DeviceSnapshot: ...
    def capabilities(self) -> DeviceCapabilities: ...

class DeviceControl(Protocol):
    def reset(self) -> OperationResult: ...
```

`reset()` 只在后续能力接线任务中实现；没有该能力时返回明确的 unsupported，不执行替代性危险命令。

### 6.3 装配

```python
def telemetry_for_profile(profile: PlatformProfile) -> DeviceTelemetry:
    # darwin → AppleSiliconTelemetry
    # linux + nvidia → NvidiaTelemetry
    # unknown → NullTelemetry（字段 None）
```

装配必须是唯一入口。`health.py`、`power_stats.py`、`manager.py`、Dashboard handler 不能自行重新识别平台。

## 7. 两个平台后端

### 7.1 NVIDIA 后端

第一阶段复用现有 `nvidia-smi` 查询，后续可在不改契约的前提下替换为 NVML：

- memory used/total：`memory.used` / `memory.total`；
- utilization：`utilization.gpu`；
- power：`power.draw`；
- temperature：`temperature.gpu`；
- clock：`clocks.sm` 或等价字段；
- source 字段标记 `nvidia-smi`；
- 任意查询失败只影响对应字段，不让整个 snapshot 抛异常。

### 7.2 Apple Silicon 后端

- memory total：`sysctl hw.memsize`；
- memory used：`vm_stat` 回收页口径；
- memory budget：平台 policy 的 `RAM - reserve`；
- pressure：macOS memory pressure 探针（已有或新增轻量实现）；
- power/temperature/clock/utilization：按权限和系统能力尝试，不能获取则 `None`；
- source 字段分别标记 `sysctl`、`vm_stat`、`memory_pressure`、`powermetrics` 等；
- 禁止为了填充 NVIDIA 对应字段而把统一内存压力或内存使用率冒充 GPU 利用率。

## 8. 现有代码接线规划

| 现有位置 | 改造方向 | 归属 |
|---|---|---|
| `health.py: gpu_used_mb/gpu_total_mb` | 委托 `DeviceTelemetry.snapshot()`；保留 deprecated 兼容函数 | 接线层 |
| `power_stats.py: probe_gpu_power_w` | 改为通用 `probe_device_power_w`，由 telemetry 注入；保留旧函数 shim | 接线层 |
| `manager.py` snapshot | 输出统一 device snapshot，同时保留旧 `gpu_*` 字段一个周期 | 通用核心 |
| `gpu_state.py` | 只消费资源/设备接口；NVIDIA reset 文案和能力移到 DeviceControl | 接线层 + 控制能力 |
| `cli.py` | 根据 `memory_kind` 和 capability 渲染；NVIDIA 专用 reset 仅 capability=true 时展示 | 通用展示层 |
| `telemetry.py` | 组合请求指标与设备指标，不实现硬件探测 | 通用核心 |
| `db.py` / migration | 为设备功耗样本补 platform/accelerator/source 维度，旧表读兼容 | 通用持久化 |
| `dashboard/js/monitor.js` | 设备卡与引擎卡分离，`None` 显示“不可用”/`—` | 通用控制面 |
| `prometheus.py` | 保持引擎 Prometheus 解析，不并入设备后端 | Engine Adapter |

## 9. 数据/API 兼容策略

1. 新增规范化 `/api/device_metrics`，返回 `snapshot`、`capabilities`、采样时间和 sources。
2. `/api/snapshot` 增加 `device` 对象；旧 `gpu_used_mb`、`gpu_total_mb`、`gpu_util_pct` 保留一个兼容周期，由统一快照派生。
3. 功耗采样 API 改为设备中性命名；历史 `gpu_power_samples` 查询接口保留，新增 platform/source 字段或兼容视图，避免已有历史数据丢失。
4. Dashboard 以 `memory_kind`、capabilities 驱动标题和卡片，不用平台名硬编码业务判断。
5. `None` 在 JSON 中保持 `null`，前端统一显示“不可用”，不转换成 0。

## 10. 测试与验收

### 契约测试

- NullTelemetry：所有字段为 `None`，不抛异常；
- DeviceSnapshot 序列化：`None → null`，sources 和 timestamp 保留；
- capabilities 与字段一致；
- 统一层 import 不触发平台命令。

### NVIDIA 后端测试

- mock `nvidia-smi` 多 GPU 输出，验证 used/total/util/power/temp/clock 解析；
- 单字段命令失败时其余字段仍可用；
- 命令超时不阻塞 snapshot；
- 无 NVIDIA 环境返回 NullTelemetry 或字段 None。

### Apple Silicon 后端测试

- mock `sysctl`/`vm_stat`/pressure 输出；
- 验证 `memory_kind=unified`、budget = RAM - reserve；
- 验证 power/temperature 不可用时是 None，不是 0；
- 环境变量 IFF_* 优先、MACFABRIC_* 回落保持兼容。

### 接线与回归

- health、power sampler、snapshot、CLI 均通过注入的 telemetry 工作；
- 引擎指标仍走 engine adapter，不出现在 device snapshot 的错误字段中；
- Apple 沙箱 `:8998` 与 NVIDIA 上游测试均通过；
- 生产 `:8999` 双协议和 Dashboard 设备卡回归。

## 11. 实施顺序

1. **T0：契约与归属锁定**——新增类型、capabilities、字段命名、旧字段兼容策略；不接线。
2. **T1：平台后端**——NVIDIA/Apple/Null 三个实现，命令/API mock 测试。
3. **T2：业务接线**——health、power_stats、manager snapshot、gpu_state、CLI 改为消费统一接口。
4. **T3：持久化与控制面**——设备功耗 schema/API/Dashboard 迁移，兼容旧历史和旧字段。
5. **T4：双平台验收与上游交付**——Mac 沙箱、生产回归、上游 pick 分支和 manifest 对账。

## 12. 待用户确认的细节

1. Apple Silicon 当前无法稳定获得的功耗/温度/频率/设备利用率，是否按本设计返回 `None` 并在 UI 显示“不可用”（推荐），而不是用 0 或统一内存比例伪造？
2. 旧 `gpu_*` 字段保留一个兼容周期后是否移除；本设计建议至少跨一个 InferFabric 上游版本周期。
3. NVIDIA 第一阶段是否继续使用 `nvidia-smi`（无新依赖），后续再可替换 NVML；本设计建议是。

## 13. builder check 裁决记录（2026-11-18，可由用户纠正）

1. Apple Adapter 复用 `platform/probe.py` 原语（sysctl/vm_stat/预算单一事实源），Adapter 只组装快照，不重复实现命令。
2. 内部类型用 Literal/枚举表达有限值，JSON 输出字符串；`sources` key 与字段名一一对应。
3. 采样节奏维持现状：功耗 60s/90 天留存；snapshot 单次调用单一 timestamp，可按现有 TTL 缓存，`/api/device_metrics` 与 `/api/snapshot` 不得长期展示不同快照。
4. 接线清单补全（builder 实测新增）：`model_lifecycle.py`、`process_manager/base.py`、`process_manager/sglang.py`、`health_checker.py`、`proxy/handler.py`（/system 端点仍直调 nvidia-smi）、`cli.py`——全部纳入 T2/T3。
5. Dashboard null 迁移：清理 `store.js` 的 `|| 0`/`|| 32607` 伪造值与 `overview.js` 的 5090D 硬编码上限；`memory_kind` 驱动文案；不支持的能力隐藏卡片填充而非画 0。
6. 测试补充：平台无关契约测试、mock 后端测试、DB migration 回归、Dashboard/API null 契约测试。

## 14. 用户裁决记录（2026-11-18，全部采纳推荐项）

| # | 议题 | 裁决 |
|---|---|---|
| 14.1 | NVIDIA 多 GPU 标量语义 | **标量聚合**：used/total/power 等为跨卡聚合口径；逐卡明细（devices[]）留待多卡路由需求出现再加；配合 14.5 的 device_id 维度预留 |
| 14.2 | Apple 旧 gpu_* 映射 | **明确映射 + UI 弃用**：gpu_used_mb→统一内存 used（调度依赖，不断）、gpu_total_mb→budget B、gpu_util_pct→**null**（不再伪造内存比例）；Dashboard 全部切 device 对象，旧字段仅 API 兼容一个周期后移除 |
| 14.3 | DeviceControl.reset 范围 | **接口 + Apple unsupported**：本期定义 DeviceControl 协议，reset() 仅在 capabilities.reset=true 的 NVIDIA 后端实现；Apple 返回明确 unsupported；gpu_state/CLI reset 逻辑迁移进 DeviceControl |
| 14.4 | 遥测不可用语义 | **分级**：观测类（功耗/温度/利用率采样）fail-open→None，UI 显示不可用；准入与破坏性操作（wait_gpu_free、reset、内存准入闸）fail-closed→保守拒绝或维持现有保守语义 |
| 14.5 | capabilities 静态/动态拆分 | DeviceCapabilities 只声明后端静态能力；字段本次实际可用性由快照 None + sources 表达（builder 代拟，用户未纠正即执行） |
| 14.6 | 功耗样本表迁移 | 新建 device_power_samples(ts, accelerator, device_id, watts, source)；旧 gpu_power_samples 保留只读兼容视图，旧行 platform=unknown，历史数据不丢（builder 代拟，执行） |
| 14.7 | NVIDIA 采集通道 | 本期只用 nvidia-smi，不引入 NVML 依赖；命令缺失→NullTelemetry/字段 None；未来换 NVML 不动契约（builder 代拟，执行） |
| 14.8 | 兼容周期终止条件 | 旧 gpu_* 字段与旧表保留至"对应特性合入上游 + 一个上游发布周期"；删除条件写入 manifest 条目，不现在定死版本号（builder 代拟，执行） |

> §12 原"待用户确认的细节"三条已由本表覆盖（12.1→14.4/14.2、12.2→14.8、12.3→14.7）。
