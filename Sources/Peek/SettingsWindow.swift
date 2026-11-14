import AppKit
import Carbon.HIToolbox
import ServiceManagement

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - 侧栏行

/// 设置窗口左侧的分类行。自绘圆角背景，选中用强调色淡底。
private final class SidebarRow: NSView {

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }

    var isSelected = false { didSet { applyStyle() } }
    var onClick: (() -> Void)?

    init(title: String, symbol: String) {
        super.init(frame: .zero)
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)

        label.stringValue = title
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 10, y: (bounds.height - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 32, y: (bounds.height - 16) / 2, width: bounds.width - 40, height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || hovered else { return }
        let fill = isSelected
            ? Theme.accent.withAlphaComponent(0.14)
            : NSColor.labelColor.withAlphaComponent(0.06)
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func applyStyle() {
        label.textColor = isSelected ? Theme.text : Theme.secondary
        label.font = .systemFont(ofSize: 12.5, weight: isSelected ? .medium : .regular)
        icon.contentTintColor = isSelected ? Theme.accent : Theme.secondary
        needsDisplay = true
    }
}

// MARK: - 快捷键录制控件

/// 点一下进入录制，按新组合键提交；⌫ 清除，Esc 取消。
/// 录制期间由外部把全局热键全部摘掉，否则按下的组合会被系统抢先当成全局热键。
final class HotKeyRecorderView: NSView {

    var combo: HotKeyCombo? { didSet { needsDisplay = true } }
    var onCommit: ((HotKeyCombo?) -> Void)?
    /// true = 进入录制，false = 退出录制
    var onRecordingChanged: ((Bool) -> Void)?

    private(set) var isRecording = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 6, yRadius: 6)
        if isRecording {
            Theme.accent.withAlphaComponent(0.12).setFill()
        } else {
            Theme.resultBG.setFill()
        }
        path.fill()

        if isRecording {
            Theme.accent.setStroke()
            path.lineWidth = 1.5
        } else {
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
        }
        path.stroke()

        let text = isRecording ? "按下组合键…" : (combo?.display ?? "未设置")
        let color = isRecording ? Theme.accent : (combo == nil ? Theme.secondary : Theme.text)
        let font = NSFont.systemFont(ofSize: isRecording ? 11 : 12.5,
                                     weight: isRecording ? .regular : .medium)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style,
        ])
        let height = attributed.size().height
        attributed.draw(in: NSRect(x: 4, y: (bounds.height - height) / 2,
                                   width: bounds.width - 8, height: height))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func becomeFirstResponder() -> Bool {
        isRecording = true
        needsDisplay = true
        onRecordingChanged?(true)
        return true
    }

    override func resignFirstResponder() -> Bool {
        if isRecording {
            isRecording = false
            needsDisplay = true
            onRecordingChanged?(false)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }

        let keyCode = UInt32(event.keyCode)

        // Esc：放弃这次录制，保持原来的键位
        if keyCode == UInt32(kVK_Escape) {
            finish(with: nil, commit: false)
            return
        }
        // ⌫ / ⌦：清除绑定
        if keyCode == UInt32(kVK_Delete) || keyCode == UInt32(kVK_ForwardDelete) {
            finish(with: nil, commit: true)
            return
        }

        let combo = HotKeyCombo(keyCode: keyCode,
                                modifiers: HotKeyCombo.carbonModifiers(from: event.modifierFlags))
        guard combo.isUsable else {
            // 只有 ⇧ 或什么都没有 = 正常打字，不接受
            NSSound.beep()
            return
        }
        finish(with: combo, commit: true)
    }

    private func finish(with newCombo: HotKeyCombo?, commit: Bool) {
        isRecording = false
        needsDisplay = true
        window?.makeFirstResponder(nil)
        if commit {
            onCommit?(newCombo)
        }
    }
}

// MARK: - 设置窗口

final class SettingsWindow: NSObject, NSWindowDelegate {

    static let shared = SettingsWindow()

    private enum Page: Int, CaseIterable {
        case engine, hotkeys, general, about

        var title: String {
            switch self {
            case .engine:  return "翻译引擎"
            case .hotkeys: return "快捷键"
            case .general: return "通用"
            case .about:   return "关于"
            }
        }

        var symbol: String {
            switch self {
            case .engine:  return "arrow.left.arrow.right"
            case .hotkeys: return "command"
            case .general: return "gearshape"
            case .about:   return "info.circle"
            }
        }
    }

