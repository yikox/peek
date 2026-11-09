import AppKit
import UniformTypeIdentifiers

/// 截图完成后的缩略图浮窗。
///
/// 存在的意义：把「截图」和「截图之后干什么」拆开。以前 ⌥S / ⌥A 框完就直接进 OCR，
/// 想要一张干净的图只能绕道系统截图。现在框完先给一张缩略图，再决定复制 / 保存 / 识别。
///
/// 交互约定：
/// - 不激活 App（nonactivatingPanel），不切 Space，不打断原应用
/// - 点窗口外面 / ESC 关闭；⌘C 复制、⌘S 保存、⏎ 识别
/// - 双击缩略图 = 复制并关闭
final class CaptureResultController {

    static let shared = CaptureResultController()

    private var panel: CaptureResultPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var image: CGImage?
    private var isDismissing = false
    /// 框选时被顶掉的前台应用，关窗后还回去
    private var restoreApp: NSRunningApplication?

    private init() {}

    // MARK: - 显示

    func show(_ image: CGImage, restoreTo app: NSRunningApplication? = nil) {
        close()
        isDismissing = false
        self.image = image
        restoreApp = app

        let thumb = CaptureResultPanel.thumbSize(for: image)
        let windowSize = CaptureResultPanel.windowSize(thumb: thumb)

        let panel = CaptureResultPanel(size: windowSize, thumb: thumb)
        panel.onCopy = { [weak self] in self?.copyToPasteboard() }
        panel.onSave = { [weak self] in self?.save() }
        panel.onOCR = { [weak self] in self?.runOCR() }
        panel.onDoubleClick = { [weak self] in self?.copyToPasteboard() }
        panel.setImage(image)

        self.panel = panel
        position(panel)
        panel.present()
        installMonitors()

        Log.info("截图: 缩略图窗已显示 \(image.width)×\(image.height)px 窗口=\(Int(windowSize.width))×\(Int(windowSize.height))pt")
    }

    func close() {
        guard let panel else { return }
        removeMonitors()
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
        image = nil

        let target = restoreApp
        restoreApp = nil
        // 框选时为了 makeKey 把 Peek 拉到了前台，关掉缩略图后把焦点还回去。
        // 从菜单栏触发时前台本来就是 Peek 自己，跳过。
        if let target,
           target.bundleIdentifier != Bundle.main.bundleIdentifier,
           !target.isTerminated {
            target.activate()
        }
    }

    // MARK: - 三个动作

    /// 复制到剪贴板。PNG 和 TIFF 都写一份：前者给聊天工具，后者给 Pages / Keynote 这类老派应用。
    private func copyToPasteboard() {
        guard let image, !isDismissing else { return }
        isDismissing = true

        let rep = NSBitmapImageRep(cgImage: image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        var wrote = false
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
            wrote = true
        }
        if let tiff = rep.representation(using: .tiff, properties: [:]) {
            pasteboard.setData(tiff, forType: .tiff)
            wrote = true
        }

        Log.info("截图: 已复制到剪贴板 \(image.width)×\(image.height)px wrote=\(wrote)")
        panel?.flash("已复制")
        NSSound(named: "Pop")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            self?.close()
        }
    }

    /// 保存为 PNG。弹标准存储面板（默认落到桌面），不自作主张往某个目录里塞文件。
    private func save() {
        guard let image, !isDismissing else { return }
        isDismissing = true

        let savePanel = NSSavePanel()
        savePanel.title = "保存截图"
        savePanel.prompt = "保存"
        savePanel.allowedContentTypes = [.png]
        savePanel.canCreateDirectories = true
        savePanel.isExtensionHidden = false
        savePanel.nameFieldStringValue = Self.defaultFileName()
        savePanel.directoryURL = FileManager.default.urls(for: .desktopDirectory,
                                                          in: .userDomainMask).first

        // nonactivating 面板的 App 在后台，不激活的话存储面板会弹在别的应用后面
        NSApp.activate(ignoringOtherApps: true)
        savePanel.begin { [weak self] response in
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.close() }
                guard response == .OK, let url = savePanel.url else {
                    Log.info("截图: 保存已取消")
                    return
                }
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    Log.info("截图: PNG 编码失败")
                    return
                }
                do {
                    try data.write(to: url)
                    Log.info("截图: 已保存 \(url.path) \(data.count) 字节")
                } catch {
                    Log.info("截图: 保存失败 \(error.localizedDescription)")
                }
            }
        }
    }

    /// 识别文字：关掉缩略图，把这张图交给主面板走 OCR。
    private func runOCR() {
        guard let image, !isDismissing else { return }
        isDismissing = true
        // 接下来要显示主面板，别把焦点还回原应用
        restoreApp = nil
        close()
        PanelController.shared.recognizeScreenshot(image, mode: .translate)
    }

    private static func defaultFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Peek \(formatter.string(from: Date())).png"
    }

    // MARK: - 定位与监听

    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 14
        if y < visible.minY + 10 {
            y = mouse.y + 14
        }
        x = min(max(visible.minX + 10, x), visible.maxX - size.width - 10)
        y = min(max(visible.minY + 10, y), visible.maxY - size.height - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func installMonitors() {
        removeMonitors()

        // 点窗口外面就收起来，跟系统截图缩略图一个脾气
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel?.isKeyWindow == true else { return event }
            if event.keyCode == UInt16(KeyCode.escape) {
                self.close()
                return nil
            }
            if event.keyCode == UInt16(KeyCode.enter) || event.keyCode == UInt16(KeyCode.keypadEnter) {
                self.runOCR()
                return nil
            }
            if event.modifierFlags.contains(.command) {
                switch event.charactersIgnoringModifiers {
                case "c": self.copyToPasteboard(); return nil
                case "s": self.save(); return nil
                default: break
                }
            }
            return event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }
}

