# CHERRY-PICK-MANIFEST — MacFabric → InferFabric 上游摘取清单

> 基线：vendor/InferFabric HEAD `e453a90`（D20 审计基线）。上游前进时由上游责任人 rebase。
> 对账状态：`待摘取` / `已提交 PR` / `已合入` / `被退回`。维护人：peer session `inferfabric-pr`。
> 分类（D20）：**A=通用修复**（可直接摘）· **P=平台相关**（并入 platform/ 层后摘）· **M=Mac 专属**（留 fork，不摘）。

## 1. 34 个演进文件三级归类（D20 diff 审计，2026-11-18）

### A 类 — 通用修复/增强，可摘（逐条出 pick 分支）

| 文件 | 内容摘要 | 归属批次 |
|---|---|---|
| proxy/forwarder.py | usage 双 chunk 取 max；/admin CORS 收紧；Anthropic base 路径双约定拼接 | B1 |
| proxy/sse_buffer.py | 流式缓冲修复（= saw_done/saw_error 观测位 hunk ~10 行）→ **已核销：随 F5 带上**（D 桶 stream_state 前置，2026-11-18 裁决） | B1→F5 |
| proxy/request_logger.py | 日志字段补全 | B1 |
| ratelimit.py | 限流修复（= observe 模式 effective_timeout hunk ~12 行）→ **已核销：随 F5 带上**（池预算契约前置，2026-11-18 裁决） | B1→F5 |
| telemetry.py | 指标口径修复 | B1 |
| request_log_db.py | key_name/metadata 字段 + route 兜底（NOT NULL 防静默丢弃） | B1 |
| db.py | 同上 schema 演进 | B1 |
| tune.py / proxy/async_server.py / __init__.py | 版本与路由注册零碎修正 | B1 |
| cloud_discovery.py | 斜杠模型精确解析（resolve_cloud_model，含 spec 短名键兜底）；floor 兜底补注册前缀键；resolve_route 全名优先 | B2 |
| proxy_manager.py | 云发现单飞（单锁单线程，失败可重试）。**fabric-\* 池命名已移出**（裁决 2026-11-18：与 model_pool/* 深度纠缠且属用户可见命名变更，归 B3/F5 一并制作） | B2 |
| model_pool/dispatch.py + pool_forward.py + config.py + registry.py + catalog.py + __init__.py | 池 v2：priority=index*10 全量重建、CAS 回写、409 重试、selector 证据编译期推导（accept_declared 默认 true） | B2 |
| dashboard/fragments/model-pools.html + js/model-pools.js | 池 v2 控制面对应 UI | B2 |
| security/auth_facade.py + security/admin.py | 鉴权 facade 与 admin 修正（marker/db 缺失不 crashloop） | B3 |
| model_discovery.py | 端口分配泛化 + 探测委托（**P 成分**：探测调用已改 platform.probe，摘取时随 platform 层先行） | B3(P) |

### P 类 — 平台相关（并入 platform/ 层，随 platform 分支整体摘）

| 文件 | 内容 |
|---|---|
| platform/（新增包，本工作区 M1 产物） | ResourceLedger 接口 + umem/vram 双后端 + probe + procguard + engines + detect |
| manager.py | `_admit_memory` 账本准入闸（G1）；已改从 platform 导入 |
| gpu_state.py / health.py / model_lifecycle.py | 端口 PID 委托 probe；macOS 跳过 GPU 准入闸 |
| process_manager/base.py + llama_cpp.py + tts.py + asr.py | `python_bin` 显式路径；lsof 停止路径；Metal 二进制配置化 |
| config.py | `MACFABRIC_STATE_DIR`/`MACFABRIC_MODELS_DIR` 解耦（机制通用，命名可上游化改 IFF_*） |
| memory_ledger.py + mac_platform.py | 迁移期 shim（摘取时可不带，上游直接用 platform/） |

### M 类 — Mac 专属，留 fork（不上游）

| 文件 | 内容 |
|---|---|
| proxy/chat_handlers.py（packs 部分） | pack 卸载 503 闸（依赖 packs 体系；上游若要 packs 则随 B4 整体摘） |
| proxy/pack_handlers.py + packs/ + jobs.py + proxy/handler.py（admin 扩展大头） | 能力包体系 + jobs + admin 端面（**B4 候选**：以新文件为主可摘性好，是否上游化由上游责任人裁决） |
| proxy/anthropic_bridge.py + anthropic_translate.py + responses_bridge.py | 协议桥三件套（**B5 候选**：翻译层上游同样适用，金标录制件已备） |

## 2. 首批摘取条目（F1–F10 粒度）

| # | 特性域 | pick 分支 | commit 范围 | 新增文件 | 触碰上游文件 | 验收测试 | 状态 |
|---|---|---|---|---|---|---|---|
| 1 | F1 三协议入口 | pick/protocol-bridges | 待切 | anthropic_translate.py、anthropic_bridge.py、responses_bridge.py | chat_handlers/handler（装配点） | tests/unit/test_anthropic_translate.py + golden 录制件 | 待摘取 |
| 2 | F2 平台资源账本 | pick/platform-layer | 移植自 40bb02e..`d392007`，落为上游基线 2 commits：`7cc392a`（platform 包+4 套测试）+ `331c315`（5 导入点装配） | platform/ 全包 7 文件 + test_platform_*.py 4 文件 | manager/gpu_state/health/model_lifecycle/model_discovery（5 处导入点注入） | unit 1894 绿 + integration 118 绿（darwin 原生 + IFF_FORCE_PLATFORM=linux mock 双跑） | 已提交 PR：[InferFabric#2](https://github.com/vincentlau2046/InferFabric/pull/2)（2026-11-18） |
| 3 | F4 能力包 | pick/capability-packs | 待切 | packs/、pack_handlers.py、jobs.py | handler.py admin 面、chat_handlers（503 闸） | test_packs_*.py（11 文件）+ test_jobs.py | 待摘取 |
| 4 | F5 模型池 v2 | pick/pool-v2 | `5feff43`（池 v2 核心+传输+命名+前置 hunk）+ `60f9689`（测试契约更新），已 rebase 到 main `7ab0cf8`（PR #1 合入后，2026-11-18） | test_pool_deadline_recovery / test_pool_health_policy / test_pool_prefix_fabric / test_pool_transport_contract（E 桶用例拆出归 #12） | model_pool/ 6 文件（A 池v2核心+B 命名v2+C 单飞调用侧+D 结构化传输）+ proxy/chat_handlers.py（`_forward_request_ex` 注入+池分支门）+ proxy/handler.py（路由门+/v1/models 发号，2 处 1 行）+ proxy/sse_buffer.py（观测位 hunk，B1 核销）+ ratelimit.py（observe effective_timeout hunk，B1 核销，D24 措辞已入 PR）+ security/auth_facade.py + security/admin.py（pools 前缀门各 1 行）+ dashboard 两件 | 4 套移植测试 + vendor 测试套更新到 v2 契约（dispatch 缝线 `_forward_request_ex`、池键 flash、fabric- 命名、面板 DOM/CAS），unit+integration 2034 绿（darwin 原生）；**依赖 PR #1 先合入**（C 调用侧单飞） | **已合入**：[InferFabric#4](https://github.com/vincentlau2046/InferFabric/pull/4)（2026-11-18 13:01 approve with rebase，main=`52baf04`+`8bdec97`+`fd1c017`） |
| 5 | F6 云聚合修复 | pick/cloud-fixes | `3670d40`..`94d5bd7`（2 commits，基线 e453a90） | test_cloud_route_resolution.py、test_cloud_discovery_singleflight.py | cloud_discovery.py、proxy_manager.py、proxy/chat_handlers.py + proxy/handler.py（调用侧各 1-3 行注入） | 单测：unit 1882 绿 ×2 + integration 118 绿（本机验证 2026-11-18） | 已提交 PR：[InferFabric#1](https://github.com/vincentlau2046/InferFabric/pull/1)（2026-11-18） |

> **F6 制作记录**（inferfabric-pr session）：
> ① 单飞测试中"池 dispatch 调用侧 background=True"断言用例移出，随 F5 pool-v2 摘取；② **floor 兜底补前缀键 hunk 已撤出**——与上游既有契约测试 `TestShortNameCollisionContract`（碰撞整条跳过）冲突，属行为变更非纯修复，是否上游化待上游责任人在 PR #1 讨论区裁决（PR 描述"Not included"节已说明）；③ `test_r9_anomaly_collector.py::test_query_since` 为上游既有 flaky（pristine 10 连跑失败 3 次），与 F6 无关；④ fabric-* 池命名从 F6/B2 剔除归 F5（Q1 裁决）。
| 6 | F7 安全门禁 | pick/security-fixes | 待切 | — | security/*、db.py、handler.py security 面 | test_admin_auth.py | 待摘取 |
>
> **F2 制作注记**（主 session）：范围已扩展至 `d392007`——终审 Important-1 修复落在 procguard.py（launchctl/systemctl 返回码校验 + systemd enable --now + guard_for_profile 强制显式 label，防覆写生产 plist）。**摘取必须包含该修复**，否则上游拿到的是 fail-silent 版 install。
>
> **F2 制作注记**（inferfabric-pr session，2026-11-18）：
> ① procguard fail-visible 修复（d392007）已包含 ✓；② env 命名按 §1 P 类既定原则上游化：`MACFABRIC_FORCE_PLATFORM→IFF_FORCE_PLATFORM`、`MACFABRIC_RESERVE_MB→IFF_RESERVE_MB`、`MACFABRIC_STATE_DIR→IFF_DATA_DIR`（与上游既有 env 约定对齐），测试同步；**追加（d2636fc，对齐 fork 7bbf3c4）**：detect/probe 已加 IFF_* 优先 + MACFABRIC_* 回落双读别名，两边 platform 文件除别名行外逐字一致，后续 pick 零重命名噪音——fork 侧 `_policy_reserve_mb` 仍单读 MACFABRIC_STATE_DIR，建议 fork 补对称别名行后两边完全一致；③ **未随带**：mac_platform/memory_ledger shim 两文件及其 3 个 shim 兼容用例（上游无 shim）；llama_cpp 停进程即睡眠语义（改 Linux 可见行为，留 fork 待议）；model_discovery 额外 scan_bases 与根级散置 GGUF 扫描（Mac 目录习惯，M 类）；④ TestDeployEngineAdoption 补平台钉定（probe.IS_MACOS→False），VRAM 守卫用例在统一内存机器确定性可跑（C2 纪律补强，已入 PR）。
>
> **F2 评审修复**（inferfabric-pr session，2026-11-18，REQUEST-CHANGES 响应已推送 `81de082` + PR 评论逐项说明）：① `ledger_mode` 落为真解析字段（ModelConfig 新字段 + 模板 emit `ledger_mode:`，ModeOf 读实值，RESIDENT 层激活）；② switch() 准入闸移到 already-running 检查后（含时序回归测试）；③ pid_on_port 恢复 v1 契约（timeout=5、异常传播 fail-visible，双后端直测）；④ auto_deploy 已配置即早退；测试 nits 全收（reload 遥留/Path.home/直测补齐）。fork 侧同修由 peer 执行保 parity。
| 7 | F8 守护与隔离 | （随 2 platform-layer） | 已随 PR #2 `7cc392a` 带入（procguard fail-visible 版） | procguard.py | —（launchd/systemd 脚本上游等价物未带，fork 的 gateway-launchd.sh 留 M 类） | test_platform_vram_procguard_engines.py（随 PR #2） | 已提交 PR：随 [InferFabric#2](https://github.com/vincentlau2046/InferFabric/pull/2) |
| 8 | F9 Dashboard 新页 | pick/dashboard-pages | 未实施 | M2 产出 packs/security/connect 三 fragment | dashboard/__init__.py 注册点 | M2 验收 | 未实施 |
| 9 | F10 Connect 托管 | pick/connect-clients | 未实施 | M3 产出 platform/clients.py | dashboard 注册点 | M3 验收 | 未实施 |
| 10 | F3 引擎矩阵 | （随 2 platform-layer） | 已随 PR #2 `7cc392a` 带入 | engines.py | — | 同 2 | 已提交 PR：随 [InferFabric#2](https://github.com/vincentlau2046/InferFabric/pull/2) |

## 3. 摘取纪律（重申）

- 新功能进新文件；触碰上游文件的 diff 必须是注入点级别。
- 每条目附验收测试，要求在上游平台（含 CUDA 机）可跑；平台探测 mock env 上游化为 `IFF_FORCE_PLATFORM`（F2 制作时已改名，fork 侧仍为 MACFABRIC_FORCE_PLATFORM）。
- pick 分支基于 `e453a90` 切出，上游前进由上游责任人 rebase。
- **限流纪律（D24，用户裁决 2026-11-18）**：本地网关默认不限速（rpm=0 永不改变）；ratelimit 相关 diff 的 PR 描述必须写明"无默认行为变更"；任何新增限流配置/默认值改动单独报备用户裁决。F5 携带的 ratelimit hunk = observe 等待语义修复（非限流变更），PR 描述照此表述。

### 3.1 与主仓责任人的 PR 协同协议（用户指示 2026-11-18，防空等待）

**节奏与触发**
1. 双向 30min 循环：我侧 cron 巡检（PR/Issue API 全量比对 manifest 已知状态）；上游承诺评审循环 ~30min（Issue #3 14:14Z 整合评论书面确认）。
2. **主动通知义务（我侧）**：每次新开 PR / 推送修复 commit 后，**立即**在对应 PR 发一条简短 "pushed，ready for re-review（逐项对账见上）" 评论——不等巡检、不依赖 GitHub 事件通知（explicit fetch 不更新 tracking refs 的教训已在 #4 出现过）。
3. **评审响应时限**：上游 verdict 进来后，blocking 项当日修完重推，同批 nits 一并处理，逐项回帖对账（#2/#4 模式）。

**空等待防护**
4. ping 规则：push/评论后等满 2 个巡检周期（~1h）仍无评审动静 → 礼貌 ping 一次；再无回应不再追加，转报用户。
5. 裁决类等待不空转：等方案/行为变更裁决期间，转做本地可推进的其它 manifest 条目（F1/F4/F7、entry #12 等），裁决回来再切回。
6. 分工边界（依 Issue #3 整合评论）：上游责任人=本地镜像/迁移运维 + 物理 CUDA 验收；我=inferfabric-pr=L3b、uninstall CLI、L1（延后）及后续 manifest 条目的 PR 制作与评审响应。

**状态落盘**
7. manifest 每次状态变化即更新并 commit（维护人=inferfabric-pr）；跨会话交接以 manifest 为唯一对账源，Issue/PR 侧以最新带 "single source of truth" 声明的评论为准。

## 4. D23 部署隔离范式条目（用户裁决 2026-11-18：坚持并上游推广）

| # | 特性域 | pick 分支 | commit 范围 | 新增文件 | 触碰上游文件 | 验收测试 | 状态 |
|---|---|---|---|---|---|---|---|
| 11 | F3 部署隔离范式（推 x86+NVIDIA） | pick/deploy-isolation | 待切 | packs/runtime_prep.py、packs/sandbox.py、packs/uninstaller.py、packs/supervisor.py、docs/ISOLATION.md | process_manager/base.py（python_bin 注入、引擎引用计数 `_collect_engine_refs`）、config.py | test_packs_sandbox.py、test_packs_runtime_prep.py、test_packs_installer.py（平台无关） | 审计已上报上游：[InferFabric#3](https://github.com/vincentlau2046/InferFabric/issues/3)（5 问打包单 issue，2026-11-18）；PR #2 描述已附链接。**以 issue #3 14:14Z 整合评论为唯一事实源（取代其前两条）**：① docker 迁移（qwen3-vl-4b/gemma4-31b-vl/ovis-ocr2）批准、无需代码 PR（上游本地运维）；② ComfyUI 豁免=终局；③ **L3a `:ro` 已完成**（上游 88c64af）；④ **L3b 镜像标签+作用域 prune → 指派本 session**（小 PR 先行；**已完成并合入上游 [PR #6](https://github.com/vincentlau2046/InferFabric/pull/6)**（2026-11-18，re-verified approve 评论 6983021881，rebase 合入 main：`42fd501`+`402a98d`），见下 L3b 注记）；⑤ **L2-uninstall CLI（`iff remove`+引擎引用计数+dry-run，CLI 先行，dashboard 入口同弧线不阻塞）→ 指派本 session**，本 issue 主体、下一个实质 PR，issue 保持 open 直至其落地（**[PR #7](https://github.com/vincentlau2046/InferFabric/pull/7)** 已合入上游（2026-11-18 16:01Z，re-verified approve 6983959494，rebase 合入 `b233606`+`5e5ddde`+`50816a3`）；**issue #3 同日 16:01:49Z 关闭**，见下 uninstall 注记与关闭记录）；⑥ L1（IFF_CONDA_ENVS+python_bin）延后至三模型 docker 迁移完成后；⑦ Q5 pkgs=用户级共享缓存不自动清=终局。本 session 已回帖确认（2026-11-18，comment 6981444580）：接 L3b + uninstall CLI，顺序 L3b 先行。原 PR-A/PR-B 切分提案被整合表取代，作废。 |

> **L3b 制作注记**（inferfabric-pr session，2026-11-18，分支 `pick/l3b-managed-images` @ `b7167d7`，基线 `fd1c017`）：
> ① **技术前提**：docker 镜像 label 是 build-time 的，pull 下来的镜像无法事后打标 → `docker image prune --filter label=…` 对 pull 镜像永远不匹配。故 "managed" 以两路表达：**容器 label**（网关发出的每条 `docker run` 带 `--label com.inferfabric.managed`，vllm/sglang `build_docker_cmd` + ninfer docker run）+ **项目台账**（`IFF_DATA_DIR/image_ledger.json`，引擎启动路径显式 `ensure_image_pulled` 替代 docker-run 隐式自动拉取）。
> ② **prune 不变量（代码+测试强制）**：只 rmi 台账内且无任何 models.d 配置引用（vllm/sglang/ninfer `docker_image`）的 ref；**永不发 `docker image prune`**（测试断言任何 argv 不得含 `prune`）；rmi 失败 fail-visible 且 ref 留在台账（删不掉仍是我们的责任）；dry-run 零 docker 调用。Q5 corollary 写入模块 docstring（`~/miniconda3/pkgs` 用户级共享缓存永不自动清）。
> ③ **语义**：显式拉取 fail-open（拉取失败仅告警，后续 docker run 自会显性失败）；台账写失败绝不抛（记账不得阻断引擎启动）。
> ④ 触碰上游文件仅 config.py 每引擎 4 行 label 注入 + 三个 process_manager 启动路径 8 行接线；其余为新文件。
> ⑤ 测试：19 新用例（纯逻辑，fake run/tmp_path，无 docker/GPU/网络）；上游基线全量 unit+integration **2115 绿**。
> ⑥ 机制提案已在 issue #3 comment 6981562467 备案并邀请否决（若维护人偏好 managed-tag 命名空间等替代方案，台账形状尚无下游依赖，可重做）；PR #6 已按 §3.1 即时发 ready-for-review 评论（6981817026）并回链 #3。**uninstall CLI（⑤）为下一实质 PR，将直接消费 `ManagedImageLedger`/`collect_image_refs`。** ⑦ 上游复审两轮：hardening（digest 记账+台账锁/revision）推送 `9417aed` 并获 re-verified approve（6983021881），rebase 合入 main；PR #6 关闭。
>
> **L2-uninstall 制作注记**（inferfabric-pr session，2026-11-18，分支 `pick/uninstall-cli` @ `4fc3d7f` → 上游 rebase 合入 `50816a3`，基线 main（`a4af613`，含 #5/#6 合入）：
> ① 新文件 `inferfabric/uninstaller.py`：`collect_engine_refs` 是唯一可删判据（envs: vllm/sglang/comfyui/tts/asr 的 `conda_env`；images: vllm/sglang/ninfer 的 `docker_image`），`extra_sources` 可注入 fork 侧引用源（packs/未来项目内 env 前缀）——peer 要求的"引用源接口可注入、路径假设不写死"已落；② `iff remove model`：停服务失败即中止（无"活进程+删配置"孤儿）、默认 blocked 于池候选引用、`--purge-pools` 原子写+revision 递增+写前 `load_pools_dict` 复验，权重只报告不删（HF 缓存共享）；③ `iff remove env`：CONDA_ENVS 直接子目录包含性校验、conda 优先、`--force` 才 rmtree；Q5 pkgs 永不触碰（输出 note 明示）；④ `iff remove image`：引用计数 + 台账双门禁，rmi 失败 ref 留台账，永不全局 prune；⑤ 破坏性命令两段式：无 `--yes` 只打计划并 exit 1、`--dry-run` exit 0、`--yes` 执行；⑥ 测试 29 新用例，上游基线全量 unit+integration **2144 绿**；⑦ 已按 §3.1 即时发 ready-for-review 评论（6981988629）；**遗留待裁决**：`--purge-weights` 未含（PR 内明示留后续）、dashboard 移除入口同弧线后续、L1 落地后 env 前缀改项目内（引用源接口已备）。
>
> **L2-uninstall 评审修复**（inferfabric-pr session，2026-11-18，REQUEST-CHANGES 6983105760 → 修复推送 `4fc3d7f`，逐项评论 6983465589）：① env 测试密闭化（monkeypatch `shutil.which=None`，不再误用宿主真 conda；`--force` 分支真被覆盖）；② 池引用门禁 fail-closed：不可读/非法 `model_pools.yaml` 抛 `PoolsConfigError`，`remove_model` 在任何副作用前中止（不再静默当无引用删配置）；③ `--purge-pools` 走活 registry CAS（GET raw+revision → PUT expected_revision，registry 校验+递增+落盘+发布快照，proxy 即时生效；冲突刷新重试一次；无 proxy 时 CLI 单写者本地原子写并报 `pending`；坏 JSON 绝不回落本地写），报告带 `pool-reload` 状态；④ 本地构建镜像以 `.Id` 记账（`image_identity_value`：RepoDigests 优先，否则 Image ID），prune/remove 复核同一身份，`ninfer:*` 不再死路；⑤ env 根改为 `<IFF_DATA_DIR>/envs`（项目托管前缀），`~/miniconda3/envs` 用户级遗留只读，缺前缀消息明示；nits：dry-run 忠实计划（无身份→blocked）、scenario 漂移进报告（`scenarios.yaml`/`active_scenarios.yaml`，不代删）、CLI 三段式测试（dry-run exit0 / 无 --yes exit1 / --yes 执行）。验证：全量 unit+integration **2248 绿**（darwin + IFF_FORCE_PLATFORM=linux）。`extra_sources` 保留为 fork 注入点（上游无 pack 调用方，测试覆盖可调用源）；`ensure_image_pulled` 预拉 stall 留 #6 起源 follow-up。
>
> **issue #3 关闭记录**（2026-11-18 16:01:49Z，维护人 summary 评论 6983970272）：全部批准项落地——L3a `:ro`（`88c64af`）、L3b（#6）、L2-uninstall（#7）、设备遥测 enabler（#5）、Q5 声明。**遗留 follow-up（维护人明示非阻塞）**：① L1 `IFF_CONDA_ENVS`+`python_bin`（延后至维护侧剩余 docker 迁移完成）；② dashboard `iff remove` 入口（同弧线下一 UI 任务）；③ 移除后 `scenarios.yaml` 漂移检查（#7 审查 nit）；④ 首次拉取 stall 双倍（#6/#7 nit）；⑤ 剩余 docker 迁移目标 `qwen3-vl-4b`/`gemma4-31b-vl`/`ovis-ocr2`（维护侧）。维护人：②–④「若要跟踪可自开 issue」。**已按 D 落地**：用户裁决（经 peer 转达）「按 D 开，细化照你说的」→ 已开上游汇总 issue [InferFabric#8](https://github.com/vincentlau2046/InferFabric/issues/8)（2026-11-19，backlog tracker、非阻塞、不承诺排期；②标注“下一个 UI PR 时顺手做”，③标注症状+检测方法，④标注复现条件+“仅为观察、无根因”）。候选曾为：A=3 个独立 issue；B=仅 dashboard；C=不另开仅台账；D=1 个汇总 issue。
>
> **issue #8 跟进**（inferfabric-pr session，2026-11-19）：维护人把 tracker 转为带 owner 矩阵（评论 6996974784，②③ 指派 counterpart=本 session，① 随下一 UI PR）并完成 ③ 实测（评论 6997042427：busybox 显式 pull 9.33s vs run 自动拉 9.72s——**无系统性双拉**，inspect-first 结构保证；真实暴露面=失败路径：显式 pull 失败被吞后 docker run **无超时**隐式重拉）。用户裁决「按 2′ 做，①② 排期 session 定」→ 本 session 在 #8 回帖决策（6997995954）：
> - ② **PR #9**（pick/scenario-drift）：`find_scenario_drift` 检测式比对（models.d keys+served names vs 两侧车顶层键），report-only、侧车永不改、不可读侧车显性上报；`iff models` 打漂移警告；7 新测试，全量 2254 绿（1 个上游既有 flake）。
> - ③ **PR #10**（pick/pull-failfast）：选项 2′ = start path 消费 `ensure_image_pulled` 结构化结果，`status=error` 时**不发 docker run** 直接中止（错误含 stderr 摘要+重试指引）；`ensure_image_pulled` 失败结果新增 `detail`；docker run argv 零改动；3 新 abort 测试 + 3 个存量 start 测试补显式 pull-success 桩（其假 run 从未模拟 docker inspect，潜在问题被 fail-fast 暴露）；全量 2252 绿（darwin+linux）。
> - ① dashboard `iff remove` 入口：随下一 UI PR（peer 弧线协调），验收门槛=真实浏览器交互测试（维护人明示）。
> 两 PR 均 §3.1 即时 ready-for-review（#9 评论 6998096851、#10 评论 6998260401）。 维护人回帖确认三条全收并更新矩阵（6998050891），附 PR #10 三点评审清单：本轮已逐点自查（(a) inspect 30s 超时只落入 pull 步骤，非 ok 一律 abort；(b) `_try_adopt` 首行镜像身份校验，不匹配走重建落入闸门、匹配则镜像必然在场且收养路径不发 docker run；(c) 已实现），并将三点取证作为评论贴到 #10（6998455758），不改码等评审。
>
> **评审结果**（2026-11-19）：
> - **PR #10 已合并**（APPROVE-WITH-NITS，rebase 为 `ba9e56f`；clean worktree 2252 绿）。4 个 nit 均非阻塞（过时 docstring、wake 边缘→已记入 #8 follow-up（离线+inspect 瞬时失败会 abort 本可成功的启动；廉价加固=失败后补一次本地 inspect）、2 个测试未断言 retry 提示、闸门块三处重复）；维护人在 #8 关闭矩阵中标记 item 3 **Done**。
> - **PR #9 REQUEST-CHANGES**（2 Blocking + 3 Nits）→ 已修并推送 `2f19b76`：B1 baseline 收窄为 config 名集合（loader 双双 `models.get()` 按 config 名取键，served-name 键是死条目必须上报，对应测试反置）；B2 两个 CLI 测试 monkeypatch `inferfabric.config.APPLIED_SCENARIOS_FILE`（原测试在真机上被 `~/.inferfabric/active_scenarios.yaml` 泄漏打爆——并更正 PR body 归因：那次 1 failed 是本 PR 的锅而非 r9 flake）；N1 cmd_models 漂移检查 fail-open 包裹；N3 补 list/空侧车形状 + 双文件同漂测试。2256 passed（唯一失败仍为上游 r9 flake），§3.1 评论 6998984651，等复审。 维护人复审 **APPROVED 并合并**（rebase 为 `2fe7128`，re-verified 2257 passed / 0 failed + live drift check 正确；2026-11-19T03:58Z）。issue #8 矩阵：item 2 **Done**、item 3 **Done**，仅剩 item 1（随下一 UI PR，owner=peer 弧线）；评审 nit 遗留台账（不排期）：`APPLIED_SCENARIOS_FILE` 忽略 `IFF_DATA_DIR`（上游 config.py:35 既有）+ pull 闸门 inspect 瞬时失败边缘。issue #8 保持 open 仅因 item 1。

**范式原则（用户原话裁决）**：部署不得影响系统环境；整体卸载/安装必须方便（一键化、容器化拆除）。Mac 侧表达 = 用户态自包含（engines/ 独立二进制 + venv + `python_bin` 显式）；**x86+NVIDIA 侧不是照搬 Mac 路径，而是同一原则的本地表达**——上游既有 Docker（ninfer/sglang）与 conda env 路径需审计：容器/venv 是否项目内自包含、卸载是否引用计数拆除、有无系统级残留（conda 全局、系统 site-packages、/usr/local 二进制）。产出物 = 适配方案 + 对应 pick 分支，先在 PR #1 讨论区或单独 issue 与上游对齐形态再动手。

## 5. F5 分桶裁决新增条目（2026-11-18 第二封报备，8 桶全量分类后）

| # | 特性域 | pick 分支 | 内容 | 状态 |
|---|---|---|---|---|
| 12 | 池观测/摘要（E 桶 ~257 行，bdd6e4b） | pick/pool-summary-observability | 纯增量观测体系，单立；**判据=剥离后测试是否自洽**，若剥离致 A/D 语义不完整需改随 F5 带上，须先报主 session 批准 | 待制作 |
| 13 | 跨池唯一校验移除（H 桶 -24 行） | （待议） | 行为放宽变更，单立"行为变更待议"，不进纯修复批次 | 待议 |
| 14 | 慢模型容忍默认值（G 桶 ~12 行，117e4d9） | （待议） | 行为默认值变更，单立"行为变更待议"，与 floor 兜底同性质 | 待议 |
| 15 | DeviceTelemetry 双平台设备遥测 | pick/device-telemetry | 移植自 `2a346e1..2574b3b`（8 commits），落为上游基线 2 commits：`f8efadc`（feat：契约+双后端+接线+v011）+ `e7b65dd`（test：6 新测试文件 + vendor 套迁移），基线 `fd1c017`（main，含 PR #2/#4） | platform/telemetry.py + apple_telemetry.py + nvidia_telemetry.py、migrations/v011_device_power_samples.py、test_platform_telemetry_{contract,backends}.py、test_device_telemetry_wiring.py、test_device_power_persistence.py、test_device_api_contract.py、test_dashboard_device_contract.py | health.py、manager.py、gpu_state.py、model_lifecycle.py、interfaces.py、health_checker.py、cli.py、db.py、power_stats.py、telemetry.py、process_manager/{base,facade,sglang}.py、proxy/handler.py、dashboard store/overview/monitor + base.html（注入点级）+ vendor 测试套迁移 9 文件 | 上游基线全量：unit+integration **2178 绿**（PR #5 评审修复后；darwin 原生与 IFF_FORCE_PLATFORM=linux 各跑一过，仅余上游既有 flake test_r9::test_query_since）；fork 侧证据：unit 421 绿（darwin 原生）+ IFF_FORCE_PLATFORM=linux mock 28 绿 + :8998 隔离沙箱 HTTP 验收（docs/qa/2026-11-18-device-telemetry.md）；**物理 CUDA 验收为上游独立门**；依赖 F2 platform-layer（PR #2 已合入） | **已提交 PR**：[InferFabric#5](https://github.com/vincentlau2046/InferFabric/pull/5)（2026-11-18）；**评审 REQUEST-CHANGES 已修复推送 `f8e4dc5`（逐项评论 6982835210），待上游复审**。退役条件：上游合入 + 一个发布周期后移除 gpu_* 兼容层/兼容视图；无 NVML；无 D24 限流变更（PR 描述已照 D24 措辞声明） |

> **F5 分桶记录**：D 桶（结构化传输 e48401a）随 F5 带上——A 核心构建在其 `_forward_request_ex` suppress 模式之上，拆开不自洽，且 D 本身是传输正确性修复（裁决①，2026-11-18）；F 桶（purge_candidates 联动）归 D23 条目域（依赖 F6 已撤出的 excluded_models 语义，留 fork 待议）。
>
> **F15 制作注记**（inferfabric-pr session，2026-11-18）：① 移植方式=映射 diff（`macfabric_gateway/`→上游根）整体套用 + 4 文件 rejects 手补（health/model_lifecycle/manager/routes 表）；② fork 侧缺失的 vendor 测试套（fork 测试目录结构不同）按 F5 先例自行迁移 9 文件到遥测契约（snapshot 桩 NullTelemetry、system_info 快照投影重写、VRAM 守卫注入伪遥测、PowerSampler 遥测化、monitor.js 契约改 /api/device_power + 数据驱动 W 轴）；③ health.py 的 platform probe import 随重写失去使用者，已删除（fork 侧保留为死 import，parity 核对时注意此一处有意差异）；④ 无 NVML / 无 D24 限流变更 / 物理 CUDA 验收留上游独立门（PR 描述均已声明）；⑤ v011 回滚需迁移前 SQLite 备份（QA §4 已写入 PR 描述）。
>
> **F15 评审修复**（inferfabric-pr session，2026-11-18，REQUEST-CHANGES → 修复推送 `f8e4dc5` + PR 评论 6982835210 逐项说明）：BLOCKING 1 = `DeviceControl.reset(force=False)` 进入契约（protocol/Null/NVIDIA），force 仅豁免目标卡占用门禁、不放大未限定范围的 `-pm`/`-r` 回落；`RESET_IDLE_THRESHOLD_MB` 1024→2048 与 `GPU_FREE_THRESHOLD_MB` 对齐；生产调用点（model_lifecycle×3、gpu_state.force_reset、CLI gpu-clear、`POST /admin/gpu-clear`、force_kill_all）全部 force=True。BLOCKING 2 = `check_vram_budget` 对 `telemetry is None` / `snapshot() is None` 返回 fail-closed error dict；TTS deploy-failure 测试注入 `_ok_telemetry()` 并 pin 非 macOS（评审在 Linux 上看到的 3 个失败即此路径，darwin 因 `not IS_MACOS` 守卫跳过故本地不可见）。Secondary = `/api/power` 改 aggregate 优先、仅窗口无 aggregate 时整段回落 legacy，永不合并，新增 `stream` 字段（选 redirect 而非 dual-write，避免复活混合流与跨流插值）。验证：TTS 36 绿（darwin + IFF_FORCE_PLATFORM=linux）；全量 unit+integration 2178 绿双平台。无转发核心 / dependency 变更。
>
> **F5 评审修复**（inferfabric-pr session，2026-11-18，REQUEST-CHANGES 响应已推送 `6d86f7c` + PR 评论逐项说明）：blocker=存量池键回落（`_resolve_pool_snap` 规范名未命中回落原短名，fabric- 重命名不切断未迁移配置，双站点+回归测试）；nit1=物理门后重算转发预算（本地+云两路径，防 ≈2×remaining 超预算）；nit2=admin PUT pop 掉 expected_revision 不落盘；nit3=priority 改 `_strict_int` 严格解析。全量 2058 绿。**PR #2 已合入上游（12:21 approve with rebase）**。**PR #4 已合入上游（13:01 approve with rebase，merge `fd1c017`）——F5 池 v2 全部落地，上游 zero-follow-up。**
>
> **F5 制作注记**（inferfabric-pr session，2026-11-18）：
> ① 全量回归机制抓到关键补漏：B 桶命名硬切的 4 个上游文件门卫 hunk（handler.py 路由门+/v1/models 发号、chat_handlers 池分支门、auth_facade pools 策略、security/admin 池 scope 校验）——不带它们 fabric- 请求在生产进不了池分支，均已按 fork 落位（各 1-2 行注入点级）；② 测试回收：3 件整体移植 + transport_contract 拆分（TestAttemptErrorSanitized 与 ObservationParity 摘要断言归 #12，A 契约改写到 AttemptRecord/outcome 层保留）；③ 移出 3 用例：test_defaults_slow_model_tolerance→#14（G 桶实锤）、test_registry_selfheal_uses_native_flag→F1（上游无 anthropic_native 字段，休眠）、TestAttemptErrorSanitized→#12；④ vendor 测试套按 v2 契约更新（dispatch 缝线/池键 flash/fabric- 命名/证据推导/时钟模式/面板 DOM），共 20 文件，unit+integration 2034 全绿；⑤ 上游既有 `test_forwarder_pool_contract.py` 的 iff/fast 字符串不依赖命名门（原样通过），未动。
