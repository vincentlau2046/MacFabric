# B3 原生 UI 改造证据（2026-11-16，2026-11-17 原生 Table 重做）

> 范围：plan Task B3（三页接共享表格与详情）+ 顺带完成的 B4 部分。
> 声明：本记录只证明本文件列出的检查；样稿一致 ≠ 语义门禁（后者在 D2）。

## 2026-11-17 #45 能力包标签统一（TDD，spec docs/superpowers/specs/2026-11-17-pack-tag-alignment.md）

| 检查 | 命令 | 结果 |
|---|---|---|
| 契约测试（22 组，含 #45 新增 9 断言） | `bash scripts/test-app-contracts.sh` | CONTRACT_TESTS_OK，exit=0（先 RED 9 失败→GREEN） |
| 调试档构建（:8998） | `bash macfabric-app/build.sh --debug` | exit=0（仅既有 onChange deprecation 警告） |
| 正式档构建 | `bash macfabric-app/build.sh` | exit=0 |
| dev 应用重启 + 网关复核 | 精确路径重启 dev App；`GET :8998/models` | App 运行中，网关 200 未受影响 |

实施内容（映射纯 App 侧，网关 payload 不动）：
- `ProductModels.CapabilityTags`：主标签由 capability 映射（llm→对话 · vl→看图(id 固定 "vision") ·
  embedding→嵌入/检索 · rerank→重排 · asr→语音转写 · tts→语音合成 · ocr→文字识别 · aigc→生图 · 其他→原文）；
  修饰标签已知词映射（tools→工具调用 · multilingual→多语 · retrieval→检索 · low-latency→低延迟 ·
  builtin→内置 · zero-download→零下载 · custom→自定义 · chat 映射"对话"后与主标签去重），未知词原样透传。
- 呈现：能力包行 `CapabilityTags.displayTags`（主标签在前 + 至多 2 修饰）；共享能力列兜底 prefix(3)；
  详情栏"能力"字段给全量（modifierLimit .max）。
- 看图三态：`VisionPresentation`（nil=不显示不提 · true=能力标签 · false=表格无标签且详情"不支持"）；
  云端行 `cloudRows` 改走该口径（语义与原 `== true` 等价，纯口径归一）；
  `hubDetailFields` 对 supports_vision=false 的云端模型如实标注"看图: 不支持"。
- 红线保持：标签纯展示无门禁；无 bool() 塌缩入口；fixture 断言钉住 nil/false 不产生看图标签。

## 2026-11-17 原生 Table 重做（用户裁决：用 Apple 原生设计语言，不用 CSS 式自绘）

## 2026-11-17 原生 Table 重做（用户裁决：用 Apple 原生设计语言，不用 CSS 式自绘）

| 检查 | 命令 | 结果 |
|---|---|---|
| 契约测试（20 组） | `bash scripts/test-app-contracts.sh` | CONTRACT_TESTS_OK，exit=0 |
| 调试档构建（:8998） | `bash macfabric-app/build.sh --debug` | exit=0 |
| 正式档构建 | `bash macfabric-app/build.sh` | exit=0 |

改造内容：
- **共享表格换原生 SwiftUI `Table`**（NSTableView 底座）：原生列头/选中/行分隔/
  双击与右键菜单（详情）；列取舍仍由 `ModelColumnLayout` 断点契约驱动；
  选中经 `Set<String>` 桥接单选。自绘表头/行/卡片 chrome 全部删除。
- **三页改单张统一表**：本地推理、模型服务（本地+云端同表，类型/来源成列，
  行尾"接入配置"开详情，模型池降为表格下方脚注卡片）、
  能力包（类型成列 + 原生分段筛选 全部/各类型(计数)，不再按类型分节重复表头）。
- **详情栏改原生检查器风格**：分区用发丝分隔线，去卡片底色。
- 契约布局调整：catalog 页新增 `.type` 列（名称后），其余断点契约未动。

