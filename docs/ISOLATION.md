# MacFabric — 环境隔离策略（2026-11-14）

> 用户要求：模型运行环境必须隔离，不能影响 macOS 系统层面。
> 结论：**采用"用户态自包含"隔离，不采用 Docker**。理由与边界如下。

## 一、为什么不用 Docker（关键事实）

macOS 上的 Docker 是**Linux 虚拟机**（hyperkit/Apple Virtualization），有两条硬限制：

1. **无 GPU 直通**：Apple Virtualization 不暴露 Metal/Accelerate 给容器 →
   llama-server(Metal)、whisper.cpp(Metal)、MLX 全部退化成 VM CPU 模拟，
   推理慢 5–15 倍，"端侧工作站"定位直接失效。这是 Apple 平台限制，非配置问题。
2. **双倍内存开销**：VM 预留内存 + 模型内存，与内存账本 B=RAM−8G 冲突。

Docker 适用于纯 CPU 的非加速服务；对以 Metal 为第一公民的 MacFabric 全量套用 = 自废武功。

## 二、实际采用的隔离边界（已落地）

| 组件 | 隔离形态 | 系统足迹 |
|---|---|---|
| llama-server | 项目内独立二进制 `engines/llama-b12361/`（官方预编译，零依赖） | 无（不写系统目录，不装任何包） |
| whisper.cpp | 项目内源码构建 `engines/whisper/whisper.cpp/build/bin/` + 项目内 cmake tarball | 无 |
| kokoro TTS | 项目内 venv `engines/kokoro/venv/`（pip 完全隔离）+ `python_bin` 显式路径（不走 conda 探测） | 无（已移除 ~/miniconda3 symlink） |
| 网关 | uv venv `.venv/` | 无 |
| OCR | macOS Vision 系统框架（只读调用） | 无 |
| 模型文件 | 全部 `MacFabric/models/` | 无 |
| 运行状态 | `~/.inferfabric/`（数据目录，唯一项目外足迹，符合 XDG 惯例） | 仅此一处 |
| 进程 | 用户态进程，start_new_session 独立进程组；停止=杀进程组 | 无 launchd/系统服务（launchd 脚本提供但默认不激活） |

- 系统级安装为零：不装 Homebrew、不动系统 Python、无 root 操作
- 卸载 = 删项目目录 + `~/.inferfabric`，无残留

## 三、约束传递给新增引擎的规则

1. 引擎必须是项目内自包含产物（独立二进制或 venv），**禁止** pip --user、
   禁止写 /usr、/Library、禁止要求 brew
2. YAML 配置用 `python_bin:`/绝对 `binary_path:` 显式指向项目内路径
3. 需要系统框架（如 Vision）时只做只读 API 调用

## 四、部署范式（MacFabric 与上游 InferFabric 的底层差异点）

> 用户裁决（2026-11-14）：隔离不是个别引擎的做法，而是**所有部署方式的底层范式**。
> 能力包一键安装/卸载必须端到端，不依赖任何手工部署步骤。

### 每个"能力包"= 三个可整体拆除的单元

| 单元 | 位置 | 生命周期 |
|---|---|---|
| 模型文件 | `MacFabric/models/` | 安装时下载（.part→原子改名），卸载时删除 |
| 引擎环境 | `MacFabric/engines/<unit>/`（二进制或 venv） | 首个引用它的模型安装时创建，引用计数归零时整目录 rmtree |
| 配置 | `macfabric_gateway/models.d/<name>.yaml` | 安装时写入（全部路径显式），卸载时删除 |

### 代码落点（已实现）

- **安装**：`POST /admin/packs/download` — 引擎阶段（如 whisper 需构建 →
  `engines/whisper/`，用 `engines/_tools` 内置 cmake，零系统安装）→
  模型下载 → yaml 装机（不启动）
- **卸载**：`POST /admin/packs/uninstall` — 停服务 → 删 yaml → 热重载 →
  删模型文件（仅项目 `models/`，`~/models` 用户数据不碰）→
  `_collect_engine_refs` 引用计数：重载后无剩余模型引用该引擎单元 → 整目录移除 →
  模型池联动清除（`PoolRegistry.purge_candidates`）
- **跨模块联动**：本地模型卸载 / 云模型移除 / provider 删除 →
  池内引用候选自动清除（源模块删除，池不同步即悬空）
- **卸载响应**带 `removed_model_files` / `removed_engine_dir` /
  `pool_candidates_purged` — 清理可审计，不静默

### 卸载 = 零残留验收标准

删项目目录 + `~/.inferfabric` 后系统无任何残留（无 brew 包、无 conda env、
无 launchd 服务、无 /usr /Library 写入）；运行中卸载先停服务再拆环境。

## 五、能力包隔离修订（2026-11-15 用户裁决）

> 能力包（Pack）架构下，"一模型一环境"为**严格独立**：每包复制自己的
> 引擎二进制 / venv，不共享 `engines/`，卸载 = 删包目录，无引用计数。
> 统一的是沙箱方案、目录模板、安装事务和 Supervisor，不是运行时本体。

- 上述 §四 的**引擎引用计数（`_collect_engine_refs`）仅保留给用户导入
  模型的旧路径**；能力包安装/卸载不走该机制。
- 包目录：`~/.inferfabric/packs/<pack_id>/<pack_version>/`（runtime/、
  models/、work/、logs/、tmp/、sandbox/、state/ 均包自有）。
- 卸载语义：确认框列出受影响模型池候选 → 用户确认后自动清除 →
  drain 在途请求（上限 10s，超时强杀进程组、在途请求按 503 返回）→
  整目录删除 → 热重载。详细状态机见
  `docs/superpowers/specs/2026-11-15-capability-packs-design.md`。
