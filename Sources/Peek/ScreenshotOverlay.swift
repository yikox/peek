import AppKit

enum ScreenshotMode {
    case translate   // 框选 → OCR → 翻译
    case ocr         // 框选 → 只 OCR
    case capture     // 框选 → 弹缩略图，复制 / 保存 / 识别随用户选

    var label: String {
        switch self {
        case .translate: return "翻译"
        case .ocr: return "OCR"
        case .capture: return "截图"
        }
    }
}

/// 截图取词：冻结当前屏幕 → 全屏遮罩上拖框 → 裁剪 → OCR。
///
/// 和原版的关键差别：
/// - 画面**只抓一次**（CGDisplayCreateImage），之后所有绘制都用这张 CGImage，
///   拖框时不再反复截图 —— 这是它跟手的前提。
/// - 遮罩窗口自己画暗色 + 挖洞 + 放大镜，没有额外视图层级，也没有动画。
/// - 框选结束后立刻关窗再识别，避免遮罩残留在下一次截图里。
final class ScreenshotController {

    static let shared = ScreenshotController()

    private var window: ScreenshotWindow?
    private var isActive = false
    /// 框选要抢焦点（makeKey），记下抢之前是谁在前台，截完还回去
    private var previousApp: NSRunningApplication?

    private init() {}

    /// 开始截图。返回 false 表示没权限/抓屏失败。
    @discardableResult
    func begin(_ mode: ScreenshotMode) -> Bool {
        guard !isActive else { return true }
        guard ScreenCapture.hasPermission else {
            Log.info("截图: 无屏幕录制权限")
            return false
        }
        guard let screen = screenUnderMouse() ?? NSScreen.main else { return false }
        guard let frozen = ScreenCapture.freeze(screen) else {
            Log.info("截图: 抓屏失败")
            return false
        }

        isActive = true
        previousApp = NSWorkspace.shared.frontmostApplication
        PanelController.shared.hide()

        let overlay = ScreenshotWindow(screen: screen, image: frozen)
        window = overlay
        overlay.onFinish = { [weak self] rect in
            guard let self else { return }
            let cropRect = rect
            self.finish(rect: cropRect, screen: screen, image: frozen, mode: mode)
        }
        overlay.onCancel = { [weak self] in
            Log.info("截图: 已取消")
            self?.teardown()
            self?.restorePreviousApp()
        }
        overlay.present()
        Log.info("截图: 遮罩已显示 \(Int(screen.frame.width))×\(Int(screen.frame.height))pt @\(Int(screen.backingScaleFactor))x 模式=\(mode.label)")
        return true
    }

    private func finish(rect: NSRect, screen: NSScreen, image: CGImage, mode: ScreenshotMode) {
        teardown()

        // 视图坐标（左下原点）→ 像素坐标（左上原点）
        let scale = CGFloat(image.width) / screen.frame.width
        let pixelRect = CGRect(x: rect.minX * scale,
                               y: (screen.frame.height - rect.maxY) * scale,
                               width: rect.width * scale,
                               height: rect.height * scale)

        guard let cropped = ScreenCapture.crop(image, to: pixelRect) else {
            Log.info("截图: 裁剪失败 rect=\(NSStringFromRect(pixelRect))")
            return
        }
        // 纯截图：不解码，直接把裁好的图送去缩略图窗
        if mode == .capture {
            Log.info("截图: 裁剪 \(cropped.width)×\(cropped.height)px，弹缩略图")
            CaptureResultController.shared.show(cropped, restoreTo: previousApp)
            return
        }

        Log.info("截图: 裁剪 \(cropped.width)×\(cropped.height)px，开始识别")
        PanelController.shared.recognizeScreenshot(cropped, mode: mode)
    }

    private func teardown() {
        window?.orderOut(nil)
        window = nil
        isActive = false
    }

    /// 取消截图时把焦点还给原来的应用（框选时被我们顶掉了）
    private func restorePreviousApp() {
        defer { previousApp = nil }
        guard let app = previousApp,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              !app.isTerminated else { return }
        app.activate()
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
    }
}

// MARK: - 遮罩窗口

final class ScreenshotWindow: NSWindow {

    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    init(screen: NSScreen, image: CGImage) {
        super.init(contentRect: screen.frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        level = .screenSaver
        backgroundColor = .black
        isOpaque = true
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        animationBehavior = .none

        let view = ScreenshotView(frame: NSRect(origin: .zero, size: screen.frame.size), image: image)
        view.onFinish = { [weak self] rect in
            self?.onFinish?(rect)
        }
        view.onCancel = { [weak self] in
            self?.onCancel?()
        }
        contentView = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
        if let view = contentView {
            makeFirstResponder(view)
        }
    }
}

// MARK: - 遮罩视图

final class ScreenshotView: NSView {

