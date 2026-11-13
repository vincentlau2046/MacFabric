// MacFabric ocr-helper — Vision framework OCR CLI（P1/P3）
// 用法:
//   ocr-helper <image-path>        识别图片文字，stdout 输出纯文本
//   ocr-helper --selftest          生成含文字的测试图并识别（冒烟验证）
// 退出码: 0 成功 / 2 用法错误 / 3 识别失败
import Foundation
import Vision
import AppKit

func recognize(url: URL) throws -> String {
    guard let cgImage = NSImage(contentsOf: url)?.cgImage(
        forProposedRect: nil, context: nil, hints: nil) else {
        throw NSError(domain: "ocr", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "无法读取图片: \(url.path)"])
    }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    try handler.perform([request])
    return request.results?
        .compactMap { $0.topCandidates(1).first?.string }
        .joined(separator: "\n") ?? ""
}

func makeSelfTestImage(url: URL) throws {
    let size = NSSize(width: 640, height: 160)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 42, weight: .bold),
        .foregroundColor: NSColor.black,
    ]
    let text = NSAttributedString(string: "MacFabric OCR 2026", attributes: attrs)
    text.draw(at: NSPoint(x: 60, y: 55))
    image.unlockFocus()
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "ocr", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "selftest 渲染失败"])
    }
    try png.write(to: url)
}

let args = CommandLine.arguments
if args.count < 2 {
    FileHandle.standardError.write("用法: ocr-helper <image-path> | --selftest\n".data(using: .utf8)!)
    exit(2)
}

if args[1] == "--selftest" {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mf-ocr-selftest.png")
    do {
        try makeSelfTestImage(url: tmp)
        let text = try recognize(url: tmp)
        try? FileManager.default.removeItem(at: tmp)
        print(text)
        exit(text.contains("MacFabric") ? 0 : 3)
    } catch {
        FileHandle.standardError.write("selftest 失败: \(error)\n".data(using: .utf8)!)
        exit(3)
    }
}

let url = URL(fileURLWithPath: args[1])
do {
    print(try recognize(url: url))
    exit(0)
} catch {
    FileHandle.standardError.write("OCR 失败: \(error)\n".data(using: .utf8)!)
    exit(3)
}