    private let windowW: CGFloat = 620
    private let windowH: CGFloat = 560
    private let sidebarW: CGFloat = 156
    private let footerH: CGFloat = 52

    private var window: NSPanel?
    private var sidebarRows: [SidebarRow] = []
    private var pageViews: [NSView] = []
    private var currentPage: Page = .engine
    private var contentHost = FlippedView()

    // ── 引擎页 ─────────────────────────────
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engineHint = NSTextField(wrappingLabelWithString: "")
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let browseButton = NSButton(title: "浏览可用模型…", target: nil, action: nil)
    private let promptField = NSTextField()
    private let signupLink = NSTextField(labelWithString: "还没有 Key？免费注册 →")
    private let endpointHint = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "OpenAI 兼容引擎")
    private let openAIBodyHint = NSTextField(wrappingLabelWithString: "填 OpenAI / OpenRouter / vLLM / Ollama 的兼容地址。选中「离线翻译」时这一整块不生效，可以留空。")
    private let packStatus = NSTextField(wrappingLabelWithString: "")
    private let downloadPacksButton = NSButton(title: "下载语言包…", target: nil, action: nil)

    // ── 快捷键页 ───────────────────────────
    private var recorders: [HotKeyAction: HotKeyRecorderView] = [:]

    // ── 引擎页：OpenAI 配置整体成块，非离线引擎时上移，避免语言包隐藏后留个洞
    private var openAIBlock: FlippedView?
    private var openAIBlockYWithPacks: CGFloat = 0
    private var openAIBlockYWithoutPacks: CGFloat = 0

    // ── 通用页 ─────────────────────────────
    private let launchAtLoginCheck = NSButton(checkboxWithTitle: "开机自动启动", target: nil, action: nil)
    private let prewarmCheck = NSButton(checkboxWithTitle: "启动时预热 OCR", target: nil, action: nil)
    private let autoCopyCheck = NSButton(checkboxWithTitle: "翻译完成后自动复制译文", target: nil, action: nil)

    // ── 关于页 ─────────────────────────────
    private let permissionLabel = NSTextField(wrappingLabelWithString: "")

    private override init() { super.init() }

    private var engineOptions: [TranslateEngine] { EngineRegistry.makeAll() }

    func show() {
        if window == nil { build() }
        loadValues()
        select(currentPage)
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    /// 自检入口：走和「取消」完全一样的路径（恢复热键 → 释放窗口）
    func debugClose() {
        cancel()
    }

    private func close() {
        window?.orderOut(nil)
        releaseWindow()
    }

    /// 关窗即释放。
    /// 原来只 orderOut，window 和 4 个页面（含 7 行热键录制控件）就一直挂着到退出。
    /// 现在下次打开多花几十毫秒重建，换常驻内存干净 —— 设置窗不是高频入口。
    private func releaseWindow() {
        window?.contentView = nil
        window = nil
        // 页面视图挂在 contentHost 上：只清 pageViews 数组，视图本身还活着。
        // 得把它们从父视图摘掉，再把容器换新，上一轮的页面才真正释放。
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        contentHost = FlippedView()
        sidebarRows.removeAll()
        pageViews.removeAll()
    }

    func windowWillClose(_ notification: Notification) {
        // 关窗时若还在录制，热键处于摘下状态，必须补回来
        resumeHotKeys()
        releaseWindow()
    }

    /// 供离屏渲染使用
    func debugContentView() -> NSView? {
        if window == nil { build() }
        loadValues()
        select(currentPage)
        return window?.contentView
    }

    // MARK: - 构建

    private func build() {
        let contentH = windowH - footerH

        let panel = EditingWindow(contentRect: NSRect(x: 0, y: 0, width: windowW, height: windowH),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered,
                                  defer: false)
        panel.title = "Peek 设置"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: windowW, height: windowH))
        root.autoresizingMask = [.width, .height]
        panel.contentView = root
        window = panel

        // ── 侧栏 ───────────────────────────
        let sidebar = FlippedView(frame: NSRect(x: 0, y: 0, width: sidebarW, height: contentH))
        root.addSubview(sidebar)

        var rowY: CGFloat = 14
        for page in Page.allCases {
            let row = SidebarRow(title: page.title, symbol: page.symbol)
            row.frame = NSRect(x: 8, y: rowY, width: sidebarW - 16, height: 32)
            row.onClick = { [weak self] in self?.select(page) }
            sidebar.addSubview(row)
            sidebarRows.append(row)
            rowY += 34
        }

        let divider = NSBox(frame: NSRect(x: sidebarW, y: 0, width: 1, height: contentH))
        divider.boxType = .separator
        root.addSubview(divider)

        // ── 内容区 ─────────────────────────
        contentHost.frame = NSRect(x: sidebarW + 1, y: 0,
                                   width: windowW - sidebarW - 1, height: contentH)
        root.addSubview(contentHost)

        pageViews = [
            buildEnginePage(),
            buildHotKeyPage(),
            buildGeneralPage(),
            buildAboutPage(),
        ]
        for view in pageViews {
            view.frame = contentHost.bounds
            view.autoresizingMask = [.width, .height]
            view.isHidden = true
            contentHost.addSubview(view)
        }

        // ── 底部按钮条 ─────────────────────
        let footerLine = NSBox(frame: NSRect(x: 0, y: contentH, width: windowW, height: 1))
        footerLine.boxType = .separator
        root.addSubview(footerLine)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.frame = NSRect(x: windowW - 24 - 68 - 8 - 68,
                              y: contentH + (footerH - 26) / 2, width: 68, height: 26)
        root.addSubview(cancel)

        let save = NSButton(title: "保存", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        save.frame = NSRect(x: windowW - 24 - 68, y: contentH + (footerH - 26) / 2,
                            width: 68, height: 26)
        root.addSubview(save)
    }

    // MARK: - 引擎页

    private func buildEnginePage() -> NSView {
        let page = FlippedView()
        let left: CGFloat = 24
        let width: CGFloat = 416
        var y: CGFloat = 20

        page.addSubview(sectionLabel("翻译引擎", x: left, y: y))
        y += 22

        enginePopup.frame = NSRect(x: left, y: y, width: width, height: 26)
        enginePopup.controlSize = .regular
        enginePopup.font = .systemFont(ofSize: 12)
        enginePopup.target = self
        enginePopup.action = #selector(engineChanged)
        for engine in engineOptions {
            let title: String
            switch engine.id {
            case "system": title = "离线翻译（macOS 自带模型，无需 Key）"
            case "mock":   title = "Mock（离线占位，不联网）"
            default:       title = "OpenAI 兼容接口（OpenRouter / vLLM / Ollama）"
            }
            enginePopup.addItem(withTitle: title)
            enginePopup.lastItem?.representedObject = engine.id
        }
        page.addSubview(enginePopup)
        y += 34

        engineHint.font = .systemFont(ofSize: 11)
        engineHint.textColor = .secondaryLabelColor
        engineHint.frame = NSRect(x: left, y: y, width: width, height: 40)
        page.addSubview(engineHint)
        y += 46

        packStatus.font = .systemFont(ofSize: 11)
        packStatus.textColor = .secondaryLabelColor
        packStatus.frame = NSRect(x: left, y: y, width: 300, height: 34)
        page.addSubview(packStatus)

        downloadPacksButton.bezelStyle = .rounded
        downloadPacksButton.controlSize = .small
        downloadPacksButton.font = .systemFont(ofSize: 11)
        downloadPacksButton.target = self
        downloadPacksButton.action = #selector(downloadPacks)
        downloadPacksButton.frame = NSRect(x: left + 306, y: y + 4, width: 106, height: 22)
        page.addSubview(downloadPacksButton)
        y += 46

        // OpenAI 配置整体放进一个容器：切到「离线翻译」时把容器上移 46pt，
        // 填掉语言包那块隐藏后留下的空白
        let block = FlippedView(frame: NSRect(x: 0, y: y, width: 463, height: 320))
        page.addSubview(block)
        openAIBlock = block
        openAIBlockYWithPacks = y
        openAIBlockYWithoutPacks = y - 46

        var by: CGFloat = 0
        block.addSubview(separator(y: by, x: left, width: width))
        by += 14

        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.frame = NSRect(x: left, y: by, width: 240, height: 18)
        block.addSubview(heading)

        endpointHint.font = .systemFont(ofSize: 11)
        endpointHint.textColor = .secondaryLabelColor
        endpointHint.alignment = .right
        endpointHint.frame = NSRect(x: left + 260, y: by + 1, width: 156, height: 16)
        block.addSubview(endpointHint)
        by += 22

        openAIBodyHint.font = .systemFont(ofSize: 11)
        openAIBodyHint.textColor = .secondaryLabelColor
        openAIBodyHint.frame = NSRect(x: left, y: by, width: width, height: 30)
        block.addSubview(openAIBodyHint)
        by += 38

        block.addSubview(fieldLabel("Base URL", x: left, y: by))
        by += 18
        configure(baseURLField, placeholder: "https://openrouter.ai/api/v1",
                  frame: NSRect(x: left, y: by, width: width, height: 24))
        block.addSubview(baseURLField)
        by += 36

        block.addSubview(fieldLabel("API Key", x: left, y: by))

        signupLink.font = .systemFont(ofSize: 10.5)
        signupLink.textColor = .controlAccentColor
        signupLink.alignment = .right
        signupLink.frame = NSRect(x: left + 260, y: by - 1, width: 156, height: 16)
        signupLink.toolTip = "打开注册向导：选服务商 → 创建 Key → 自动校验"
        signupLink.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(openSignup)))
        block.addSubview(signupLink)
        by += 18

        apiKeyField.placeholderString = "sk-…（本地服务可留空）"
        apiKeyField.font = .systemFont(ofSize: 12)
        apiKeyField.frame = NSRect(x: left, y: by, width: width, height: 24)
        block.addSubview(apiKeyField)
        by += 36

        block.addSubview(fieldLabel("模型", x: left, y: by))
        by += 18
        configure(modelField, placeholder: "gpt-4o-mini / qwen2.5-7b-instruct",
                  frame: NSRect(x: left, y: by, width: 280, height: 24))
        block.addSubview(modelField)

        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .small
        browseButton.font = .systemFont(ofSize: 11)
        browseButton.target = self
        browseButton.action = #selector(openModelBrowser)
        browseButton.frame = NSRect(x: left + 288, y: by + 2, width: 128, height: 20)
        block.addSubview(browseButton)
        by += 36

        block.addSubview(fieldLabel("系统提示词（留空使用内置翻译 prompt）", x: left, y: by))
        by += 18
        configure(promptField, placeholder: "你是专业翻译引擎，只输出译文…",
                  frame: NSRect(x: left, y: by, width: width, height: 50))
        promptField.cell?.wraps = true
        promptField.cell?.isScrollable = false
        block.addSubview(promptField)

        return page
    }

    // MARK: - 快捷键页

    private func buildHotKeyPage() -> NSView {
        let page = FlippedView()
        let left: CGFloat = 24
        var y: CGFloat = 18

        let hint = NSTextField(wrappingLabelWithString:
            "点右侧键位后按下新的组合键即可修改，改完点右下角「保存」生效。⌫ 清除绑定，Esc 取消。组合键至少要带 ⌘、⌥ 或 ⌃ 其中一个。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: left, y: y, width: 416, height: 30)
        page.addSubview(hint)
        y += 40

        for action in HotKeyAction.allCases {
            let title = NSTextField(labelWithString: action.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.textColor = Theme.text
            title.frame = NSRect(x: left, y: y + 2, width: 220, height: 17)
            page.addSubview(title)

            let detail = NSTextField(labelWithString: action.detail)
            detail.font = .systemFont(ofSize: 11)
            detail.textColor = Theme.secondary
            detail.lineBreakMode = .byTruncatingTail
            detail.frame = NSRect(x: left, y: y + 21, width: 220, height: 15)
            page.addSubview(detail)

            let recorder = HotKeyRecorderView(frame: NSRect(x: left + 228, y: y + 6,
                                                            width: 112, height: 26))
            recorder.combo = HotKeyStore.combo(for: action)
            recorder.onRecordingChanged = { [weak self] recording in
                if recording { self?.pauseHotKeys() } else { self?.resumeHotKeys() }
            }
            recorder.onCommit = { [weak self] combo in
                self?.commit(combo, for: action)
            }
            page.addSubview(recorder)
            recorders[action] = recorder

            let reset = NSButton(title: "恢复", target: self, action: #selector(resetOne(_:)))
            reset.bezelStyle = .rounded
            reset.controlSize = .small
            reset.font = .systemFont(ofSize: 10.5)
            reset.tag = HotKeyAction.allCases.firstIndex(of: action) ?? 0
            reset.frame = NSRect(x: left + 348, y: y + 7, width: 56, height: 22)
            reset.toolTip = "恢复 \(action.title) 的默认快捷键"
            page.addSubview(reset)

            y += 54
        }

        let resetAll = NSButton(title: "全部恢复默认", target: self, action: #selector(resetAllHotKeys))
        resetAll.bezelStyle = .rounded
        resetAll.controlSize = .small
        resetAll.font = .systemFont(ofSize: 11)
        resetAll.frame = NSRect(x: left, y: y + 4, width: 108, height: 24)
        page.addSubview(resetAll)

        return page
    }

    // MARK: - 通用页

    private func buildGeneralPage() -> NSView {
        let page = FlippedView()
        let left: CGFloat = 24
        var y: CGFloat = 20

        page.addSubview(sectionLabel("启动", x: left, y: y))
        y += 22

        launchAtLoginCheck.font = .systemFont(ofSize: 12)
        launchAtLoginCheck.frame = NSRect(x: left - 2, y: y, width: 300, height: 20)
        page.addSubview(launchAtLoginCheck)
        y += 30

        prewarmCheck.font = .systemFont(ofSize: 12)
        prewarmCheck.frame = NSRect(x: left - 2, y: y, width: 300, height: 20)
        page.addSubview(prewarmCheck)
        y += 24

        let prewarmHint = NSTextField(wrappingLabelWithString:
            "Vision 的识别模型常驻内存，物理占用会多 20–65 MB，换来首次截图不用等模型加载。关闭后需要重启才真正释放。")
        prewarmHint.font = .systemFont(ofSize: 11)
        prewarmHint.textColor = .secondaryLabelColor
        prewarmHint.frame = NSRect(x: left + 16, y: y, width: 400, height: 32)
        page.addSubview(prewarmHint)
        y += 46

        page.addSubview(separator(y: y, x: left, width: 416))
        y += 16

        page.addSubview(sectionLabel("翻译", x: left, y: y))
        y += 22

        autoCopyCheck.font = .systemFont(ofSize: 12)
        autoCopyCheck.frame = NSRect(x: left - 2, y: y, width: 320, height: 20)
        page.addSubview(autoCopyCheck)
        y += 24

        let copyHint = NSTextField(wrappingLabelWithString:
            "每次翻译完成后把译文写入剪贴板，方便直接粘贴。")
        copyHint.font = .systemFont(ofSize: 11)
        copyHint.textColor = .secondaryLabelColor
        copyHint.frame = NSRect(x: left + 16, y: y, width: 400, height: 20)
        page.addSubview(copyHint)

        return page
    }

    // MARK: - 关于页

    private func buildAboutPage() -> NSView {
        let page = FlippedView()
        let left: CGFloat = 24

        let iconView = NSImageView(frame: NSRect(x: left, y: 20, width: 64, height: 64))
        iconView.image = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        page.addSubview(iconView)

        let name = NSTextField(labelWithString: "Peek")
        name.font = .systemFont(ofSize: 18, weight: .semibold)
        name.frame = NSRect(x: left + 80, y: 26, width: 200, height: 22)
        page.addSubview(name)

        let info = Bundle.main.infoDictionary
        let shortVersion = info?["CFBundleShortVersionString"] as? String ?? "?"
        let commit = info?["PeekBuildCommit"] as? String ?? ""
        let buildTime = info?["PeekBuildTime"] as? String ?? ""
        let version = NSTextField(labelWithString:
            commit.isEmpty ? "版本 \(shortVersion)" : "版本 \(shortVersion) · \(commit)")
        version.font = .systemFont(ofSize: 11)
        version.textColor = .secondaryLabelColor
        version.toolTip = buildTime.isEmpty ? nil : "构建于 \(buildTime)"
        version.frame = NSRect(x: left + 80, y: 50, width: 300, height: 16)
        page.addSubview(version)

        let desc = NSTextField(wrappingLabelWithString:
            "划一下就浮出来的翻译浮窗。本地离线翻译走 macOS 自带模型，译文不出本机；也可以接任意 OpenAI 兼容接口。")
        desc.font = .systemFont(ofSize: 11.5)
        desc.textColor = .secondaryLabelColor
        desc.frame = NSRect(x: left, y: 100, width: 400, height: 44)
        page.addSubview(desc)

        let github = NSButton(title: "GitHub 项目主页", target: self, action: #selector(openGitHub))
        github.bezelStyle = .rounded
        github.controlSize = .small
        github.font = .systemFont(ofSize: 11)
        github.frame = NSRect(x: left, y: 152, width: 124, height: 24)
        page.addSubview(github)

        page.addSubview(separator(y: 196, x: left, width: 416))

        page.addSubview(sectionLabel("系统权限", x: left, y: 212))

        permissionLabel.font = .systemFont(ofSize: 11.5)
        permissionLabel.textColor = .secondaryLabelColor
        permissionLabel.frame = NSRect(x: left, y: 234, width: 400, height: 40)
        page.addSubview(permissionLabel)

        let accessibilityButton = NSButton(title: "辅助功能设置…", target: self,
                                           action: #selector(openAccessibilitySettings))
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.controlSize = .small
        accessibilityButton.font = .systemFont(ofSize: 11)
        accessibilityButton.frame = NSRect(x: left, y: 282, width: 118, height: 24)
        page.addSubview(accessibilityButton)

        let screenButton = NSButton(title: "屏幕录制设置…", target: self,
                                    action: #selector(openScreenSettings))
        screenButton.bezelStyle = .rounded
        screenButton.controlSize = .small
        screenButton.font = .systemFont(ofSize: 11)
        screenButton.frame = NSRect(x: left + 126, y: 282, width: 118, height: 24)
        page.addSubview(screenButton)

        return page
    }

    // MARK: - 小工具

    private func sectionLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 416, height: 16)
        return label
    }

    private func fieldLabel(_ text: String, x: CGFloat, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: x, y: y, width: 416, height: 16)
        return label
    }

    private func separator(y: CGFloat, x: CGFloat, width: CGFloat) -> NSBox {
        let box = NSBox(frame: NSRect(x: x, y: y, width: width, height: 1))
        box.boxType = .separator
        return box
    }

    private func configure(_ field: NSTextField, placeholder: String, frame: NSRect) {
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.frame = frame
    }

    // MARK: - 分页

    private func select(_ page: Page) {
        currentPage = page
        for (index, row) in sidebarRows.enumerated() {
            row.isSelected = (index == page.rawValue)
        }
        for (index, view) in pageViews.enumerated() {
            view.isHidden = (index != page.rawValue)
        }
        if page == .about { refreshPermissionLabel() }
        if page == .general { refreshGeneralChecks() }
    }

    private func refreshGeneralChecks() {
        launchAtLoginCheck.state = SMAppService.mainApp.status == .enabled ? .on : .off
        prewarmCheck.state = PrefKey.prewarmOCRDefault ? .on : .off
    }

    private func refreshPermissionLabel() {
        let accessibility = SelectionGrabber.hasPermission ? "已开启" : "未开启"
        let screen = ScreenCapture.hasPermission ? "已开启" : "未开启"
        permissionLabel.stringValue =
            "辅助功能（划词取词）：\(accessibility)\n屏幕录制（截图）：\(screen)"
    }

    // MARK: - 引擎切换

    @objc private func engineChanged() {
        refreshEngineState()
    }

    private var selectedEngineId: String {
        (enginePopup.selectedItem?.representedObject as? String) ?? "openai"
    }

    /// 选「离线翻译」时，把 OpenAI 那一整块灰掉 —— 否则用户会以为必须填 Key 才能存
    private func refreshEngineState() {
        let id = selectedEngineId
        let usesOpenAI = (id == "openai")

        for control in [baseURLField, apiKeyField, modelField, promptField] as [NSControl] {
            control.isEnabled = usesOpenAI
            control.alphaValue = usesOpenAI ? 1 : 0.4
        }
        browseButton.isEnabled = usesOpenAI
        browseButton.alphaValue = usesOpenAI ? 1 : 0.4
        signupLink.isHidden = !usesOpenAI
        for view in [heading, endpointHint, openAIBodyHint] as [NSView] {
            view.alphaValue = usesOpenAI ? 1 : 0.4
        }

        switch id {
        case "system":
            engineHint.stringValue = "用 macOS 自带的翻译模型：完全离线、译文不出本机、不需要 Key。\n第一次翻译某个语言对时，系统会弹窗让你下载语言包（几百 MB），下载完就一直离线可用。"
        case "mock":
            engineHint.stringValue = "占位引擎，不联网，只用来验证界面排版。"
        default:
            engineHint.stringValue = "调用 OpenAI Chat Completions 兼容接口。需要 Base URL + 模型名，大多数服务还要 Key。"
        }

        packStatus.isHidden = (id != "system")
        downloadPacksButton.isHidden = (id != "system")

        // 语言包那 46pt 只在离线引擎时才有内容。非离线时整块上移，
        // 否则下拉框和下面的分隔线之间会空出一大段，看起来像布局坏了。
        openAIBlock?.frame.origin.y = usesOpenAI ? openAIBlockYWithoutPacks : openAIBlockYWithPacks

        if id == "system" { refreshPackStatus() }
    }

    // MARK: - 语言包

    private func refreshPackStatus() {
        guard #available(macOS 15.0, *) else {
            packStatus.stringValue = "系统翻译需要 macOS 15 或更新版本。"
            return
        }
        packStatus.stringValue = "正在检查语言包…"
        Task { @MainActor in
            let bridge = SystemTranslationBridge.shared
            let en2zh = await bridge.packState(from: Locale.Language(identifier: "en"), to: "zh")
            let zh2en = await bridge.packState(from: Locale.Language(identifier: "zh-Hans"), to: "en")
            packStatus.stringValue = "英语 → 中文：\(en2zh)\n中文 → 英语：\(zh2en)"
        }
    }

    @objc private func downloadPacks() {
        guard #available(macOS 15.0, *) else { return }
        downloadPacksButton.isEnabled = false
        packStatus.stringValue = "正在请求语言包，系统可能会弹下载确认…"
        Task { @MainActor in
            let bridge = SystemTranslationBridge.shared
            var failure: String?
            for (from, to) in [("zh", "en"), ("en", "zh")] {
                do {
                    try await bridge.prepare(from: from, to: to)
                } catch {
                    failure = error.localizedDescription
                }
            }
            downloadPacksButton.isEnabled = true
            if let failure {
                packStatus.stringValue = "下载失败：\(failure)"
            } else {
                refreshPackStatus()
            }
        }
    }

    // MARK: - 快捷键：录制期间摘掉全局热键

    private func pauseHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        Log.info("热键: 录制中，已全部暂停")
    }

    private func resumeHotKeys() {
        (NSApp.delegate as? AppDelegate)?.reloadHotKeys()
    }

    /// 提交前先查本次会话里还没保存的改动，避免两个动作抢同一个组合
    private func pendingConflict(_ combo: HotKeyCombo, excluding action: HotKeyAction) -> HotKeyAction? {
        for other in HotKeyAction.allCases where other != action {
            if recorders[other]?.combo == combo { return other }
        }
        return nil
    }

    private func commit(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        guard let combo else {
            recorders[action]?.combo = nil
            Log.info("快捷键: \(action.title) 已清除")
            return
        }

        if let conflict = pendingConflict(combo, excluding: action) {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "\(combo.display) 已经被「\(conflict.title)」占用"
            alert.informativeText = "先给「\(conflict.title)」换一个组合键，或者换一个没被用过的组合。"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            recorders[action]?.combo = HotKeyStore.combo(for: action)
            return
        }

        recorders[action]?.combo = combo
        Log.info("快捷键: \(action.title) → \(combo.display)")
    }

    @objc private func resetOne(_ sender: NSButton) {
        let actions = HotKeyAction.allCases
        guard sender.tag >= 0, sender.tag < actions.count else { return }
        let action = actions[sender.tag]

        // 默认键位也可能被别人占了（用户把别人的键改成了默认值），先查一下
        if let conflict = pendingConflict(action.defaultCombo, excluding: action) {
            NSSound.beep()
            let alert = NSAlert()
            alert.messageText = "默认组合 \(action.defaultCombo.display) 已被「\(conflict.title)」占用"
            alert.informativeText = "先把「\(conflict.title)」改成别的键，再恢复默认。"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }
        recorders[action]?.combo = action.defaultCombo
    }

    @objc private func resetAllHotKeys() {
        for action in HotKeyAction.allCases {
            recorders[action]?.combo = action.defaultCombo
        }
        Log.info("快捷键: 全部恢复默认（待保存）")
    }

    // MARK: - 加载与保存

    private func loadValues() {
        let defaults = UserDefaults.standard

        let saved = defaults.string(forKey: PrefKey.engineId) ?? "openai"
        let ids = engineOptions.map { $0.id }
        let index = ids.firstIndex(of: saved) ?? ids.firstIndex(of: "openai") ?? 0
        enginePopup.selectItem(at: index)
        refreshEngineState()

        baseURLField.stringValue = defaults.string(forKey: PrefKey.baseURL) ?? ""
        apiKeyField.stringValue = defaults.string(forKey: PrefKey.apiKey) ?? ""
        modelField.stringValue = defaults.string(forKey: PrefKey.model) ?? ""
        promptField.stringValue = defaults.string(forKey: PrefKey.systemPrompt) ?? ""
        autoCopyCheck.state = defaults.bool(forKey: PrefKey.autoCopy) ? .on : .off
        refreshEndpointHint()

        for action in HotKeyAction.allCases {
            recorders[action]?.combo = HotKeyStore.combo(for: action)
        }

        refreshGeneralChecks()
        refreshPermissionLabel()
    }

    private func refreshEndpointHint() {
        let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            endpointHint.stringValue = "未配置"
            return
        }
        if ModelCatalog.isOpenRouter(base) {
            endpointHint.stringValue = "OpenRouter"
        } else if let host = URL(string: base)?.host {
            endpointHint.stringValue = host
        } else {
            endpointHint.stringValue = "地址格式可疑"
        }
    }

    private func applyValues() {
        let defaults = UserDefaults.standard
        defaults.set(baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: PrefKey.baseURL)
        defaults.set(apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: PrefKey.apiKey)
        defaults.set(modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: PrefKey.model)
        defaults.set(promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: PrefKey.systemPrompt)
        defaults.set(selectedEngineId, forKey: PrefKey.engineId)

        defaults.set(autoCopyCheck.state == .on, forKey: PrefKey.autoCopy)

        // OCR 预热开关：关掉后不再提前编译，第一次识别要当场等模型编译
        let wantsPrewarm = prewarmCheck.state == .on
        let hadPrewarm = PrefKey.prewarmOCRDefault
        if wantsPrewarm != hadPrewarm {
            defaults.set(wantsPrewarm, forKey: PrefKey.prewarmOCR)
            if wantsPrewarm {
                OCR.prewarm()
            } else {
                Log.info("OCR 预热: 已关闭（首次识别会当场编译，要等十几秒）")
            }
        }

        applyLaunchAtLogin()

        for action in HotKeyAction.allCases {
            let combo = recorders[action]?.combo
            if combo == action.defaultCombo {
                HotKeyStore.reset(action)
            } else {
                HotKeyStore.set(combo, for: action)
            }
        }

        refreshEndpointHint()
        PanelController.shared.reloadEngines()
    }

    private func applyLaunchAtLogin() {
        let service = SMAppService.mainApp
        let wantEnabled = launchAtLoginCheck.state == .on
        let isEnabled = service.status == .enabled
        guard wantEnabled != isEnabled else { return }
        do {
            if wantEnabled {
                try service.register()
                Log.info("开机自启: 已开启")
            } else {
                try service.unregister()
                Log.info("开机自启: 已关闭")
            }
        } catch {
            Log.info("开机自启: 操作失败 \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "无法修改开机自启"
            alert.informativeText = "\(error.localizedDescription)\n\n请把 Peek 拖到「应用程序」文件夹后再试。"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func save() {
        applyValues()
        resumeHotKeys()
        close()
    }

    @objc private func cancel() {
        // 不落盘，但录制期间热键被摘掉了，必须按已保存的配置恢复
        resumeHotKeys()
        close()
    }

    // MARK: - 外部入口

    @objc private func openModelBrowser() {
        let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            openSignup()
            return
        }
        ModelBrowserWindow.shared.show(baseURL: base,
                                       apiKey: apiKeyField.stringValue,
                                       currentModel: modelField.stringValue) { [weak self] model in
            guard let self else { return }
            self.modelField.stringValue = model.id
            self.refreshEndpointHint()
        }
    }

    @objc private func openSignup() {
        SignupWizard.shared.show(baseURL: baseURLField.stringValue,
                                 apiKey: apiKeyField.stringValue) { [weak self] base, key, _ in
            guard let self else { return }
            if !base.isEmpty { self.baseURLField.stringValue = base }
            self.apiKeyField.stringValue = key
            self.refreshEndpointHint()
            self.applyValues()
            self.openModelBrowser()
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/yikox/peek") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openScreenSettings() {
        ScreenCapture.openSettings()
    }

    // MARK: - 自检辅助

    /// 让 Key 输入框拿到焦点，用于验证粘贴链路
    @discardableResult
    func debugFocusKeyField() -> Bool {
        if window == nil { build() }
        select(.engine)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeKey()
        return window?.makeFirstResponder(apiKeyField) ?? false
    }

    var debugApiKey: String {
        get { apiKeyField.stringValue }
        set { apiKeyField.stringValue = newValue }
    }

    var debugWindow: NSWindow? { window }

    /// 离屏渲染指定分页（--snapshot-settings --page hotkeys 用）
    func debugSelect(page index: Int) {
        if window == nil { build() }
        loadValues()
        select(Page(rawValue: index) ?? .engine)
    }
}
