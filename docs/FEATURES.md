# MacFabric — 特性端到端梳理（feature-driven audit，2026-11-14）

> 用户裁决驱动：池按模型 role 定义（LLM 三默认池）、候选竖排可调优先级、模型可卸载、云端可增删、VL 能力标签。
> 本文档 = 特性清单 + 语义 + 现状 + 批次。完成后逐项回填状态。

## 一、特性清单（F1–F8）

### F1 模型池（role 语义）— ✅ 本轮落地
**语义**：池 = 模型角色的路由链，非静态目录。LLM 三默认角色池：
- `fabric-fast` 快速对话 — qwen3-4b(本机) → zhipu/glm-5(云端)
- `fabric-small` 轻量任务 — qwen3-4b → zhipu/glm-5-flash
- `fabric-premium` 高质量长文 — 纯云端 glm-5（本机 4B 不够格，`allow_cross_location: false`）

**规则**：priority 数字小者优先；路由自上而下逐候选尝试（本地失败/离线 → 云端兜底）；候选含本机与云端混排（`kind: local|cloud`，云端以 `provider/model` 表示）。
**实现**：`~/.inferfabric/model_pools.yaml`（revision CAS）；GET/POST `/admin/model-pools`（POST body = raw 配置 + expected_revision，409 revision_conflict 时重取重试）；App 模型池页 = 竖排候选链（priority 序号 + 点亮态 + 本机/云端 chip + 首选徽章 + ↑↓ 调序按钮）。
**已验证**：换序 rev1→2、旧 revision 重发 409、还原 rev3；三池零 issue 加载。

### F2 模型卸载 — ✅ 本轮落地
**语义**：能力包页承载「安装/卸载一体」（裁决：不单做安装管理页）。卸载 = 停服务（若在跑）→ 删 models.d/<name>.yaml → 热重载；GGUF 模型文件保留磁盘，v2 再议缓存清理。
**实现**：POST `/admin/packs/uninstall` {name}；App 能力包页已装卡「卸载」按钮（两击确认防误删）。
**已验证**：卸载后 /models=[]、重复卸载 404、还原+reload 恢复。
**修复**：handler 原误调 `pm.mgr.load_models()`（模块函数非方法）→ AttributeError 被 except 吞掉、注册表不刷新；改走 `pm.mgr.reload_models()`（同步 _gpu_state/_lifecycle）。

### F3 云端接入 CRUD — ✅ B2 落地
**语义**：服务商可增删（名称、OpenAI 兼容 base、API key、是否发现）；模型可发现/添加/删除（`enabled_models` 白名单 + 每模型 `supports_vision/supports_tools`）。
**实现**：`~/.inferfabric/cloud_provider.yaml`（schema：providers.{name}.{openai_base, api_key, discovery_enabled, enabled_models, models}）；端点已注册：GET/DELETE `/admin/cloud/providers`、POST `/admin/cloud/discover|test|reload|provider-test`、GET `/admin/cloud/provider-models`。
**实现（B2）**：App 云端接入页真数据化 — 服务商卡（key 状态/可路由数/连通测试/删除两击确认/展开模型策展）、模型行（enable/disable 白名单勾选、VL tag 打标/去标、手填 add、manual 模型 remove）、底部添加服务商表单（名称+Base+key，key 写 secrets.env 存 ${REF}）。
**已验证**：add→dup 400→add model→enable→tag VL→remove→delete→404 八步全过，providers 恢复 [zhipu]。

### F4 本地模型安装（发现/添加）— ✅ B3 落地
**实现（B3）**：`/local-models` 从空 stub 接真（`discover_local_models`）；发现范围扩到 MacFabric/models 且支持**根级散置 GGUF**（按配置 model_path 精确排除已装）；新增 `POST /admin/packs/install`（`install_yaml` 只写配置+热重载，**不启动**，与"模型不默认启动"裁决一致）；Mac 专用 llama_cpp 模板（Metal gpu_layers 99 + on_demand 三字段 + binary_path 自动探测）；App 能力包页底部「本机模型发现」卡（扫描/安装）。
**已验证**：假 GGUF 全周期 install→YAML 正确→/models 含且 active=false→uninstall 清理。
**语义**：与 F2 对称的「增加」侧：扫描本机 GGUF → 生成 models.d YAML → 出现在能力包/本地推理。
**实现**：`manager.py` 有 `_discover_local_models(models_dir)`（/api/discover-models 类端点）。
**待办**：安装向导（选文件 → 起名 → mem_baseline/role → 写 YAML）。

### F5 VL 能力标签 — ✅ B1/B3 铺满
池候选行 + 本地推理模型行（model_type == vl）+ 云端策展行（supports_vision 三态 + tag 切换）+ 能力包 vl 卡线色。
**语义**：模型具备「看图」能力需可配置可显示。本机：`model_type: vl`；云端：`supports_vision: true`。
**实现**：模型池候选行 VL 徽章（thVl 粉线 chip）；能力包 vl 卡已有线色。待扩展：本地推理/Hub 卡片徽章。

