# CHERRY-PICK-MANIFEST — MacFabric → InferFabric 上游摘取清单

> 基线：vendor/InferFabric HEAD `e453a90`（D20 审计基线）。上游前进时由上游责任人 rebase。
> 对账状态：`待摘取` / `已提交 PR` / `已合入` / `被退回`。维护人：peer session `inferfabric-pr`。
> 分类（D20）：**A=通用修复**（可直接摘）· **P=平台相关**（并入 platform/ 层后摘）· **M=Mac 专属**（留 fork，不摘）。

## 1. 34 个演进文件三级归类（D20 diff 审计，2026-11-18）

### A 类 — 通用修复/增强，可摘（逐条出 pick 分支）

| 文件 | 内容摘要 | 归属批次 |
|---|---|---|
| proxy/forwarder.py | usage 双 chunk 取 max；/admin CORS 收紧；Anthropic base 路径双约定拼接 | B1 |
| proxy/sse_buffer.py | 流式缓冲修复 | B1 |
| proxy/request_logger.py | 日志字段补全 | B1 |
| ratelimit.py | 限流修复 | B1 |
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
| 2 | F2 平台资源账本 | pick/platform-layer | 40bb02e..`d392007`（**含 procguard fail-visible 修复**，见下注） | platform/ 全包 | manager/gpu_state/health/model_lifecycle/model_discovery（5 处导入点） | test_platform_*.py（4 文件，全部平台无关可跑） | 待摘取 |
| 3 | F4 能力包 | pick/capability-packs | 待切 | packs/、pack_handlers.py、jobs.py | handler.py admin 面、chat_handlers（503 闸） | test_packs_*.py（11 文件）+ test_jobs.py | 待摘取 |
| 4 | F5 模型池 v2 | pick/pool-v2 | 待切 | — | model_pool/*、dashboard model-pools 两件、proxy_manager | 池 CAS/rebuild 相关单测 | 待摘取 |
| 5 | F6 云聚合修复 | pick/cloud-fixes | `3670d40`..`94d5bd7`（2 commits，基线 e453a90） | test_cloud_route_resolution.py、test_cloud_discovery_singleflight.py | cloud_discovery.py、proxy_manager.py、proxy/chat_handlers.py + proxy/handler.py（调用侧各 1-3 行注入） | 单测：unit 1882 绿 ×2 + integration 118 绿（本机验证 2026-11-18） | 已提交 PR：[InferFabric#1](https://github.com/vincentlau2046/InferFabric/pull/1)（2026-11-18） |

> **F6 制作记录**（inferfabric-pr session）：
> ① 单飞测试中"池 dispatch 调用侧 background=True"断言用例移出，随 F5 pool-v2 摘取；② **floor 兜底补前缀键 hunk 已撤出**——与上游既有契约测试 `TestShortNameCollisionContract`（碰撞整条跳过）冲突，属行为变更非纯修复，是否上游化待上游责任人在 PR #1 讨论区裁决（PR 描述"Not included"节已说明）；③ `test_r9_anomaly_collector.py::test_query_since` 为上游既有 flaky（pristine 10 连跑失败 3 次），与 F6 无关；④ fabric-* 池命名从 F6/B2 剔除归 F5（Q1 裁决）。
| 6 | F7 安全门禁 | pick/security-fixes | 待切 | — | security/*、db.py、handler.py security 面 | test_admin_auth.py | 待摘取 |
>
> **F2 制作注记**（主 session）：范围已扩展至 `d392007`——终审 Important-1 修复落在 procguard.py（launchctl/systemctl 返回码校验 + systemd enable --now + guard_for_profile 强制显式 label，防覆写生产 plist）。**摘取必须包含该修复**，否则上游拿到的是 fail-silent 版 install。
| 7 | F8 守护与隔离 | （随 2 platform-layer） | — | procguard.py | scripts/gateway-launchd.sh（上游为 systemd 等价物） | test_platform_vram_procguard_engines.py | 待摘取 |
| 8 | F9 Dashboard 新页 | pick/dashboard-pages | 未实施 | M2 产出 packs/security/connect 三 fragment | dashboard/__init__.py 注册点 | M2 验收 | 未实施 |
| 9 | F10 Connect 托管 | pick/connect-clients | 未实施 | M3 产出 platform/clients.py | dashboard 注册点 | M3 验收 | 未实施 |
| 10 | F3 引擎矩阵 | （随 2 platform-layer） | — | engines.py | — | 同 2 | 待摘取 |

## 3. 摘取纪律（重申）

- 新功能进新文件；触碰上游文件的 diff 必须是注入点级别。
- 每条目附验收测试，要求在上游平台（含 CUDA 机）可跑；平台探测用 `MACFABRIC_FORCE_PLATFORM` mock。
- pick 分支基于 `e453a90` 切出，上游前进由上游责任人 rebase。

## 4. D23 部署隔离范式条目（用户裁决 2026-11-18：坚持并上游推广）

| # | 特性域 | pick 分支 | commit 范围 | 新增文件 | 触碰上游文件 | 验收测试 | 状态 |
|---|---|---|---|---|---|---|---|
| 11 | F3 部署隔离范式（推 x86+NVIDIA） | pick/deploy-isolation | 待切 | packs/runtime_prep.py、packs/sandbox.py、packs/uninstaller.py、packs/supervisor.py、docs/ISOLATION.md | process_manager/base.py（python_bin 注入、引擎引用计数 `_collect_engine_refs`）、config.py | test_packs_sandbox.py、test_packs_runtime_prep.py、test_packs_installer.py（平台无关） | 未实施（先与上游对齐 x86 表达形态） |

**范式原则（用户原话裁决）**：部署不得影响系统环境；整体卸载/安装必须方便（一键化、容器化拆除）。Mac 侧表达 = 用户态自包含（engines/ 独立二进制 + venv + `python_bin` 显式）；**x86+NVIDIA 侧不是照搬 Mac 路径，而是同一原则的本地表达**——上游既有 Docker（ninfer/sglang）与 conda env 路径需审计：容器/venv 是否项目内自包含、卸载是否引用计数拆除、有无系统级残留（conda 全局、系统 site-packages、/usr/local 二进制）。产出物 = 适配方案 + 对应 pick 分支，先在 PR #1 讨论区或单独 issue 与上游对齐形态再动手。
