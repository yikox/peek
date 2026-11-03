import AppKit
import Foundation

// 生成 App 图标：1024×1024 圆角方块，靛蓝渐变 + 白色「译」
// 用法: swift tools/make_icon.swift <输出目录>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))

image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

// 画布透明
ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

// macOS 图标留白：内容占 ~82%
let inset: CGFloat = 92
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let radius: CGFloat = rect.width * 0.225
let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// 阴影
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34,
              color: NSColor.black.withAlphaComponent(0.30).cgColor)
ctx.addPath(path)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 渐变主体
ctx.saveGState()
ctx.addPath(path)
ctx.clip()
let colors = [
    NSColor(srgbRed: 0.36, green: 0.42, blue: 0.98, alpha: 1).cgColor,  // 靛蓝
    NSColor(srgbRed: 0.53, green: 0.29, blue: 0.94, alpha: 1).cgColor,  // 紫
] as CFArray
let space = CGColorSpaceCreateDeviceRGB()
if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY),
                           options: [])
}
// 顶部高光
let highlight = CGGradient(colorsSpace: space,
                           colors: [NSColor.white.withAlphaComponent(0.22).cgColor,
                                    NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                           locations: [0, 1])!
ctx.drawLinearGradient(highlight,
                       start: CGPoint(x: 0, y: rect.maxY),
                       end: CGPoint(x: 0, y: rect.midY),
                       options: [])
ctx.restoreGState()

// 白色「译」字
let glyph = "译" as NSString
let font = NSFont.systemFont(ofSize: rect.width * 0.52, weight: .semibold)
let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor.white,
]
let glyphSize = glyph.size(withAttributes: attrs)
let glyphOrigin = CGPoint(x: rect.midX - glyphSize.width / 2,
                          y: rect.midY - glyphSize.height / 2 + rect.width * 0.01)
glyph.draw(at: glyphOrigin, withAttributes: attrs)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("渲染失败"); exit(1)
}
let pngPath = "\(outDir)/icon_1024.png"
try png.write(to: URL(fileURLWithPath: pngPath))
print("wrote \(pngPath)")
