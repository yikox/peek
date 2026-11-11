import AppKit

/// ⌥Z 弹出的剪贴板历史小窗。
///
/// 和截图缩略图窗同一套脾气：不激活 App、不切 Space、点外面就收。
/// 点某一条 = 写回剪贴板 + 关窗，接着 ⌘V 就能用 —— 中间不插任何确认步骤。
final class ClipboardHistoryWindow {

    static let shared = ClipboardHistoryWindow()

    private var panel: ClipboardHistoryPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {}

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    func show() {
        close()
        // 翻译浮窗的窗口层级比这里高，留着会盖住历史窗
        PanelController.shared.hide()

        let items = ClipboardHistory.shared.items
        let panel = ClipboardHistoryPanel(items: items)
        panel.onPick = { [weak self] item in
            self?.pick(item)
        }
        self.panel = panel

        position(panel)
        panel.present()
        installMonitors()
        Log.info("剪贴板历史: 窗口显示 \(items.count) 条")
    }

    func close() {
        guard let panel else { return }
        Log.info("剪贴板历史: 窗口关闭")
        removeMonitors()
        panel.orderOut(nil)
        panel.contentView = nil
        self.panel = nil
    }

    private func pick(_ item: ClipboardHistory.Item) {
        ClipboardHistory.shared.copyToPasteboard(item)
        NSSound(named: "Pop")?.play()
        Log.info("剪贴板历史: 选中并关闭 → \(ClipboardHistory.preview(item.text))")
        close()
    }

    /// 自检用：走真实的选中路径（写回剪贴板 + 关窗），把行为测全
    func debugPick(index: Int) {
        let items = ClipboardHistory.shared.items
        guard items.indices.contains(index) else {
            Log.info("剪贴板历史: 自检索引 \(index) 越界（共 \(items.count) 条）")
            return
        }
        pick(items[index])
    }

    /// 把当前窗口原样导出成 PNG，用于验证真实数据下的排版。
    /// 窗口没开就先开一个 —— 导出不该依赖「此刻恰好有人按了 ⌥Z」。
    func debugSnapshot(to path: String) {
        if panel == nil { show() }
        guard let view = panel?.contentView else {
            Log.info("剪贴板历史: 窗口未打开，无法导出")
            return
        }
        Snapshot.captureView(view, to: path)
        Log.info("剪贴板历史: 已导出 \(path)")
    }

    // MARK: - 定位

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

    // MARK: - 监听

