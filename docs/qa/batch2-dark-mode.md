# 批 2 QA 记录 — TOP4 第一步：解除浅色固定，跟随系统深色

日期：2026-11-17 · spec：docs/superpowers/specs/2026-11-17-batch2-dark-mode.md

## 改动清单

| 固定点 | 修复 |
|---|---|
| Color 扩展 13 静态浅色 token | 全部重接 DS 同名自适应色 |
| MainWindowView / WizardView `.preferredColorScheme(.light)` | 两处删除 |
| `NSApp.appearance = .aqua` 强制 | 删除（nil = 跟随系统） |
| 主窗口 backgroundColor 写死浅色 RGB | `NSColor.windowBackgroundColor` 语义自适应 |
| 15 处 `Color.black.opacity` 洗色 | 三档 wash token（浅黑/深白自动翻转） |
| 新增 | `DS.glass`、`Color.wash/washFaint/washStrong`、调试参数 `-appearance dark\|light` |

## 验证证据

1. 契约测试 `scripts/test-app-contracts.sh`：CONTRACT_TESTS_OK 全过 ×2（改动前/后各一轮）；
2. 色值解析验证：swiftc 直编 DesignSystem.swift + 9 用例 harness（desk/panel/glass/wash/washStrong/accent × 明暗两档），9/9 PASS —— 同一 token 在 darkAqua/aqua 下解析出正确两档值，玻璃/洗色在深色下翻转为白基调；
3. 双档构建：`build.sh --debug` 与正式 `build.sh` 均 exit 0；
4. 遗留扫描：`rg 'preferredColorScheme|NSAppearance(named: .aqua)|Color.black.opacity'` main.swift 零命中；
5. 全量 pytest 不受影响（纯 App 表现层，网关零改动，未重跑）。

## 已知边界

- 原生截图矩阵仍受 TCC 屏幕录制权限阻塞（与截图审核任务同一根源，待权限路径裁决后补人工视觉走查）；
- 契约测试编不到 main.swift/DesignSystem.swift，自适应 token 无法契约断言，以色值解析 harness 代替（9 用例可复跑）；
- 能力线九色与状态语义色保持明暗共用（DS 既有设计），未引入新色；
- `-appearance` 参数仅进程级调试用（与 -page/-size 同先例），正式启动路径不传参、跟随系统。