    var onFinish: ((NSRect) -> Void)?
    var onCancel: (() -> Void)?

    private let image: CGImage
    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var tracking: NSTrackingArea?

    private let dim: CGFloat = 0.42
    private let magSize = NSSize(width: 108, height: 128)
    private let magZoom: CGFloat = 8

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    // MARK: 鼠标

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let end = currentPoint else { return }
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        // 太小当成误点
        guard rect.width >= 4, rect.height >= 4 else {
            onCancel?()
            return
        }
        onFinish?(rect)
    }

    override func mouseMoved(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(KeyCode.escape) {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // MARK: 绘制

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none

        // 1) 冻结画面铺满
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)

        // 2) 暗色遮罩（选区挖洞）
        let selection = currentSelection()
        let shade = NSBezierPath(rect: bounds)
        if let selection {
            shade.appendRect(selection)
            shade.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(dim).setFill()
        shade.fill()

        if let selection {
            // 3) 选区描边
            Theme.accent.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1.5
            border.stroke()

            // 4) 尺寸标签
            let label = "\(Int(selection.width)) × \(Int(selection.height))"
            drawPill(label, at: NSPoint(x: selection.minX, y: selection.maxY + 6), anchorLeft: true)

            // 5) 放大镜
            if let cursor = currentPoint {
                drawMagnifier(at: cursor)
            }
        } else {
            drawPill("拖动选择区域　·　ESC 取消", at: NSPoint(x: bounds.midX, y: bounds.maxY - 60), centered: true)
        }
    }

    /// 离屏渲染 / 自检用：直接摆一个选区出来，不用真的拖。
    func debugSetSelection(_ rect: NSRect) {
        startPoint = NSPoint(x: rect.minX, y: rect.maxY)
        currentPoint = NSPoint(x: rect.maxX, y: rect.minY)
        needsDisplay = true
    }

    private func currentSelection() -> NSRect? {        guard let start = startPoint, let end = currentPoint else { return nil }
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        return rect.width >= 4 && rect.height >= 4 ? rect : nil
    }

    private func drawPill(_ text: String, at point: NSPoint, anchorLeft: Bool = false, centered: Bool = false) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attributes)
        let pad = NSSize(width: 7, height: 3)
        var origin = point
        if centered {
            origin.x -= (size.width + pad.width * 2) / 2
            origin.y -= (size.height + pad.height * 2) / 2
        } else if !anchorLeft {
            origin.x += 8
            origin.y -= (size.height + pad.height * 2) / 2
        }
        let box = NSRect(x: origin.x, y: origin.y,
                         width: size.width + pad.width * 2,
                         height: size.height + pad.height * 2)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
        (text as NSString).draw(at: NSPoint(x: box.minX + pad.width, y: box.minY + pad.height),
                                withAttributes: attributes)
    }

    private func drawMagnifier(at cursor: NSPoint) {
        var box = NSRect(x: cursor.x + 18, y: cursor.y - magSize.height - 18,
                         width: magSize.width, height: magSize.height)
        if box.maxX > bounds.maxX - 8 { box.origin.x = cursor.x - magSize.width - 18 }
        if box.minY < bounds.minY + 8 { box.origin.y = cursor.y + 18 }

        let clip = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        NSGraphicsContext.current?.saveGraphicsState()
        clip.addClip()
        // 把整张图放大 magZoom 倍后再平移，让光标处正好落在放大镜中心
        let scaled = NSRect(x: box.midX - cursor.x * magZoom,
                            y: box.midY - cursor.y * magZoom,
                            width: bounds.width * magZoom,
                            height: bounds.height * magZoom)
        NSImage(cgImage: image, size: bounds.size).draw(in: scaled)
        NSGraphicsContext.current?.restoreGraphicsState()

        // 边框 + 十字线
        NSColor.white.withAlphaComponent(0.85).setStroke()
        let framePath = NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3)
        framePath.lineWidth = 1
        framePath.stroke()

        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: box.midX, y: box.minY))
        cross.line(to: NSPoint(x: box.midX, y: box.maxY))
        cross.move(to: NSPoint(x: box.minX, y: box.midY))
        cross.line(to: NSPoint(x: box.maxX, y: box.midY))
        Theme.accent.withAlphaComponent(0.9).setStroke()
        cross.lineWidth = 1
        cross.stroke()
    }
}