    private func installMonitors() {
        removeMonitors()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let panel = self.panel, panel.isKeyWindow else { return event }

            switch event.keyCode {
            case UInt16(KeyCode.escape):
                self.close()
                return nil
            case UInt16(KeyCode.enter), UInt16(KeyCode.keypadEnter):
                panel.pickSelected()
                return nil
            case UInt16(KeyCode.upArrow):
                panel.moveSelection(by: -1)
                return nil
            case UInt16(KeyCode.downArrow):
                panel.moveSelection(by: 1)
                return nil
            default:
                break
            }

            // 1-9 直选。带 ⌘ / ⌥ / ⌃ 的不抢，留给系统和其他快捷键
            if !event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
                return event
            }
            if let chars = event.charactersIgnoringModifiers,
               let number = Int(chars), number >= 1, number <= 9 {
                panel.pick(index: number - 1)
                return nil
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

final class ClipboardHistoryPanel: NSPanel {

    var onPick: ((ClipboardHistory.Item) -> Void)?

    private let listView: ClipboardListView

    init(items: [ClipboardHistory.Item]) {
        let size = ClipboardListView.windowSize(count: items.count)
        listView = ClipboardListView(items: items,
                                     frame: NSRect(origin: .zero, size: size))

        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        contentView = listView
        listView.onPick = { [weak self] item in self?.onPick?(item) }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func zoom(_ sender: Any?) {}

    func present() {
        makeKeyAndOrderFront(nil)
    }

    func moveSelection(by delta: Int) { listView.moveSelection(by: delta) }
    func pickSelected() { listView.pickSelected() }
    func pick(index: Int) { listView.pick(index: index) }
}

// MARK: - 列表

final class ClipboardListView: NSView {

    var onPick: ((ClipboardHistory.Item) -> Void)?

    private let items: [ClipboardHistory.Item]
    private var rows: [ClipRowView] = []
    private var selectedIndex = 0
    private let titleLabel = NSTextField(labelWithString: "剪贴板历史")
    private let countLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "↑↓ 选择 · ⏎ 复制 · 1-9 直选 · Esc 关闭")
    private let emptyLabel = NSTextField(labelWithString: "还没有记录，先复制点什么")

    private static let width: CGFloat = 340
    private static let pad: CGFloat = 8
    private static let headerH: CGFloat = 24
    private static let rowH: CGFloat = 34
    private static let hintH: CGFloat = 22
    private static let emptyH: CGFloat = 56

    static func windowSize(count: Int) -> NSSize {
        let bodyH = count == 0 ? emptyH : CGFloat(min(count, ClipboardHistory.limit)) * rowH
        return NSSize(width: width, height: pad * 2 + headerH + bodyH + hintH)
    }

    init(items: [ClipboardHistory.Item], frame: NSRect) {
        self.items = items
        super.init(frame: frame)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        applyBackground()

        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = Theme.secondary
        addSubview(titleLabel)

        countLabel.font = NSFont.systemFont(ofSize: 11)
        countLabel.textColor = Theme.secondary
        countLabel.alignment = .right
        countLabel.stringValue = items.isEmpty ? "" : "\(items.count) / \(ClipboardHistory.limit)"
        addSubview(countLabel)

        hintLabel.font = NSFont.systemFont(ofSize: 10.5)
        hintLabel.textColor = Theme.secondary
        hintLabel.alignment = .center
        addSubview(hintLabel)

        if items.isEmpty {
            emptyLabel.font = NSFont.systemFont(ofSize: 12)
            emptyLabel.textColor = Theme.secondary
            emptyLabel.alignment = .center
            addSubview(emptyLabel)
            return
        }

        for (i, item) in items.enumerated() {
            let row = ClipRowView(item: item, index: i)
            row.onPick = { [weak self] in self?.pick(index: i) }
            addSubview(row)
            rows.append(row)
        }
        refreshSelection()
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

    override func layout() {
        super.layout()

        let pad = Self.pad
        let contentW = bounds.width - pad * 2
        let top = bounds.height - pad

        titleLabel.frame = NSRect(x: pad + 2, y: top - Self.headerH + 6, width: 160, height: 16)
        countLabel.frame = NSRect(x: bounds.width - pad - 2 - 120,
                                  y: top - Self.headerH + 7, width: 120, height: 15)
        hintLabel.frame = NSRect(x: pad, y: pad - 2, width: contentW, height: 15)

        var y = top - Self.headerH
        if items.isEmpty {
            emptyLabel.frame = NSRect(x: pad, y: y - Self.emptyH, width: contentW, height: 20)
            return
        }
        for row in rows {
            row.frame = NSRect(x: pad, y: y - Self.rowH, width: contentW, height: Self.rowH)
            y -= Self.rowH
        }
    }

    // MARK: - 选择

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = max(0, min(rows.count - 1, selectedIndex + delta))
        refreshSelection()
    }

    func pickSelected() {
        pick(index: selectedIndex)
    }

    func pick(index: Int) {
        guard items.indices.contains(index) else { return }
        onPick?(items[index])
    }

    private func refreshSelection() {
        for (i, row) in rows.enumerated() {
            row.isSelected = (i == selectedIndex)
        }
    }
}

// MARK: - 单行

final class ClipRowView: NSView {

    var onPick: (() -> Void)?

    var isSelected = false {
        didSet { refreshBackground() }
    }

    private let item: ClipboardHistory.Item
    private let textLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var hovered = false
    private var pressed = false
    private var trackingArea: NSTrackingArea?

    init(item: ClipboardHistory.Item, index: Int) {
        self.item = item
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        textLabel.stringValue = ClipboardHistory.preview(item.text)
        textLabel.font = NSFont.systemFont(ofSize: 12.5)
        textLabel.textColor = Theme.text
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.cell?.usesSingleLineMode = true
        addSubview(textLabel)

        timeLabel.stringValue = Self.timeText(item.at)
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        timeLabel.textColor = Theme.secondary
        timeLabel.alignment = .right
        addSubview(timeLabel)

        toolTip = ClipboardHistory.preview(item.text, limit: 500)
        refreshBackground()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let timeW: CGFloat = 52
        textLabel.frame = NSRect(x: 10, y: (bounds.height - 16) / 2,
                                 width: bounds.width - 10 - timeW - 8, height: 16)
        timeLabel.frame = NSRect(x: bounds.width - timeW - 10, y: (bounds.height - 14) / 2,
                                 width: timeW, height: 14)
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
        if inside { onPick?() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshBackground()
    }

    private func refreshBackground() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var color: NSColor = .clear

        if isSelected {
            color = Theme.accent.withAlphaComponent(isDark ? 0.36 : 0.16)
        } else if pressed {
            color = isDark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.10)
        } else if hovered {
            color = isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)
        }

        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = color.cgColor
        }
        layer?.backgroundColor = cg
    }

    private static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "HH:mm"
        } else {
            formatter.dateFormat = "M/d HH:mm"
        }
        return formatter.string(from: date)
    }
}
