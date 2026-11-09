import AppKit
import Foundation

// 生成 App 图标：1024×1024，深色圆角方块 + 一只从墙沿后面探出的眼睛。
//
// 概念说明：Peek 的本义是「偷看一眼」。单纯画一只眼睛会变成监控/隐私类的符号，
// 所以在眼睛前面压一条亮色的墙沿，眼睛只露出一部分，动作感才出来。
// 尺寸统一按 1024 的视觉坐标书写（y 向下），绘制时由 GY() 翻成 CoreGraphics 坐标。
//
// 用法: swift tools/make_icon.swift <输出目录>

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/icon"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let S: CGFloat = 1024

func GY(_ vy: CGFloat) -> CGFloat { S - vy }

func newCanvas() -> (NSBitmapImageRep, CGContext) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(S), pixelsHigh: Int(S),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    return (rep, gctx.cgContext)
}

// macOS 图标轮廓是超椭圆（squircle）而不是圆角矩形，n≈5 时最接近
func squircle(_ rect: CGRect, n: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    for i in 0...900 {
        let t = CGFloat(i) / 900 * .pi * 2
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: cy + b * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
    }
    path.closeSubpath()
    return path
}

// 杏仁形的眼白：上下各一段二次贝塞尔，h 为总高度
func almond(cx: CGFloat, cy: CGFloat, w: CGFloat, h: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let left = CGPoint(x: cx - w / 2, y: cy)
    let right = CGPoint(x: cx + w / 2, y: cy)
    path.move(to: left)
    path.addQuadCurve(to: right, control: CGPoint(x: cx, y: cy + h))
    path.addQuadCurve(to: left, control: CGPoint(x: cx, y: cy - h))
    path.closeSubpath()
    return path
}

func fill(_ ctx: CGContext, _ path: CGPath, _ color: NSColor) {
    ctx.addPath(path)
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}

func linear(_ ctx: CGContext, from: CGPoint, to: CGPoint, _ colors: [NSColor],
            _ stops: [CGFloat]? = nil) {
    let locations = stops ?? (colors.count == 2 ? [0, 1] : [])
    guard locations.count == colors.count else { return }
    guard let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors.map { $0.cgColor } as CFArray,
                             locations: locations) else { return }
    ctx.drawLinearGradient(g, start: from, end: to,
                           options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

let (rep, ctx) = newCanvas()
let shape = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

let ink = NSColor(srgbRed: 0.03, green: 0.04, blue: 0.08, alpha: 1)
let iris = NSColor(srgbRed: 0.17, green: 0.26, blue: 0.44, alpha: 1)
let sclera = NSColor(srgbRed: 1.0, green: 0.988, blue: 0.962, alpha: 1)

// ── 背景
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()
linear(ctx, from: CGPoint(x: 0, y: S), to: CGPoint(x: S, y: 0),
       [NSColor(srgbRed: 0.17, green: 0.16, blue: 0.26, alpha: 1),
        NSColor(srgbRed: 0.08, green: 0.08, blue: 0.13, alpha: 1)])
ctx.restoreGState()

// ── 眼睛
let eyeCX = S / 2
let eyeCY = GY(440)
let eyeW: CGFloat = 560
let eyeH: CGFloat = 368
let irisR: CGFloat = 100

let white = almond(cx: eyeCX, cy: eyeCY, w: eyeW, h: eyeH)
fill(ctx, white, sclera)

ctx.saveGState()
ctx.addPath(white)
ctx.clip()

// 上眼睑阴影，让眼白不是一片死白
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: eyeCY + eyeH / 2 - 80, width: S, height: 80))
linear(ctx, from: CGPoint(x: 0, y: eyeCY + eyeH / 2),
       to: CGPoint(x: 0, y: eyeCY + eyeH / 2 - 80),
       [NSColor.black.withAlphaComponent(0.16), NSColor.black.withAlphaComponent(0)])
ctx.restoreGState()

