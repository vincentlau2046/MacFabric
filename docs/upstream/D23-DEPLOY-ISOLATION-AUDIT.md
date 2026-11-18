# D23 部署隔离范式 — 上游（x86+NVIDIA）现状审计

> 审计人：inferfabric-pr session · 2026-11-18 · 基线 e453a90（vendor 只读核查）
> 依据：manifest §4 第 11 条（用户裁决 D23：部署绝不影响系统环境；整体卸载/安装必须方便）
> 状态：**主 session 已过目，批准上报**（附一条补充，见 §6）→ 以 issue 形式与上游对齐形态，再切 pick/deploy-isolation

## 1. 上游三种部署形态盘点（实测）

| 形态 | 引擎 | 启动机制 | 自包含性 | 拆除/卸载 |
|---|---|---|---|---|
| Docker | ninfer | `docker run -d --gpus all --rm -v {weight_dir}:/workspace`（process_manager/ninfer.py:225） | 容器层自包含（--rm 短容器、日志轮转 50m×3）；权重宿主目录挂载（未加 `:ro`） | 停止即容器销毁 ✓；**镜像无引用计数、无标签、无 prune 路径** |
| Docker | sglang / vllm(docker) | `cfg.build_docker_cmd()` + `--rm`，优雅 docker stop | 同上 | 同上 |
| conda | vllm(conda) / comfyui / tts / asr | 显式拼 `CONDA_ENVS/<env>/bin/{vllm,python}` 加入 PATH / 直接 exec | **不自包含**：env 建在全局 miniconda3 | **无任何拆除路径**（见 §2） |

## 2. 违反 D23 的问题清单（按严重度）

1. **【高】conda env 全局命名空间 + 项目不管理生命周期**（config.py:42 `CONDA_ENVS = Path.home()/"miniconda3"/"envs"`，YAML 按名引用 `conda_env: qw36-27b-vllm`）：
   - env 创建不在项目内（用户手工 conda create），装了什么、被谁引用，系统无账；
   - 跨项目名冲突；pkg 缓存沉淀在 ~/miniconda3/pkgs（用户级残留）；
   - 无引用计数 → "整体卸载"只能人工 `conda env remove`，极易漏删/误删。
2. **【高】全仓无 uninstall/remove/purge 路径**（grep 证据：零命中）——模型/引擎/env/镜像只增不减，与"整体卸载必须方便"直接冲突。
3. **【中】CONDA_ENVS 硬编码** `~/miniconda3/envs`：无 env var / 配置覆盖，miniconda 装在别处即不可用；也无 venv 等替代解释器入口（fork 的 `python_bin` 显式字段即为此而设，属 P 类随 platform 层）。
4. **【低】ninfer 权重目录挂载未加 `:ro`**：容器理论上可写宿主权重目录（隔离性瑕疵，一行修复）。
5. **【低】docker 镜像无项目标签**：无法区分"本项目拉的镜像"与用户自装镜像 → 无法安全 prune。

## 3. 适配方案建议（x86 表达，非照搬 Mac）

**原则对齐**：Mac 侧"engines/ 独立二进制 + venv + python_bin 显式"= 用户态自包含；x86 侧同原则的本地表达分三层：

- **L1（配置层，小 diff）**：`CONDA_ENVS` 可配置（env var `IFF_CONDA_ENVS` / iff.yaml 覆盖）——机制与上游已有 `IFF_DATA_DIR` 解耦同构；python_bin 显式字段（fork 已有，随 platform/process_manager 线上游化）允许 venv 替代 conda。
- **L2（隔离基底，主体）**：项目托管 env 前缀——`conda create -p <IFF_DATA_DIR>/envs/<name>`（或 venv），env 落在项目数据目录内；packs/ 四模块（runtime_prep = 环境预置、sandbox = 运行隔离、uninstaller = 引用计数拆除、supervisor = 守护）为承载骨架；引擎引用计数 `_collect_engine_refs` 决定 env/镜像可否安全移除。
- **L3（镜像卫生，一行级）**：项目拉取的 docker 镜像统一打 label（`com.inferfabric.managed=true`），prune 只清带标签镜像；ninfer 挂载补 `:ro`。

**切分边界**（与 F4 capability-packs 重叠协商）：deploy-isolation 只带 L1 配置解耦 + L2 四模块基底 + L3 两处小修；packs 目录其余（目录/装拆 API）归 F4。

## 4. 待上游确认的问题（issue 用，4+1 问）

1. conda env 是否接受迁入项目数据目录（`conda create -p` 前缀式）？还是维持全局 env + 仅加引用计数账本？
2. `IFF_CONDA_ENVS` / python_bin 显式字段是否可接受（不改默认行为，只加覆盖入口）？
3. docker 镜像打管理标签 + 作用域 prune 是否可接受？
4. uninstall 端点（CLI `iff remove` / admin API）优先级与形态。
5. `~/miniconda3/pkgs` 缓存残留的承接：拆除路径须同时清理或明确声明 pkgs 占用——`conda clean` 作用域化，或文档化为用户级共享缓存不自动清，二选一（主 session 审阅补充）。

## 5. 验收测试预案（切分支时带）

- test_packs_sandbox.py / test_packs_runtime_prep.py / test_packs_installer.py（fork 平台无关，移植 + IFF_* 改名）
- 新增：conda 前缀 env 的创建/引用计数/拆除闭环单测（subprocess mock，无真实 conda 依赖）
- L3：docker cmd 组装的 label/:ro 断言（纯字符串，无 docker 依赖）

## 6. 主 session 审阅意见（2026-11-18，批准上报）

- 审计结论与分层方案（L1 配置解耦 / L2 项目托管 env + 引用计数 / L3 镜像卫生）**批准**，与 D23 原则和 Mac 侧已验证形态同构，切分边界（vs F4）正确。
- **一条补充**：§2 指出的 `~/miniconda3/pkgs` 用户级缓存残留，方案层没有承接——L2 的前缀 env 拆除后 tarball 仍沉淀在 pkgs。建议并入 L2 验收：拆除路径须同时清理（或明确声明）本项目 env 对应的 pkgs 占用（`conda clean` 作用域化，或文档化"pkgs 为用户级共享缓存、不自动清"），二选一，进 issue 问题清单作为第 5 问。
- 上报形态同意用 **issue**（4+1 问打包，比散在 PR #1/#2 评论里干净）；PR #2 建议只在描述里加一行链接。
- 验收测试预案通过；注意 IFF_* 改名按 PR #2 已确立的双读别名纪律执行。