// MARK: - 窗口

final class CaptureResultPanel: NSPanel {

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onOCR: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    private let resultView: CaptureResultView

    private static let pad: CGFloat = 12
    private static let maxThumbW: CGFloat = 360
    private static let maxThumbH: CGFloat = 240
    private static let minWidth: CGFloat = 292
    private static let infoH: CGFloat = 15
    private static let buttonH: CGFloat = 32
    private static let stackGap: CGFloat = 8

    static func thumbSize(for image: CGImage) -> NSSize {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(1, min(maxThumbW / w, maxThumbH / h))
        return NSSize(width: max(1, (w * scale).rounded()),
                      height: max(1, (h * scale).rounded()))
    }

    static func windowSize(thumb: NSSize) -> NSSize {
        NSSize(width: max(thumb.width, minWidth) + pad * 2,
               height: pad * 2 + thumb.height + 6 + infoH + stackGap + buttonH)
    }

    init(size: NSSize, thumb: NSSize) {
        let inset = Self.pad
        let viewRect = NSRect(origin: .zero, size: size)
        resultView = CaptureResultView(frame: viewRect,
                                       pad: inset,
                                       thumbSize: thumb,
                                       infoH: Self.infoH,
                                       buttonH: Self.buttonH,
                                       gap: Self.stackGap)

        super.init(contentRect: viewRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        contentView = resultView

        resultView.onCopy = { [weak self] in self?.onCopy?() }
        resultView.onSave = { [weak self] in self?.onSave?() }
        resultView.onOCR = { [weak self] in self?.onOCR?() }
        resultView.onDoubleClickImage = { [weak self] in self?.onDoubleClick?() }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func zoom(_ sender: Any?) {}

    func setImage(_ image: CGImage) {
        resultView.setImage(image)
    }

    func flash(_ message: String) {
        resultView.flash(message)
    }

    func present() {
        makeKeyAndOrderFront(nil)
    }
}

// MARK: - 内容视图

final class CaptureResultView: NSView {

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onOCR: (() -> Void)?
    var onDoubleClickImage: (() -> Void)?

    private let thumbView = ThumbnailView()
    private let infoLabel = NSTextField(labelWithString: "")
    private let copyButton = CaptureActionView(symbol: "doc.on.doc", title: "复制")
    private let saveButton = CaptureActionView(symbol: "square.and.arrow.down", title: "保存")
    private let ocrButton = CaptureActionView(symbol: "text.viewfinder", title: "识别文字")

    private let pad: CGFloat
    private let thumbSize: NSSize
    private let infoH: CGFloat
    private let buttonH: CGFloat
    private let gap: CGFloat

    private let card = NSView()
    private var flashLabel: NSTextField?

    init(frame: NSRect, pad: CGFloat, thumbSize: NSSize, infoH: CGFloat, buttonH: CGFloat, gap: CGFloat) {
        self.pad = pad
        self.thumbSize = thumbSize
        self.infoH = infoH
        self.buttonH = buttonH
        self.gap = gap
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        applyBackground()

        addSubview(thumbView)

        infoLabel.font = NSFont.systemFont(ofSize: 11)
        infoLabel.textColor = Theme.secondary
        infoLabel.alignment = .center
        infoLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(infoLabel)

        copyButton.onClick = { [weak self] in self?.onCopy?() }
        saveButton.onClick = { [weak self] in self?.onSave?() }
        ocrButton.onClick = { [weak self] in self?.onOCR?() }
        addSubview(copyButton)
        addSubview(saveButton)
        addSubview(ocrButton)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        var cg = Theme.panel.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = Theme.panel.cgColor
        }
        layer?.backgroundColor = cg
    }

    func setImage(_ image: CGImage) {
        thumbView.setImage(image)

        let px = "\(image.width) × \(image.height) px"
        let rep = NSBitmapImageRep(cgImage: image)
        if let bytes = rep.representation(using: .png, properties: [:])?.count {
            infoLabel.stringValue = "\(px) · \(Self.byteText(bytes))"
        } else {
            infoLabel.stringValue = px
        }
        // 中文两端对齐没意义，尺寸这种纯数字串居中更好看
        infoLabel.alignment = .center
    }

    private static func byteText(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    func flash(_ message: String) {
        flashLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        label.layer?.cornerRadius = 7
        label.layer?.masksToBounds = true
        label.frame = NSRect(x: (bounds.width - 92) / 2,
                             y: thumbView.frame.midY - 15,
                             width: 92, height: 30)
        addSubview(label)
        flashLabel = label

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak label] in
            label?.removeFromSuperview()
        }
    }

