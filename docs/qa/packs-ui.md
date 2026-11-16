# QA — 能力包 UI + 卸载生产接线（PK4，2026-11-16）

自动化：网关侧 240/240 绿（含 T1 接线 6 项、卸载契约真实化）；App 侧 build.sh 编译门禁。
生产网关：127.0.0.1:8999（launchd com.macfabric.gateway）。

## 自动化/冒烟已验证

- ✅ `GET /admin/packs/catalog` → 200，首批 5 项（Qwen3-4B / BGE-M3 / Whisper / Kokoro / macOS Vision）
- ✅ `GET /admin/packs/status` / `GET/PUT /admin/packs/policy` → 200
- ✅ `GET /admin/packs/uninstall-preview?pack_id=llm.qwen3-4b-instruct-2507` → 200（**终审 F5 闭合证据**：接线前 404）
- ✅ 真实安装发起 → preflight 全过（参数/内存/磁盘/沙箱门禁）→ **下载阶段被网络阻断**
  （huggingface.co 直连 reset，spec §14 已知风险）→ 阶段化错误
  `download_error:URLError` + failed 记录保留诊断 + 磁盘零残留 — 失败路径 UX 事实
- ✅ 503 判定：chat/messages 路径 is_model_disabled 先于鉴权/池/本地分发（单测）
- ✅ 卸载全链路回调（stop_independent → purge_candidates → reload_models）单测钉住

## 人工 GUI 取证清单（待用户执行 — open macfabric-app/build/MacFabric.app）

- [ ] 能力包页渲染 5 张 Catalog 卡（Qwen3-4B 与 BGE-M3 可安装；Whisper/Kokoro/OCR"待接入"置灰）
- [ ] 安装 Qwen3-4B：卡上阶段文案流转（预检中→下载中→…），失败后显示错误 + 重试按钮
- [ ] （网络可达时）安装成功 → "已安装" → 模型服务页出现 pack 模型 → chat 冒烟 → 卸载确认框列池 → 卸载 → 卡回未安装态
- [ ] 卸载确认框：受影响池列表展示（空池也出确认框）
- [ ] 设置页"能力包策略"：保存生效、非法输入出错误横幅（参数量 ≥1；保留内存 1024–65536 MiB）
- [ ] 侧栏术语未变（"能力包"）

## 已知风险 / 后续

- huggingface.co 直连阻断 → 真包完整链路（下载→chat）待镜像源支持后验收（另立项）；
  引擎 artifact（github.com）此前实测可下载（sha256 已冻结）。
- 3 个旧静态包（rerank / qwen3-1.7b / qwen3-vl-4b）已按裁决从页移除，待下批 Catalog 冻结回归。
