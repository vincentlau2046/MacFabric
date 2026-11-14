// MacFabric 图标生成器 — CoreGraphics 矢量绘制 → iconset PNG（scripts/ 工具，产物进 app bundle）
// 设计：深蓝底 + 编织线（fabric 意象：多模型/多协议汇聚）+ 中央发光枢纽（统一入口 :8999）
// 用法: swiftc scripts/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <out-dir>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon.iconset"

func rgba(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func draw(size: CGFloat) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let S = size, u = S / 1024
    let R = CGRect(x: 0, y: 0, width: S, height: S)

    // ── 底：squircle 近似圆角矩形 + 深蓝对角渐变 ──
    let radius = 0.224 * S
    let bg = CGPath(roundedRect: R, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.addPath(bg); ctx.clip()
    let g = CGGradient(colorsSpace: cs,
                       colors: [rgba(0x2A3163), rgba(0x141838), rgba(0x0B0E26)] as CFArray,
                       locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

    // ── 织物：两组交叉渐变线（quadratic 弧线，带柔光）──
    ctx.setShadow(offset: .zero, blur: 26 * u, color: rgba(0x7DD3FC, 0.35))
    let strands: [(UInt32, CGFloat, CGFloat, CGFloat, CGFloat)] = [
        // color, width(u), from(x,y 0..1, CG 原点左下), ctrl-offset
        (0x2DD4BF, 30, 0.10, 0.86, 0.30),   // 青：左上→中下
        (0x8B5CF6, 26, 0.14, 0.14, -0.26),  // 紫：左下→右上
        (0xF59E0B, 22, 0.86, 0.88, 0.24),   // 琥珀：右下→左上
        (0x60A5FA, 26, 0.88, 0.16, -0.28),  // 蓝：右下→左上另一弧
    ]
    for (hex, w, fx, fy, bend) in strands {
        let p1 = CGPoint(x: fx * S, y: fy * S)
        let p2 = CGPoint(x: (1 - fx) * S, y: (1 - fy) * S)
        let mid = CGPoint(x: (p1.x + p2.x) / 2 + bend * S,
                          y: (p1.y + p2.y) / 2 - bend * S)
        let path = CGMutablePath()
        path.move(to: p1); path.addQuadCurve(to: p2, control: mid)
        ctx.addPath(path)
        ctx.setStrokeColor(rgba(hex, 0.85))
        ctx.setLineWidth(w * u); ctx.setLineCap(.round)
        ctx.strokePath()
    }
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // ── 中央芯片轮廓（统一入口意象）──
    let chipSide = 340 * u
    let chip = CGRect(x: (S - chipSide) / 2, y: (S - chipSide) / 2, width: chipSide, height: chipSide)
    let chipPath = CGPath(roundedRect: chip, cornerWidth: 84 * u, cornerHeight: 84 * u, transform: nil)
    ctx.setFillColor(rgba(0x0B0E26, 0.55)); ctx.addPath(chipPath); ctx.fillPath()
    ctx.setStrokeColor(rgba(0xE2E8F0, 0.30)); ctx.setLineWidth(7 * u)
    ctx.addPath(chipPath); ctx.strokePath()
    // 芯片引脚（上下左右各 3 短线，硅片意象）
    ctx.setStrokeColor(rgba(0xE2E8F0, 0.35)); ctx.setLineWidth(6 * u); ctx.setLineCap(.round)
    for i in -1...1 {
        let off = CGFloat(i) * 92 * u
        for (dx1, dy1, dx2, dy2) in [(off, 1, off, 1.22), (off, -1, off, -1.22),
                                     (1, off, 1.22, off), (-1, off, -1.22, off)] {
            ctx.move(to: CGPoint(x: S / 2 + dx1 * chipSide / 2, y: S / 2 + dy1 * chipSide / 2))
            ctx.addLine(to: CGPoint(x: S / 2 + dx2 * chipSide / 2, y: S / 2 + dy2 * chipSide / 2))
        }
    }
    ctx.strokePath()

    // ── 中央发光枢纽（径向渐变裁剪在枢纽圆内，外圈用阴影做辉光）──
    let hubC = CGPoint(x: S / 2, y: S / 2)
    let hubR = 78 * u
    let hubRect = CGRect(x: hubC.x - hubR, y: hubC.y - hubR, width: hubR * 2, height: hubR * 2)
    ctx.saveGState()
    ctx.addPath(CGPath(ellipseIn: hubRect, transform: nil)); ctx.clip()
    let hubG = CGGradient(colorsSpace: cs,
                          colors: [rgba(0xFFFFFF), rgba(0x38BDF8)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(hubG, startCenter: hubC, startRadius: 0,
                           endCenter: hubC, endRadius: hubR, options: [])
    ctx.restoreGState()
    ctx.setStrokeColor(rgba(0xFFFFFF, 0.55)); ctx.setLineWidth(5 * u)
    ctx.strokeEllipse(in: CGRect(x: hubC.x - 108 * u, y: hubC.y - 108 * u, width: 216 * u, height: 216 * u))

    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let url = URL(fileURLWithPath: path) as CFURL
    let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
// iconset 规范尺寸（@2x 覆盖 16/32/128/256/512）
for s in [16, 32, 128, 256, 512, 1024] {
    writePNG(draw(size: CGFloat(s)), "\(outDir)/icon_\(s)x\(s).png")
    if s != 1024 { writePNG(draw(size: CGFloat(s) * 2), "\(outDir)/icon_\(s)x\(s)@2x.png") }
}
print("ICONSET_OK \(outDir)")
