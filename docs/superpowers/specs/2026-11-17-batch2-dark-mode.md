# 批 2：TOP4 第一步 — 解除浅色固定，跟随系统深色

日期：2026-11-17 · 状态：已裁决实施（6 项任务清单批 2）

## 问题

审计 TOP4：App 四处硬编码浅色，系统深色下刺眼：
1. `main.swift` 顶部 Color 扩展 13 个静态 token 全为浅色值；
2. `MainWindowView` 与 `WizardView` 各挂 `.preferredColorScheme(.light)`；
3. `applicationDidFinishLaunching` 强制 `NSApp.appearance = .aqua`；
4. 主窗口 `backgroundColor` 写死浅色 RGB，另散落 16 处 `Color.black.opacity` 洗色在深色下不可见/过暗。

## 方案（DS 已有自适应基建，复用不新造）

`DesignSystem.swift` 的 `DS.adaptive` 已实现 NSColor 动态外观解析，新页面（DS.*）已自适应。本批把旧 token 全部重接到 DS：

1. **token 重接**：Color 扩展 13 个静态 token 改引用 DS 同名自适应色；新增 `DS.glass`（浅 5% 黑 / 深 9% 白）与 Color 扩展 `washStrong/wash/washFaint` 三档自适应洗色；`DS.adaptive` private → internal。
2. **解除三处强制**：删两个 `.preferredColorScheme(.light)`、删 `NSApp.appearance` 强制 aqua（nil = 跟随系统）。
3. **窗口背景**：主窗口 `backgroundColor` 改 `NSColor.windowBackgroundColor`（语义自适应）；向导窗口用默认值已自适应。
4. **洗色迁移**：16 处 `Color.black.opacity` 按浓度映射三档 wash token（能力线色等彩色 opacity 不动）。

## 边界与红线

- 网关侧零接触；本批纯 App 表现层，不改任何业务逻辑/网络/存储。
- 契约测试编不到 main.swift/DesignSystem.swift（只编 ProductModels/AuthState/GatewayClient），自适应 token 无法单测，以双档构建 + 运行验证代替，QA 落盘。
- 能力线九色、状态语义色保持明暗共用（DS 现状），不引入新色。

## 验收

1. `bash scripts/test-app-contracts.sh` 全过（确认无意外破坏）；
2. `build.sh --debug` 与正式 `build.sh` 双档 exit 0；
3. 启动 dev App（-page 矩阵参数）人工确认系统深色下桌面/面板/文字/边线/洗色对比正常，浅色回归无损；
4. QA 记录落 `docs/qa/batch2-dark-mode.md`。