### F6 已对齐项（不再动）
- 内存账本三字段（B=RAM−8G、R1 准入 + force 超卖 409 确认链路、sleep/wake llama_cpp Mac 语义）
- 模型不默认启动（`mode: on_demand`，冷启动空闲、首请求自动唤醒）
- 双协议 :8999（llama-server b12361 原生 /v1/messages 透传）
- 织物暗色设计令牌全套、侧栏八页导航
- Hub 接入地址复制、试聊、监控柱状图、四态 pill

### F7 云端候选点亮 — 🔶 待定语义
云端候选「点亮」= 最近一次该 provider 可达/调用成功。暂显「待命」；后续接 `/admin/model-pools/runtime` 的候选健康态。

### F8 池管理扩展 — 🔶 开关已接（B3），拖拽/自建池留 v2
已接：`/admin/model-pools/toggle` 单池启停（服务端字段级 CAS，实测 off→on rev4→5）。
自建池/删除池/改池用途标签；候选拖拽排序（↑↓ 已够 v1）；池级 enabled 开关（端点已有 `/admin/model-pools/toggle`，UI 未接）。

## 二、批次安排

| 批次 | 内容 | 状态 |
|---|---|---|
| B1 | F1 池真数据页 + F2 卸载 + F5 VL 徽章 + 卸载 reload bug 修复 | ✅ 本轮 |
| B2 | F3 云端接入页真数据（服务商 CRUD + 模型勾选/VL 打标/手填/删除） | ✅ |
| B3 | F4 本地模型发现/安装（不启动） + F5 徽章铺满 + F8 池开关 | ✅ |
| B4 | G3 菜单栏 mini 织物条、G4 per-model 指标表（TTFT/TPS/成本）、G5 设置页真数据（开关灰显待 v1.5 端点） | ✅ |
| B5 | G6 首启向导（四步+defaults 记忆）、G7 dmg 打包（scripts/make-dmg.sh → dist/MacFabric.dmg 682K，挂载校验通过） | ✅ |

> 公证/Sparkle 更新（G7 后半）留待有开发者证书后接入。 |

## 三、验证记录（本轮）

- 池换序：POST raw+expected_revision → 200 → rev2，fast 首选变 zhipu/glm-5
- CAS：旧 revision 重发 → 409 revision_conflict（App 端策略：重新 GET 后提示）
- 还原：rev3 回 qwen3-4b 首选
- 卸载：stopped=true → /models=[] → 重复 404 → 还原恢复
- App 构建：`macfabric-app/build.sh` 通过


## 四、I/O 能力包落地（O 批次，2026-11-14 规划）

> 动机：agent 普遍需要 OCR/ASR/TTS 输入输出模型；端侧工作站没有这三样等于半残。
> 调研结论（互联网核验 + 代码勘察，2026-11-14）：

### 选型（全部 Apple Silicon Metal/原生，全部 OpenAI 兼容协议）

| 能力 | 引擎 | 模型 | 大小 | 接入方式 |
|---|---|---|---|---|
| OCR | **macOS Vision 框架**（已构建 tools/ocr-helper ✓） | 零模型（系统内置） | 0 | 网关 /ocr 端点包装二进制；Qwen3-VL-4B 作"看图理解"上层（已可安装） |
| ASR | **whisper.cpp whisper-server**（Metal 一等公民，`--inference-path /v1/audio/transcriptions` 直接 OpenAI 兼容） | ggml-large-v3-turbo（ggerganov/whisper.cpp） | 1.5GB | cmake 构建 + pack download 复用 + asr block（start_cmd 绝对路径，无需 conda） |
| TTS | **kokoro-onnx**（thewh1teagle，v1.1-zh 中文增强，ONNX CPU 够快） | kokoro-v1.1-zh.onnx 310MB + voices-v1.1-zh.bin 51MB + espeak-ng-data 12MB | ~373MB | 自写 ~80 行 FastAPI（OpenAI /v1/audio/speech）放 venv；进程管理器走 ~/miniconda3/envs/<name>/bin/python 探测 → 建 venv 即兼容 |

否决项：Kokoro-FastAPI（remsky）功能全但要 torch（2GB+ 依赖树）；sherpa-onnx 中文音色一般；FunASR sensevoice 中文强但服务端面向 CUDA；ollama pull 不支持 GGUF 语音模型。

### 网关新增路由
- `POST /ocr` {image_path} → ocr-helper（Vision）
- `POST /v1/audio/transcriptions`（multipart）→ 转发 ASR 端口 8881
- `POST /v1/audio/speech`（json）→ 转发 TTS 端口 8880，回传音频字节

### 批次
- O1 OCR 路由（零下载）→ O2 TTS（373MB + venv）→ O3 ASR（cmake 构建 + 1.5GB）
- 能力包页 ASR/TTS 卡安装按钮在引擎就绪后点亮