let ix = eyeCX + 14
let iy = eyeCY + 40
let irisPath = CGPath(ellipseIn: CGRect(x: ix - irisR, y: iy - irisR,
                                        width: irisR * 2, height: irisR * 2), transform: nil)
fill(ctx, irisPath, iris)

// 虹膜下方的一道湿润反光
ctx.saveGState()
ctx.addPath(irisPath)
ctx.clip()
fill(ctx, CGPath(ellipseIn: CGRect(x: ix - irisR * 0.72, y: iy - irisR * 0.80,
                                   width: irisR * 1.44, height: irisR * 1.44), transform: nil),
     NSColor.white.withAlphaComponent(0.13))
ctx.restoreGState()

let pupilR = irisR * 0.44
fill(ctx, CGPath(ellipseIn: CGRect(x: ix - pupilR, y: iy - pupilR,
                                   width: pupilR * 2, height: pupilR * 2), transform: nil), ink)

// 高光
let hlR = irisR * 0.25
fill(ctx, CGPath(ellipseIn: CGRect(x: ix - irisR * 0.42 - hlR, y: iy + irisR * 0.40 - hlR,
                                   width: hlR * 2, height: hlR * 2), transform: nil),
     NSColor.white.withAlphaComponent(0.94))
ctx.restoreGState()

// ── 墙沿：把眼睛下半挡住，只露出上半
ctx.saveGState()
ctx.addPath(shape)
ctx.clip()

let wallY: CGFloat = 528
let wall = CGRect(x: 0, y: 0, width: S, height: GY(wallY))

// 墙挡住光，在眼睛上落一层投影 —— 这是「在墙后面」的关键
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: wall.maxY, width: S, height: 46))
linear(ctx, from: CGPoint(x: 0, y: wall.maxY + 46), to: CGPoint(x: 0, y: wall.maxY),
       [NSColor.black.withAlphaComponent(0), NSColor.black.withAlphaComponent(0.36)])
ctx.restoreGState()

ctx.saveGState()
ctx.clip(to: wall)
linear(ctx, from: CGPoint(x: 0, y: wall.maxY), to: CGPoint(x: 0, y: wall.minY),
       [NSColor(srgbRed: 0.97, green: 0.955, blue: 0.93, alpha: 1),
        NSColor(srgbRed: 0.55, green: 0.52, blue: 0.47, alpha: 1),
        NSColor(srgbRed: 0.14, green: 0.13, blue: 0.12, alpha: 1)],
       [0, 0.28, 1])

// 墙面靠上沿的暗带
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: wall.maxY - 60, width: S, height: 60))
linear(ctx, from: CGPoint(x: 0, y: wall.maxY), to: CGPoint(x: 0, y: wall.maxY - 60),
       [NSColor.black.withAlphaComponent(0.24), NSColor.black.withAlphaComponent(0)])
ctx.restoreGState()

// 墙沿受光的一道边
ctx.saveGState()
ctx.clip(to: CGRect(x: 0, y: wall.maxY - 9, width: S, height: 9))
linear(ctx, from: CGPoint(x: 0, y: wall.maxY), to: CGPoint(x: 0, y: wall.maxY - 9),
       [NSColor.white.withAlphaComponent(0.90), NSColor.white.withAlphaComponent(0.06)])
ctx.restoreGState()
ctx.restoreGState()

// ── 暗角
let vignette = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor.black.withAlphaComponent(0).cgColor,
                                   NSColor.black.withAlphaComponent(0.28).cgColor] as CFArray,
                          locations: [0.45, 1])!
ctx.drawRadialGradient(vignette,
                       startCenter: CGPoint(x: S / 2, y: GY(420)), startRadius: 0,
                       endCenter: CGPoint(x: S / 2, y: GY(420)), endRadius: 780,
                       options: [])
ctx.restoreGState()

guard let png = rep.representation(using: .png, properties: [:]) else {
    print("渲染失败"); exit(1)
}
let path = "\(outDir)/icon_1024.png"
try png.write(to: URL(fileURLWithPath: path))
print("wrote \(path)")
