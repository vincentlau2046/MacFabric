# QA — 能力包 PK4 全链路验收 + fabric- 命名硬切 + 发布上线（2026-11-16）

自动化：网关侧 **264/264 绿**（含 runtime_prep 7 项、fabric- 前缀钉住、断点续传 3 项、
served_name 路由回归、池默认值 3/180000）；App 侧 build.sh 编译门禁（fabric- 命名 + 池
备选 LLM/VL 过滤）。
生产网关：127.0.0.1:8999（launchd com.macfabric.gateway），**已切发布安装**
（tag `gateway-v7.10.6`，`~/Library/MacFabric/prod` 独立 venv，pid 见 launchctl）。
沙箱：127.0.0.1:8998（`scripts/sandbox-gateway.sh`，隔离 state + 真配置符号链接）。

## Catalog

- ✅ `GET /admin/packs/catalog` → 200，**4 项**（llm.qwen3-4b-instruct-2507 /
  embedding.bge-m3 / tts.kokoro-82m-onnx / ocr.macos-vision）——whisper 已按裁决移出
- ✅ 3 个旧静态包（rerank / qwen3-1.7b / qwen3-vl-4b）已按裁决从页移除

## 真包安装全链路（ModelScope 源，沙箱取证）

- ✅ 真实安装 llm.qwen3-4b-instruct-2507：preflight（参数/内存/磁盘/沙箱门禁）→
  ModelScope 下载 1.5G 模型 + 17M 引擎 → sha256 校验 → **真实运行时准备**
  （runtime_prep：tar.gz 安全解包、dylib 符号链接保真、llama-server→runtime/engine）→
  **真实隔离健康检查**（真拉起 engine 轮询 /health）→ installed
- ✅ 断点续传：ModelScope CDN 掐长连接导致 ~2GB 两连败 → Range 续传（6 次尝试上限，
  HTTPError 不重试，非 206 全量重写）——3 项单测钉住
- ✅ 安装进度实时上报（on_stage → status），进行中清除上次失败 error/stage 残留
- ✅ 引擎版本取证：`version: 1.0.0-dev (build 12361, commit 951d465f5)`
- ✅ 安装后沙箱 chat 直连 pack 模型 200（qwen3-4b-instruct-2507）

## 路由验证矩阵（沙箱 8998，全绿）

| 请求 | 结果 |
|---|---|
| `fabric-fast` | 200 → `pool:fast/cloud:atlaswork/glm-5` |
| `fabric-small` | 200 → `pool:small/cloud:atlaswork/glm-5` |
| `fabric-premium` | 200 → `pool:premium/cloud:atlaswork/gpt-6.1-sol` |
| `iff/fast`（旧命名） | **404 Unknown model**（硬切，无别名） |
| 无鉴权 | 401（policy=all 管线完好） |

## fabric- 命名硬切 + 池默认值（用户裁决 2026-11-16）

- ✅ POOL_PREFIX=`fabric-`：proxy 分发 / 安全层 pool-scopes / config 校验 / App / 
  dashboard 全量切换；iff/ 不再路由（`test_pool_prefix_fabric.py` 钉住硬切与
  池自引用拒绝）
- ✅ App 池备选列表仅 LLM+VL（`model_type in {llm, vl}`，用户裁决 VL 保留）
- ✅ 池默认 max_attempts=3 / deadline_ms=180000（validation 范围不变）；
  三个现役池显式值同步更新（生产 yaml 取证：3× (3, 180000)）

## 发布上线（生产只吃发布产物 — 用户纪律固化）

- ✅ `scripts/release-install.sh gateway-v7.10.6`：GitHub codeload 归档 → 原子换目录
  `~/Library/MacFabric/prod` → uv 独立 venv（requirements.txt 17 包）→ models.d 首次
  迁移到 `~/.inferfabric/models.d`（5 个配置，已存在永不覆盖）→ plist 重写
  （MACFABRIC_MODELS_DIR + prod 路径，原 plist 备份）→ bootout/bootstrap → 冒烟
- ✅ 生产冒烟：catalog 200（4 项）/ packs status qwen installed / 无鉴权 401 /
  进程确认 `prod/.venv/bin/python -m inferfabric.proxy.handler`