已验证命令与结果如上表；dev 应用已重启（:8998 网关 200）供人工目验。
Table 行高为原生紧凑行（ NSTableView 默认），与样稿的 56pt 双行行高不同——
原生观感优先，若用户要求可再调。

## 已验证（首轮，2026-11-16）

| 检查 | 命令 | 结果 |
|---|---|---|
| 契约测试（20 组） | `bash scripts/test-app-contracts.sh` | CONTRACT_TESTS_OK，exit=0 |
| 调试档构建（:8998） | `bash macfabric-app/build.sh --debug` | exit=0 |
| 正式档构建 | `bash macfabric-app/build.sh` | exit=0 |
| dev 网关数据源 | `GET http://127.0.0.1:8998/models`（只读） | 3 模型（1 活跃 LLM、2 包管理） |

## 三页改造内容（按已确认样稿）

- **本地推理**：卡墙 → `ModelTable(page: .localInference)` + 280pt `ModelDetails`。
  内存 nil → “未知”（不再显示 0/—）；autostart/端口/装载模式/包来源退详情；
  操作（加载/睡眠/停止/唤醒）绑 instanceID；选中按 instanceID 跨刷新保持。
- **模型服务**：本地 + 云端同页按 `PrimaryType` 分组（typeOrder 固定）；
  云端行保留上游 ID 原文、来源列“云端 · provider”；类型缺资料时归“未知类型”，不猜；
  模型池独立分组（“同类聚合 · 集中配置 · 调整一次对多 Agent 生效”）+ 管理入口；
  详情含 Base URL/端点/按类型 cURL·JSON·环境变量（密钥只用占位符）。
- **能力包**：分区 + `ModelTable(page: .catalog)`，行键 `packID|variant`；
  验证列诚实“待验证”（risk_level 不再冒充验证记录）；变体/体积/兼容/安装态成列；
  包 ID/版本/路径/沙箱降级进详情；死代码 ModelRowView/HubRow/PackCard 删除。

## AX 标识（供后续原生自动化）

- `model-row:<instanceID>`、`model-action:<instanceID>`、`model-details:<id>`
- 目录页行：`pack-row:<packID>|<variant>`

## 阻塞 / 未完成（如实）

1. **原生截图矩阵（900×650 / 1200×800 / 1600×1000 × 明暗）被 TCC 拦截**：
   终端宿主进程无“屏幕录制”权限，`screencapture -l <windowID>` 返回
   "could not create image from window"；System Events 调整窗口尺寸同样无
   “辅助功能”权限。需用户回来后在 系统设置 → 隐私与安全性 为终端授权后重跑，
   或人工目验（dev App 当前已启动，dev 网关 :8998 有 3 个真实模型）。
2. **暗色主题**：`MainWindowView` 固定 `.preferredColorScheme(.light)`
   （沿用户既有偏好）；DS 令牌已具备明暗自适应，切暗色需另行裁决后解除固定。
3. **VoiceOver / 键盘 / 大字体矩阵**：人工验收，未执行。
4. **云端模型类型列**：`/cloud` 载荷无 primary_type 字段，C 阶段目录贯通后归类。

## 顺带完成

- B2 代码面：鉴权状态机/Keychain/请求注入/三处硬编码“鉴权未启用”清除（见任务 #42）
- B4 部分：`reserveMB` 走 env > packPolicy > 8192（D7 唯一口径）；Hub 详情即拷示例
- **正式版单实例清理（用户裁决 2026-11-16：正式版全机仅 /Applications 一份）**：
  删除 ~/Library/MacFabric/prod{,.old}/macfabri-app/build/MacFabric.app 与
  仓库 build/MacFabric.app 三处重复副本 + 退出 repo 路径僵尸进程（PID 24414）；
  build 目录加 `.metadata_never_index`，build.sh 每次构建后自动 touch；
  现役 8999 网关（launchd python）全程未受影响（HTTP 200 复核）。
  `mdfind` 复核：全盘仅剩 /Applications/MacFabric.app 一个正式版。
