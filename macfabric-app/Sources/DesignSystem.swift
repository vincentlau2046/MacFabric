// UI v2 设计令牌（docs/superpowers/specs/2026-11-16-ui-standard-v2.md §2/§3）
// 明暗自适应（系统外观）；共享表格度量；能力线色。命名空间 DS —
// MacFabricApp.swift 内旧静态 Color 令牌在 B3 重接前继续供旧页面使用。
import SwiftUI
import AppKit

enum DS {
    // ── 表面与文字（明/暗）─────────────────────────────────────
    static let desk = adaptive(light: 0xF5F5F8, dark: 0x101014)
    static let panel = adaptive(light: 0xFFFFFF, dark: 0x17171C)
    static let chrome = adaptive(light: 0xECECF1, dark: 0x1E1E25)
    static let lineC = adaptive(light: 0x1D1D22, dark: 0x000000, lightAlpha: 0.10, darkAlpha: 0.22)
    /// 玻璃洗色（嵌板/胶囊底）：浅色 5% 黑，深色 9% 白
    static let glass = adaptive(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.09)
    static let ink = adaptive(light: 0x1D1D22, dark: 0xECECF1)
    static let dim = adaptive(light: 0x55555F, dark: 0xA8A8B4)
    static let faint = adaptive(light: 0x85858F, dark: 0x6E6E7A)
    static let accent = adaptive(light: 0x3D5CE5, dark: 0x5F7DFF)

    // ── 状态色（Apple 系统语义，明暗共用）───────────────────────
    static let okC = adaptive(light: 0x1FA843, dark: 0x32D74B)
    static let warnC = adaptive(light: 0xB06000, dark: 0xFFB340)
    static let errC = adaptive(light: 0xC23B3B, dark: 0xFF6961)

    // ── 能力线色（八根，明暗共用）──────────────────────────────
    static let thLlm = Color(hex: 0x4C5FE0)
    static let thVl = Color(hex: 0xE0508B)
    static let thEmb = Color(hex: 0x0F9C77)
    static let thRerank = Color(hex: 0x2B7FD4)
    static let thAsr = Color(hex: 0xC78A1F)
    static let thTts = Color(hex: 0xD45F35)
    static let thOcr = Color(hex: 0x6B9C1F)
    static let thImg = Color(hex: 0x1C9FA0)
    static let thJudge = Color(hex: 0x8E4FD8)

    /// PrimaryType → 能力线色；未知类型用判官紫之外的灰紫，不默认对话蓝。
    static func threadColor(_ type: PrimaryType) -> Color {
        switch type {
        case .llm: thLlm
        case .vl: thVl
        case .embedding: thEmb
        case .rerank: thRerank
        case .asr: thAsr
        case .tts: thTts
        case .ocr: thOcr
        case .aigc: thImg
        case .unknown: adaptive(light: 0x85858F, dark: 0x6E6E7A)
        }
    }

    // ── 共享表格度量（§3；断点判定在 ModelColumnLayout）─────────
    enum Table {
        static let headerHeight: CGFloat = 32
        static let rowHeight: CGFloat = 56
        static let columnGap: CGFloat = 12
        static let nameMin: CGFloat = 220
        static let typeWidth: CGFloat = 96
        static let capabilitiesWidth: CGFloat = 140
        static let statusWidth: CGFloat = 104
        static let memoryWidth: CGFloat = 104
        static let actionsWidth: CGFloat = 100
        static let detailWidth: CGFloat = 280
    }

    // ── 圆角/动效（§2）─────────────────────────────────────────
    enum Radius {
        static let panel: CGFloat = 14
        static let card: CGFloat = 10
        static let chip: CGFloat = 7
    }
    enum Motion {
        static let fast: Double = 0.15
        static let normal: Double = 0.25
    }

    // ── 字体辅助：ID/路径用 SF Mono；数字等宽右对齐 ─────────────
    static func mono(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }
    static func monoDigit(_ base: Font) -> Font { base.monospacedDigit() }

    // ── 基础设施 ───────────────────────────────────────────────
    static func adaptive(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        Color(NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            let alpha = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkAlpha : lightAlpha
            return NSColor(hex: hex, alpha: alpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}
