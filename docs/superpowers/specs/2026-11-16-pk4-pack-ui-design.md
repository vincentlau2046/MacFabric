# PK4 设计：能力包页（App）+ 卸载生产接线

日期：2026-11-16。上游：`2026-11-15-capability-packs-design.md`（网关底座，已交付并合入生产）。
裁决方式：七项全部按推荐获批（用户 2026-11-16"全部按推荐，开始吧"）。

## 意图

能力包能力此前只有网关后端（admin API 已在生产 8999 验证）；App 侧无任何入口，
且现 `PacksView` 为静态假目录（安装 URL 硬编码在 App 内，违反 spec §6.1
Catalog-only 裁决）。PK4 让能力包在 App 上真实可用，并闭合终审 F5 缺口
（`attach_uninstaller` 无生产调用方，卸载 API 在真实网关 404）。

## 裁决记录（七项）

1. **能力包页数据源 = A**：卡片全部来自 `GET /admin/packs/catalog` + `status`
   合并安装态；未实现运行时模板的包（whisper/kokoro）如实置灰"待接入"
   （后端 preflight 拒绝 `model_config_template_not_implemented`）。
2. **旧静态流 3 个非 Catalog 包（rerank / qwen3-1.7b / qwen3-vl-4b）= A**：
   从能力包页移除，留待下批 Catalog 冻结 hash 后回归；同时移除 App 内置
   hf-mirror URL 下载流（packPresets）——功能暂时回退换取不绕过 Catalog-only。
   "本机模型发现"（LocalDiscoverCard，用户导入流）保留不动。
3. **安装交互**：POST install → 202 → 复用 3s 轮询 status → 卡上阶段中文文案
   （预检中/下载中/校验中/配置中/健康检查中/重载中）。本期不做字节级百分比。
4. **卸载交互**：GET uninstall-preview → confirmationDialog 列受影响池 →
   确认 POST uninstall {pack_id, confirmed:true}；替代旧两击确认模式。
5. **4B/8GB 策略 = A**：设置页新增"能力包策略"区（max_model_parameters_b +
   system_reserved_memory_mb，PUT /admin/packs/policy，注明仅影响后续安装）。
6. **网关卸载接线**：handler 启动时 `attach_pack_uninstaller(pm)` 注入真实回调；
   请求路径（chat + messages）挂 `is_model_disabled` → 503。
7. **验收深度 = A**：GUI 手动冒烟 + 真装一次 Qwen3-4B 再卸载零残留。
   已知风险：本机网络对 huggingface.co 直连阻断（spec §14 取证）——下载若被
   阻断，安装失败路径本身即 UX 验证点；镜像源支持另立项，不阻塞 PK4。

## 边界

- 网关侧 pgid 追踪未建立：接线 pgid_fn=None，drain-only，绝不盲杀（对齐
  supervisor 安全裁决）。
- App 无 XCTest 基建：SwiftUI 层验证 = build.sh 编译通过 + 手动 GUI 冒烟
  清单（docs/qa/packs-ui.md），沿用 monitor-pools-v2 的 QA 模式。
- 侧栏术语不动（"能力包"已钉死）。
