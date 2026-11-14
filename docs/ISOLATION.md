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
