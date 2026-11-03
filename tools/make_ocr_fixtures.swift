import AppKit
import Foundation

// 生成 OCR 对照样本：小字号、浅底 / 深底 / 等宽终端字
// 用法: swift tools/make_ocr_fixtures.swift <输出目录>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/ocr-fixtures"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

struct Fixture {
    let name: String
    let size: CGSize
    let background: NSColor
    let foreground: NSColor
    let font: NSFont
    let lines: [String]
}

let fixtures: [Fixture] = [
    Fixture(name: "tiny_light",
            size: CGSize(width: 340, height: 96),
            background: .white,
            foreground: .black,
            font: .systemFont(ofSize: 10),
            lines: ["两路 YOLO + GPU 合成", "选帧/gather + UNet 子图", "端到端延迟 12.4ms"]),
    Fixture(name: "tiny_dark",
            size: CGSize(width: 340, height: 96),
            background: NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),
            foreground: NSColor(calibratedWhite: 0.86, alpha: 1),
            font: .systemFont(ofSize: 10),
            lines: ["两路 YOLO + GPU 合成", "选帧/gather + UNet 子图", "端到端延迟 12.4ms"]),
    Fixture(name: "terminal",
            size: CGSize(width: 460, height: 120),
            background: NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.14, alpha: 1),
            foreground: NSColor(calibratedRed: 0.62, green: 0.86, blue: 0.62, alpha: 1),
            font: .monospacedSystemFont(ofSize: 11, weight: .regular),
            lines: ["$ python bench_infer.py --bs 8",
                    "load_checkpoint 3.21s | kv_cache hit 0.93",
                    "e2e latency 12.4ms  memory 18.2GB"]),
    Fixture(name: "low_contrast",
            size: CGSize(width: 380, height: 88),
            background: NSColor(calibratedWhite: 0.86, alpha: 1),
            foreground: NSColor(calibratedWhite: 0.55, alpha: 1),
            font: .systemFont(ofSize: 11),
            lines: ["灰度低对比度样本 Gray on gray", "第二行用于测试对比度拉伸 Second line"])
]

for fixture in fixtures {
    // 两个倍率都出：@2x 对应 Retina 截图，@1x 对应"拖框很小 / 外接非 Retina 屏"，
    // 后者才是真正考验放大预处理的场景
    for scale in [2, 1] {
        let pixelWidth = Int(fixture.size.width) * scale
        let pixelHeight = Int(fixture.size.height) * scale
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: pixelWidth, pixelsHigh: pixelHeight,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            print("FAIL \(fixture.name)")
            continue
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        fixture.background.setFill()
        NSRect(origin: .zero, size: fixture.size).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: fixture.font,
            .foregroundColor: fixture.foreground,
            .paragraphStyle: paragraph
        ]
        for (index, line) in fixture.lines.enumerated() {
            let y = fixture.size.height - 20 - CGFloat(index) * 24
            (line as NSString).draw(at: NSPoint(x: 10, y: y), withAttributes: attributes)
        }

        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            print("FAIL \(fixture.name)")
            continue
        }
        let suffix = scale == 2 ? "2x" : "1x"
        let path = "\(outDir)/\(fixture.name)_\(suffix).png"
        try png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) \(pixelWidth)x\(pixelHeight)")
    }
}
