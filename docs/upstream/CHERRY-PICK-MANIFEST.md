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

## 4. D23 部署隔离范式条目（用户裁决 2026-11-18：坚持并上游推广）

| # | 特性域 | pick 分支 | commit 范围 | 新增文件 | 触碰上游文件 | 验收测试 | 状态 |
|---|---|---|---|---|---|---|---|
| 11 | F3 部署隔离范式（推 x86+NVIDIA） | pick/deploy-isolation | 待切 | packs/runtime_prep.py、packs/sandbox.py、packs/uninstaller.py、packs/supervisor.py、docs/ISOLATION.md | process_manager/base.py（python_bin 注入、引擎引用计数 `_collect_engine_refs`）、config.py | test_packs_sandbox.py、test_packs_runtime_prep.py、test_packs_installer.py（平台无关） | 审计已上报上游：[InferFabric#3](https://github.com/vincentlau2046/InferFabric/issues/3)（5 问打包单 issue，2026-11-18）；PR #2 描述已附链接；**上游已裁决（issue #3 两评论，2026-11-18）**：Q1-Q5 全答 + 方向更新——**Docker-first 全沙箱为终局**（重引擎迁 `deployment: docker`，ComfyUI 豁免留宿主；L2 conda 前缀方案被取代，L1 降为过渡兼容；L3 折入迁移：`build_docker_cmd` 补 `:ro` + 管理镜像标签 + 作用域 prune；`iff remove`+引用计数+dry-run CLI 先行不变）；Q5 裁定 pkgs=用户级共享缓存不自动清。新切分方案待报批：**PR-A = L1 过渡 + L3 镜像卫生（上游明示可立即开工）**、PR-B = docker 迁移计划（钉版镜像→影子验证→逐模型迁 YAML→退役 env） |

**范式原则（用户原话裁决）**：部署不得影响系统环境；整体卸载/安装必须方便（一键化、容器化拆除）。Mac 侧表达 = 用户态自包含（engines/ 独立二进制 + venv + `python_bin` 显式）；**x86+NVIDIA 侧不是照搬 Mac 路径，而是同一原则的本地表达**——上游既有 Docker（ninfer/sglang）与 conda env 路径需审计：容器/venv 是否项目内自包含、卸载是否引用计数拆除、有无系统级残留（conda 全局、系统 site-packages、/usr/local 二进制）。产出物 = 适配方案 + 对应 pick 分支，先在 PR #1 讨论区或单独 issue 与上游对齐形态再动手。

## 5. F5 分桶裁决新增条目（2026-11-18 第二封报备，8 桶全量分类后）

| # | 特性域 | pick 分支 | 内容 | 状态 |
|---|---|---|---|---|
| 12 | 池观测/摘要（E 桶 ~257 行，bdd6e4b） | pick/pool-summary-observability | 纯增量观测体系，单立；**判据=剥离后测试是否自洽**，若剥离致 A/D 语义不完整需改随 F5 带上，须先报主 session 批准 | 待制作 |
| 13 | 跨池唯一校验移除（H 桶 -24 行） | （待议） | 行为放宽变更，单立"行为变更待议"，不进纯修复批次 | 待议 |
| 14 | 慢模型容忍默认值（G 桶 ~12 行，117e4d9） | （待议） | 行为默认值变更，单立"行为变更待议"，与 floor 兜底同性质 | 待议 |
| 15 | DeviceTelemetry 双平台设备遥测 | pick/device-telemetry | `2a346e1..ca3aae8`（6 commits，基线 `2a346e1`，含沙箱抓修 `ca3aae8`） | platform/telemetry.py + apple_telemetry.py + nvidia_telemetry.py、migrations/v011_device_power_samples.py、test_platform_telemetry_{contract,backends}.py、test_device_telemetry_wiring.py、test_device_power_persistence.py、test_device_api_contract.py、test_dashboard_device_contract.py | health.py、manager.py、gpu_state.py、model_lifecycle.py、interfaces.py、health_checker.py、cli.py、db.py、power_stats.py、telemetry.py、process_manager/{base,facade,sglang}.py、proxy/handler.py、dashboard store/overview/monitor + base.html（注入点级） | unit 421 绿（darwin 原生）+ IFF_FORCE_PLATFORM=linux mock 28 绿 + :8998 隔离沙箱 HTTP 验收（docs/qa/2026-11-18-device-telemetry.md）；**物理 CUDA 验收为上游独立门**；依赖 F2 platform-layer（PR #2 已合入） | 待摘取（退役条件：上游合入 + 一个发布周期后移除 gpu_* 兼容层/兼容视图；无 NVML；无 D24 限流变更） |

> **F5 分桶记录**：D 桶（结构化传输 e48401a）随 F5 带上——A 核心构建在其 `_forward_request_ex` suppress 模式之上，拆开不自洽，且 D 本身是传输正确性修复（裁决①，2026-11-18）；F 桶（purge_candidates 联动）归 D23 条目域（依赖 F6 已撤出的 excluded_models 语义，留 fork 待议）。
>
> **F5 评审修复**（inferfabric-pr session，2026-11-18，REQUEST-CHANGES 响应已推送 `6d86f7c` + PR 评论逐项说明）：blocker=存量池键回落（`_resolve_pool_snap` 规范名未命中回落原短名，fabric- 重命名不切断未迁移配置，双站点+回归测试）；nit1=物理门后重算转发预算（本地+云两路径，防 ≈2×remaining 超预算）；nit2=admin PUT pop 掉 expected_revision 不落盘；nit3=priority 改 `_strict_int` 严格解析。全量 2058 绿。**PR #2 已合入上游（12:21 approve with rebase）**。**PR #4 已合入上游（13:01 approve with rebase，merge `fd1c017`）——F5 池 v2 全部落地，上游 zero-follow-up。**
>
> **F5 制作注记**（inferfabric-pr session，2026-11-18）：
> ① 全量回归机制抓到关键补漏：B 桶命名硬切的 4 个上游文件门卫 hunk（handler.py 路由门+/v1/models 发号、chat_handlers 池分支门、auth_facade pools 策略、security/admin 池 scope 校验）——不带它们 fabric- 请求在生产进不了池分支，均已按 fork 落位（各 1-2 行注入点级）；② 测试回收：3 件整体移植 + transport_contract 拆分（TestAttemptErrorSanitized 与 ObservationParity 摘要断言归 #12，A 契约改写到 AttemptRecord/outcome 层保留）；③ 移出 3 用例：test_defaults_slow_model_tolerance→#14（G 桶实锤）、test_registry_selfheal_uses_native_flag→F1（上游无 anthropic_native 字段，休眠）、TestAttemptErrorSanitized→#12；④ vendor 测试套按 v2 契约更新（dispatch 缝线/池键 flash/fabric- 命名/证据推导/时钟模式/面板 DOM），共 20 文件，unit+integration 2034 全绿；⑤ 上游既有 `test_forwarder_pool_contract.py` 的 iff/fast 字符串不依赖命名门（原样通过），未动。