    override func layout() {
        super.layout()

        let contentW = bounds.width - pad * 2
        let thumbX = pad + (contentW - thumbSize.width) / 2
        let thumbY = pad + buttonH + gap + infoH + 6

        thumbView.frame = NSRect(x: thumbX, y: thumbY,
                                 width: thumbSize.width, height: thumbSize.height)
        infoLabel.frame = NSRect(x: pad, y: pad + buttonH + gap,
                                 width: contentW, height: infoH)

        let buttonGap: CGFloat = 6
        let buttonW = (contentW - buttonGap * 2) / 3
        copyButton.frame = NSRect(x: pad, y: pad, width: buttonW, height: buttonH)
        saveButton.frame = NSRect(x: pad + buttonW + buttonGap, y: pad, width: buttonW, height: buttonH)
        ocrButton.frame = NSRect(x: pad + (buttonW + buttonGap) * 2, y: pad, width: buttonW, height: buttonH)
    }

    // 双击缩略图 = 复制
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, thumbView.frame.contains(convert(event.locationInWindow, from: nil)) {
            onDoubleClickImage?()
            return
        }
        super.mouseDown(with: event)
    }
}

// MARK: - 缩略图

/// 自绘缩略图。用 NSImageView 时 layer 的 cornerRadius 裁不住图片内容
/// （图片是直接画进 layer 的，不是背景色），所以这里在 draw 里套一层圆角裁剪。
final class ThumbnailView: NSView {

    private var image: CGImage?

    override var isOpaque: Bool { false }

    func setImage(_ image: CGImage) {
        self.image = image
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, let ctx = NSGraphicsContext.current?.cgContext else { return }

        let path = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
        ctx.saveGState()
        path.addClip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
        ctx.restoreGState()

        // 细边框，避免浅色截图和白色窗口糊在一起
        effectiveAppearance.performAsCurrentDrawingAppearance {
            Theme.border.setStroke()
        }
        path.lineWidth = 1
        path.stroke()
    }
}

// MARK: - 按钮

/// 轻量按钮：圆角底 + 图标 + 文字，自带 hover / 按下反馈。
/// 不用 NSButton 是因为要和卡片配色一致，且悬停态需要自定义。
final class CaptureActionView: NSView {

    var onClick: (() -> Void)?

    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovered = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?

    init(symbol: String, title: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = Theme.text
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        label.stringValue = title
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = Theme.text
        label.alignment = .center
        addSubview(label)

        refreshBackground()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let iconSize: CGFloat = 13
        let iconGap: CGFloat = 4
        label.sizeToFit()
        let labelW = min(label.frame.width, bounds.width - iconSize - iconGap - 4)
        let total = iconSize + iconGap + labelW
        let startX = (bounds.width - total) / 2

        iconView.frame = NSRect(x: startX, y: (bounds.height - iconSize) / 2,
                                width: iconSize, height: iconSize)
        label.frame = NSRect(x: startX + iconSize + iconGap,
                             y: (bounds.height - 15) / 2,
                             width: labelW, height: 15)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        refreshBackground()
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        pressed = false
        refreshBackground()
        NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        refreshBackground()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        refreshBackground()
        if inside { onClick?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    private func refreshBackground() {
        // 直接用白色系而不是 Theme.resultBG：亮色下 0.933 和窗口白只差 7%，
        // 按钮边界会糊掉，压到 0.92 再补一道细边才立得住。
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base = NSColor(white: isDark ? 0.21 : 0.92, alpha: 1)
        var color = base
        if pressed {
            color = base.blended(withFraction: 0.14, of: .black) ?? base
        } else if hovered {
            color = base.blended(withFraction: 0.06, of: .black) ?? base
        }

        var bg = color.cgColor
        var border = NSColor.separatorColor.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bg = color.cgColor
            border = NSColor.separatorColor.cgColor
        }
        layer?.backgroundColor = bg
        layer?.borderWidth = 0.5
        layer?.borderColor = border
    }
}