- 回滚 = `scripts/release-install.sh <旧 tag>`；配置在 `~/.inferfabric` 不受发布影响

## 追加：统一能力架构（2026-11-16 下午 — 用户裁决"一定是统一的"）

裁决记录：docs/superpowers/specs/2026-11-16-unified-capability-architecture.md

- ✅ 静态迁清：qwen3-4b（与包双份）/bge-m3/kokoro-82m/whisper-v3-turbo 四个静态
  yaml 删除（生产配置备份 ~/.inferfabric/models.d.bak-20261116-160736，磁盘模型
  文件保留）；迁清后 /models 只剩包模型
- ✅ bge-m3 走包架构端到端：安装（App 发起，全阶段）→ 沙箱 /v1/embeddings 200
  1024 维向量
- ✅ 本地推理标注来源：/models.managed_by_pack（TDD）→ App 卡片"包:<id>"
- ✅ 用户扩展能力包：POST /admin/packs/custom 校验链（https → 下载断点续传 →
  sha256 可选 → GGUF 魔数 → 磁盘门禁 → 真引擎隔离试加载 → 注册）；
  单测 11 项（含失败残留覆盖重装、sha256 不符、非 GGUF 拒绝、零残留）
- ✅ 沙箱真包 e2e：ModelScope Qwen3-0.6B-Q8_0（639MB）→ installed →
  chat 200（真实推理返回，usage/completion 齐全）；卸载→修正链接重装→复跑通过
- 取证修复：自定义包复用引擎经 runtime 符号链接（rpath @loader_path 约束）；
  manifest 缺 engine artifact 导致 binary_path 空的缺口由 e2e 发现并修复
- 取证修复（回归钉住 test_packs_wiring）：get_pack_manager 生产单例从未接线
  reload_gateway → 装包后 _reload() 静默空转、/models 无新模型（Unknown model）
  → attach_pack_uninstaller 启动装配点注入 set_reload_gateway（安装链与卸载链
  同源 pm.mgr.reload_models）；测试 277/277 绿

## 追加：v7.10.7 — 保留内存用户可设置 + App 安装版更新（2026-11-16）

- ✅ 网关 `budget_mb()`：env（显式覆盖）> 设置页 policy.json system_reserved_memory_mb
  > 默认 8192；每次调用重读，保存即时生效（账本 `_admit_memory` 动态重建，无缓存）
  ——D2"全局唯一公式"落地：内存账本与安装预检共用同一设置，不再有第二道公式
- ✅ App 设置页内存账本卡："为系统保留"可编辑（与能力包策略同一字段同一保存），
  策略草稿回填；单测 3 项钉住优先级（env 覆盖 / policy 生效 / 缺损回退默认）
- ✅ 生产 8999 冒烟：policy 8192 → 预算 28672 MB（36G−8G，口径一致）；plist 无
  env 覆盖，policy 为唯一用户入口
- ✅ `/Applications/MacFabric.app` 已替换为 v7.10.7 构建（release profile → 8999）——
  此前用户运行的是旧安装版（8 张静态卡 / 无策略卡），非后端问题
- ✅ 测试修复：runtime_prep healthcheck 断言 pgrep 锚定 tmp_path（此前全局模式被
  现役生产引擎误匹配——生产路由在跑的旁证）

## 人工 GUI 取证清单（待用户执行 — App 需重开载入新构建）

- [ ] 模型池页：池逻辑名显示 fabric-* 前缀；添加/替换池的备选列表仅 LLM/VL 模型
- [ ] 能力包页：4 张 Catalog 卡；qwen 卡"已安装"态
- [ ] 设置页"能力包策略"：保存生效、非法输入出错误横幅
- [ ] 侧栏术语未变（"能力包"）
  （安装/卸载 GUI 流程已由 API 契约冒烟等价覆盖，真包链路沙箱已全绿）

## 已知风险 / 后续

- 引擎下载代理/镜像回退（github.com 直连依赖）——另立项
- per-attempt TTFT 上限（首候选挂死吃光 deadline 的缺口）——docs/PLAN.md §11 待立项
- 严禁全局 pkill proxy.handler（两档命令行相同）——进程操作只按精确 PID / label
