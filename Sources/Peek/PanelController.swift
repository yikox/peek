import AppKit

/// 浮窗的唯一持有者。
/// 单例在 App 启动时就构建完毕（预热），之后每次唤起只做：
/// 两次字符串赋值 + orderFront —— 零窗口创建、零视图构建、零约束求解。
final class PanelController: NSObject {

    static let shared = PanelController()

    private enum State {
        case idle
        case loading(String)
        case notice(String)
        case result(TranslateOutput)
        case failure(String)
    }

    // 窗口与容器
    private let panel: FloatingPanel
    private let rootCard: CardView
    private let whiteCard: CardView

    // 顶部条
    private let topBar = NSView()
    private let engineControl = MenuControl(frame: .zero)
    private let pinButton = NSButton()
    private let closeButton = NSButton()

    // 查询区
    private let queryScroll = NSScrollView()
    private let queryTextView = QueryTextView(frame: .zero)

    // 服务行
    private let serviceBar = NSView()
    private let sourceControl = MenuControl(frame: .zero)
    private let targetControl = MenuControl(frame: .zero)
    private let swapButton = NSButton()

    // 结果区
    private let resultView = ResultView(frame: .zero)

    // 复制：各自贴着原文区、译文区的右上角。
    // 原来只有顶部条一个复制图标，语义上分不清复制的是哪一半。
    private let queryCopyBadge = CopyBadge(toolTip: "复制原文")
    private let resultCopyBadge = CopyBadge(toolTip: "复制译文")

    /// 复制按钮占掉的右侧空间。文字区按这个数收窄，按钮才不会压在字上
    private static let copyGutter: CGFloat = 24

    // 状态
    private var engines: [TranslateEngine] = EngineRegistry.makeAll()
    private var currentEngine: TranslateEngine
    private var state: State = .idle
    private var currentResultH = Metrics.resultMinH
    private var seed = 0
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var isShowing = false
    /// 钉住：点面板外面不再自动收起，只有 Esc / 关闭按钮 / 再按一次热键才收
    private var isPinned = false
    private var lastShownAt = Date.distantPast
    private var permissionWatcher: Timer?
    private var permissionTicks = 0

    private override init() {
        panel = FloatingPanel(size: NSSize(width: Metrics.windowW,
                                           height: Metrics.windowH(resultH: Metrics.resultMinH)))
        rootCard = CardView(fill: Theme.panel, bordered: true)
        whiteCard = CardView(fill: Theme.queryBG)
        currentEngine = EngineRegistry.current(from: EngineRegistry.makeAll())
        super.init()
        currentEngine = EngineRegistry.current(from: engines)
        build()
    }

    // MARK: - 构建

    private func build() {
        panel.contentView = rootCard
        rootCard.autoresizingMask = [.width, .height]

        buildTopBar()
        buildQueryArea()
        buildServiceBar()
        rootCard.addSubview(resultView)
        resultView.onOpenSettings = { [weak self] in
            self?.hide()
            SettingsWindow.shared.show()
        }

        resultView.trailingInset = Self.copyGutter
        resultCopyBadge.onCopy = { [weak self] in self?.copyResult() }
        resultCopyBadge.isHidden = true
        resultView.addSubview(resultCopyBadge)

        relayout(resultH: currentResultH, keepTopLeft: false)
        setState(.idle)
    }

    private func buildTopBar() {
        rootCard.addSubview(topBar)

        engineControl.onSelect = { [weak self] item in
            guard let self,
                  let engine = self.engines.first(where: { $0.id == item.code }) else { return }
            self.currentEngine = engine
            UserDefaults.standard.set(engine.id, forKey: PrefKey.engineId)
            if !self.queryTextView.string.isEmpty {
                self.translateCurrent()
            }
        }
        topBar.addSubview(engineControl)
        engineControl.textColor = Theme.secondary
        engineControl.toolTip = "切换翻译引擎（离线翻译 / OpenAI 兼容 / Mock）"
        rebuildEngineMenu()

        configure(icon: pinButton, symbol: "pin", action: #selector(togglePin))
        pinButton.toolTip = "固定面板：点外面不自动收起"
        configure(icon: closeButton, symbol: "xmark", action: #selector(closePanel))

        topBar.addSubview(pinButton)
        topBar.addSubview(closeButton)
    }

    private func configure(icon button: NSButton, symbol: String, action: Selector) {
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        button.contentTintColor = Theme.secondary
        button.target = self
        button.action = action
        button.focusRingType = .none
    }

    private func buildQueryArea() {
        whiteCard.addSubview(queryScroll)

        queryScroll.drawsBackground = false
        queryScroll.hasVerticalScroller = true
        queryScroll.autohidesScrollers = true
        queryScroll.scrollerStyle = .overlay
        queryScroll.borderType = .noBorder

        queryTextView.configure()
        queryTextView.isVerticallyResizable = true
        queryTextView.minSize = .zero
        queryTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        queryTextView.autoresizingMask = [.width]
        queryTextView.onSubmit = { [weak self] in self?.translateCurrent() }
        queryTextView.onCancel = { [weak self] in self?.hide() }

        queryScroll.documentView = queryTextView
        rootCard.addSubview(whiteCard)

        queryCopyBadge.onCopy = { [weak self] in
            guard let self else { return }
            let text = self.queryTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            self.writeToPasteboard(text)
            Log.info("复制: 原文 \(text.count) 字")
        }
        queryCopyBadge.isHidden = true
        // 必须排在 queryScroll 之后，否则会被滚动视图压在下面点不到
        whiteCard.addSubview(queryCopyBadge)

        // 手动打字时原文复制按钮也要跟着出现 / 消失，不能只在 show() 时算一次
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(queryTextChanged),
            name: NSText.didChangeNotification,
            object: queryTextView
        )
    }

    @objc private func queryTextChanged() {
        updateCopyBadges()
    }

    private func buildServiceBar() {
        whiteCard.addSubview(serviceBar)

        sourceControl.setItems(Language.supported.map { MenuControl.Item(title: $0.name, code: $0.code) },
                               selected: "auto")
        sourceControl.onSelect = { [weak self] _ in self?.languageChanged() }
        serviceBar.addSubview(sourceControl)

        // 默认翻成中文：中文用户看英文文档最多。原文本来就是中文时，
        // translate() 里的自动换向会把它改成翻英文。
        let defaultCode = "zh"
        targetControl.alignRight = true
        targetControl.setItems(Language.targets.map { MenuControl.Item(title: $0.name, code: $0.code) },
                               selected: defaultCode)
        targetControl.onSelect = { [weak self] _ in self?.languageChanged() }
        serviceBar.addSubview(targetControl)

        swapButton.isBordered = false
        swapButton.bezelStyle = .regularSquare
        swapButton.imagePosition = .imageOnly
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "互换语言")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        swapButton.contentTintColor = Theme.secondary
        swapButton.target = self
        swapButton.action = #selector(swapLanguages)
        swapButton.focusRingType = .none
        serviceBar.addSubview(swapButton)
    }

    // MARK: - 布局（全部手写 frame，零 Auto Layout）

    private func layoutChildren(size: NSSize) {
        let H = size.height
        let M = Metrics.margin

        let topBarY = H - M - Metrics.topBarH
        topBar.frame = NSRect(x: M, y: topBarY, width: Metrics.contentW, height: Metrics.topBarH)

        engineControl.frame = NSRect(x: 0, y: 0, width: 120, height: Metrics.topBarH)
        let buttonY: CGFloat = 1
        closeButton.frame = NSRect(x: Metrics.contentW - 22, y: buttonY, width: 22, height: 22)
        pinButton.frame = NSRect(x: Metrics.contentW - 22 - 6 - 22, y: buttonY, width: 22, height: 22)

        let cardH = Metrics.whiteCardH
        whiteCard.frame = NSRect(x: M,
                                 y: topBarY - Metrics.gap - cardH,
                                 width: Metrics.contentW,
                                 height: cardH)

        queryScroll.frame = NSRect(x: 0,
                                   y: cardH - Metrics.innerPad - Metrics.queryH,
                                   width: Metrics.contentW,
                                   height: Metrics.queryH)

        // 文字提前让开右上角的复制按钮，否则长行会从按钮底下穿过去
        let qw = max(0, queryScroll.contentSize.width - Self.copyGutter)
        queryTextView.frame = NSRect(x: 0, y: 0, width: qw, height: Metrics.queryH)
        queryTextView.layoutPlaceholder(bounds: NSRect(x: 0, y: 0, width: qw, height: Metrics.queryH))

        queryCopyBadge.frame = NSRect(x: Metrics.contentW - Self.copyGutter,
                                      y: cardH - Metrics.innerPad - 26,
                                      width: 20, height: 20)

        let barW = Metrics.contentW - M * 2
        serviceBar.frame = NSRect(x: M, y: Metrics.innerPad, width: barW, height: Metrics.serviceBarH)
        let half = (barW - 20 - 20) / 2
        sourceControl.frame = NSRect(x: 0, y: 0, width: half, height: Metrics.serviceBarH)
        swapButton.frame = NSRect(x: half + 10, y: 0, width: 20, height: Metrics.serviceBarH)
        targetControl.frame = NSRect(x: half + 30, y: 0, width: half, height: Metrics.serviceBarH)

        resultView.frame = NSRect(x: M, y: M, width: Metrics.contentW, height: currentResultH)
        // 相对 resultView 的坐标：贴右上角，中心对齐首行文字
        resultCopyBadge.frame = NSRect(x: Metrics.contentW - Self.copyGutter,
                                       y: currentResultH - 26,
                                       width: 20, height: 20)
    }

    private func relayout(resultH: CGFloat, keepTopLeft: Bool) {
        let size = NSSize(width: Metrics.windowW, height: Metrics.windowH(resultH: resultH))
        if panel.frame.size != size {
            var frame = panel.frame
            let topLeft = NSPoint(x: frame.minX, y: frame.maxY)
            frame.size = size
            if keepTopLeft && isShowing {
                // 锚点是左下角，必须先记 topLeft 再补回，否则窗口会往上窜
                frame.origin = NSPoint(x: topLeft.x, y: topLeft.y - size.height)
            }
            panel.setFrame(frame, display: false, animate: false)
        }
        currentResultH = resultH
        rootCard.frame = NSRect(origin: .zero, size: size)
        layoutChildren(size: size)
        if isShowing { clampToScreen() }
        panel.displayIfNeeded()
    }

    // MARK: - 显示 / 隐藏

    func showInput() {
        show(query: nil, autoTranslate: false)
    }

    func showWithSelection() {
        guard SelectionGrabber.hasPermission else {
            presentPermissionGuide()
            return
        }
        finishSelection()
    }

    /// 无权限时的引导：面板照常弹出，说明原因，同时开始轮询授权状态。
    /// 一旦用户在系统设置里勾上，立刻自动取词 + 翻译，不用再按一次热键、也不用重启 app。
    private func presentPermissionGuide() {
        show(query: nil, autoTranslate: false)
        setState(.notice("""
        划词翻译需要「辅助功能」权限。

        1. 在刚打开的系统设置里勾选 Peek（列表里没有就点 + 选 /Applications/Peek.app）
        2. 勾完回到要翻译的应用，重新选中文字，再按 ⌥D

        不想给权限也行：先 ⌘C 复制，再按 ⌥V 直接翻译剪贴板（免权限）。
        """))
        SelectionGrabber.requestPermission()
        startPermissionWatch()
        // LSUIElement 应用不激活的话，系统授权框容易压到别的窗口后面
        NSApp.activate(ignoringOtherApps: true)
        openAccessibilitySettings()
    }

    private func startPermissionWatch() {
        stopPermissionWatch()
        permissionTicks = 200   // 0.3s × 200 ≈ 60s
        permissionWatcher = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if SelectionGrabber.hasPermission {
                self.stopPermissionWatch()
                Log.info("辅助功能: 授权状态变为已授予")
                self.finishSelection(afterGrant: true)
                return
            }
            self.permissionTicks -= 1
            if self.permissionTicks <= 0 {
                self.stopPermissionWatch()
                Log.info("辅助功能: 等待授权超时（60s），停止轮询")
            }
        }
    }

    private func stopPermissionWatch() {
        permissionWatcher?.invalidate()
        permissionWatcher = nil
        permissionTicks = 0
    }

    /// 直接把人送到系统设置的辅助功能页，省得在设置里翻三层。
    /// 每次启动只自动开一次，避免反复抢焦点。
    private func openAccessibilitySettings() {
        guard !Self.didOpenAccessibilityPane else { return }
        Self.didOpenAccessibilityPane = true
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
        Log.info("辅助功能: 已打开系统设置的辅助功能面板")
    }

    private static var didOpenAccessibilityPane = false

    /// 真正取词 + 翻译。有权限时才会走到这里。
    private func finishSelection(afterGrant: Bool = false) {
        let grabbed = SelectionGrabber.grab()
        show(query: grabbed, autoTranslate: (grabbed?.isEmpty == false))
        guard grabbed == nil else { return }

        if afterGrant {
            // 刚授权时焦点通常还在系统设置上，取不到词是正常的
            setState(.notice("""
            辅助功能权限已生效 ✓

            回到你要翻译的应用，重新选中文字，再按一次 ⌥D。
            （刚才焦点在系统设置上，所以没取到词。）
            """))
        } else {
            setState(.notice("""
            没有取到选中的文字。

            请先在别的应用里选中一段文本再按 ⌥D。
            密码框、受保护页面、图片里的文字取不到；
            也可以 ⌘C 复制后按 ⌥V 翻译剪贴板。
            """))
        }
    }

    /// ⌥V：不需要任何权限，直接翻译剪贴板内容。
    func showFromClipboard() {
        guard let text = SelectionGrabber.clipboardText() else {
            show(query: nil, autoTranslate: false)
            setState(.notice("剪贴板里没有文字。\n先在任意应用里选中文字按 ⌘C 复制，再按 ⌥V。"))
            return
        }
        show(query: text, autoTranslate: true)
    }

    // MARK: - 截图取词

    func showScreenshot(_ mode: ScreenshotMode) {
        guard ScreenCapture.hasPermission else {
            presentScreenCaptureGuide()
            return
        }
        if !ScreenshotController.shared.begin(mode) {
            presentScreenCaptureGuide()
        }
    }

    private func presentScreenCaptureGuide() {
        show(query: nil, autoTranslate: false)
        setState(.notice("""
        截图取词需要「屏幕录制」权限。

        1. 在刚打开的系统设置里勾选 Peek
        2. 授权后必须重启 Peek 才生效（系统限制，权限在进程启动时注入）

        菜单栏图标 → 重启 Peek 即可。
        """))
        ScreenCapture.requestPermission()
        ScreenCapture.openSettings()
    }

    func showScreenshotLoading() {
        show(query: nil, autoTranslate: false)
        setState(.loading("识别文字…"))
    }

    /// 对一张已经裁好的图跑 OCR。截图遮罩和缩略图窗的「识别文字」共用这一条路径，
    /// 免得两处各写一份回调、行为和日志对不上。
    ///
    /// `mode` 故意不给默认值：早先默认成 `.ocr`，结果缩略图窗那条调用悄悄变成
    /// 「只识别不翻译」——识别结果占了结果区，输入框却是空的，看起来像功能坏了。
    func recognizeScreenshot(_ image: CGImage, mode: ScreenshotMode) {
        showScreenshotLoading()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try OCR.recognize(image) }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let result):
                    self.showScreenshotResult(result, mode: mode)
                case .failure(let error):
                    Log.info("截图: OCR 失败 \(error.localizedDescription)")
                    self.showScreenshotError(error.localizedDescription)
                }
            }
        }
    }

    func showScreenshotResult(_ result: OCR.Result, mode: ScreenshotMode) {
        switch mode {
        case .translate:
            // 识别出来的原文放上面（输入框），译文放下面（结果区），跟 ⌥S 的行为一致
            let text = result.paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                Log.info("截图: OCR 无文字（\(result.lines.count) 行 / \(result.elapsed)ms）")
                showScreenshotError(OCR.OCRError.noText.localizedDescription)
                return
            }
            Log.info("截图: OCR \(result.lines.count) 行 / \(result.elapsed)ms / \(result.variant)，填入输入框并翻译")
            show(query: text, autoTranslate: true)
        case .ocr:
            show(query: nil, autoTranslate: false)
            var output = TranslateOutput(translation: result.text)
            output.note = "OCR 结果 · \(result.lines.count) 行 · \(result.elapsed)ms · 已复制到剪贴板"
            setState(.result(output))
            writeToPasteboard(result.text)
        case .capture:
            // 纯截图不走 OCR 结果展示
            break
        }
    }

    func showScreenshotError(_ message: String) {
        show(query: nil, autoTranslate: false)
        setState(.failure(message))
    }

    func toggleInput() {
        if isShowing && panel.isVisible {
            hide()
        } else {
            showInput()
        }
    }

    private func show(query: String?, autoTranslate: Bool) {
        let wasVisible = isShowing && panel.isVisible
        isShowing = true

        if let q = query {
            queryTextView.setText(q)
            queryTextView.setSelectedRange(NSRange(location: (q as NSString).length, length: 0))
        } else if !wasVisible {
            queryTextView.setSelectedRange(NSRange(location: (queryTextView.string as NSString).length, length: 0))
        }
        updateCopyBadges()

        positionNearMouse()

        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(queryTextView)
        Log.info("面板显示: visible=\(panel.isVisible) key=\(panel.isKeyWindow) frame=\(NSStringFromRect(panel.frame)) screen=\(NSStringFromRect(NSScreen.main?.visibleFrame ?? .zero))")

        installMonitors()
        lastShownAt = Date()

        if autoTranslate, let q = query, !q.isEmpty {
            translate(text: q)
        }
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        // 收起时清掉固定状态：下次唤起默认还是「点外面就收」，
        // 否则用户会以为面板坏了（点哪都不走）
        if isPinned {
            isPinned = false
            refreshPinButton()
        }
        stopPermissionWatch()
        removeMonitors()
        seed += 1 // 丢弃尚未回来的请求
        panel.orderOut(nil)
    }

    // MARK: - 监听（只在可见期间挂载）

    private func installMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                guard let self else { return }
                // 刚显示时的同一次点击不要算作"点外面"
                if Date().timeIntervalSince(self.lastShownAt) < 0.2 { return }
                self.handleOutsideClick()
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.isShowing, self.panel.isKeyWindow else { return event }
                if event.keyCode == UInt16(KeyCode.escape) {
                    self.hide()
                    return nil
                }
                if (event.keyCode == UInt16(KeyCode.enter) || event.keyCode == UInt16(KeyCode.keypadEnter)),
                   event.modifierFlags.contains(.command) {
                    self.translateCurrent()
                    return nil
                }
                return event
            }
        }
    }

    /// 点到面板外面。抽成方法是为了让自检能覆盖这条判断本身，
    /// 而不只是验证图钉图标有没有变蓝。
    private func handleOutsideClick() {
        if isPinned { return }
        hide()
    }

    private func removeMonitors() {
        if let m = globalMonitor {
            NSEvent.removeMonitor(m)
            globalMonitor = nil
        }
        if let m = localMonitor {
            NSEvent.removeMonitor(m)
            localMonitor = nil
        }
    }

    // MARK: - 定位

    private func positionNearMouse() {
        let size = panel.frame.size
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var x = mouse.x - size.width / 2
        var y = mouse.y - size.height - 16
        if y < visible.minY + 10 {
            y = mouse.y + 16
        }
        x = min(max(visible.minX + 10, x), visible.maxX - size.width - 10)
        y = min(max(visible.minY + 10, y), visible.maxY - size.height - 10)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func clampToScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(visible.minX + 10, frame.origin.x), visible.maxX - frame.width - 10)
        frame.origin.y = min(max(visible.minY + 10, frame.origin.y), visible.maxY - frame.height - 10)
        if frame.origin != panel.frame.origin {
            panel.setFrameOrigin(frame.origin)
        }
    }

    // MARK: - 翻译

    private func translateCurrent() {
        translate(text: queryTextView.string)
    }

    private func translate(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return
        }

        let engine = currentEngine
        let from = Language.named(sourceControl.selectedCode.isEmpty ? "auto" : sourceControl.selectedCode)
        let to = Language.named(targetControl.selectedCode.isEmpty ? "en" : targetControl.selectedCode)

        seed += 1
        let mySeed = seed

        setState(.loading("翻译中…"))

        Task { [weak self] in
            do {
                var output = try await engine.translate(trimmed, from: from, to: to)

                // 原文本来就是目标语言（比如英文翻英文）→ 自动换个方向重翻，别让人看着像没反应
                var swappedTo: Language?
                if output.sameAsTarget, let alt = Self.alternateTarget(for: to) {
                    swappedTo = alt
                    var retried = try await engine.translate(trimmed, from: from, to: alt)
                    retried.note = "原文是\(to.name)，已自动改为翻成\(alt.name)"
                    output = retried
                }

                await MainActor.run {
                    guard let self, self.seed == mySeed else { return }
                    if let swappedTo {
                        self.targetControl.select(code: swappedTo.code)
                    }
                    self.setState(.result(output))
                    if UserDefaults.standard.bool(forKey: PrefKey.autoCopy) {
                        self.writeToPasteboard(output.translation)
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self, self.seed == mySeed else { return }
                    self.setState(.failure(error.localizedDescription))
                }
            }
        }
    }

    /// 同语种时换到哪个方向：中文↔英文，其它语言一律换中文
    private static func alternateTarget(for current: Language) -> Language? {
        if current.code == "en" { return Language.named("zh") }
        if current.code.hasPrefix("zh") { return Language.named("en") }
        return Language.named("zh")
    }

    private func setState(_ newState: State) {
        state = newState
        let attributed: NSAttributedString
        switch newState {
        case .idle:
            attributed = ResultBuilder.loading("Enter 翻译 · Esc 关闭")
        case .loading(let text):
            attributed = ResultBuilder.loading(text)
        case .notice(let text):
            attributed = ResultBuilder.loading(text)
        case .result(let output):
            attributed = ResultBuilder.output(output)
        case .failure(let message):
            attributed = ResultBuilder.error(message)
        }
        let height = resultView.render(attributed)
        relayout(resultH: height, keepTopLeft: true)
        updateCopyBadges()
    }

    /// 复制按钮各自只在对应区域有内容时出现。
    /// 空着还摆个复制按钮，点下去什么都不发生，反而像是坏了。
    private func updateCopyBadges() {
        queryCopyBadge.isHidden = queryTextView.string.isEmpty

        var hasResult = false
        if case .result = state { hasResult = true }
        resultCopyBadge.isHidden = !hasResult
    }

    // MARK: - 动作

    @objc private func languageChanged() {
        guard !queryTextView.string.isEmpty else { return }
        translateCurrent()
    }

    @objc private func swapLanguages() {
        let fromCode = sourceControl.selectedCode
        let toCode = targetControl.selectedCode
        guard !fromCode.isEmpty, fromCode != "auto", !toCode.isEmpty else {
            NSSound.beep()
            return
        }
        sourceControl.select(code: toCode)
        targetControl.select(code: fromCode)
        if !queryTextView.string.isEmpty {
            translateCurrent()
        }
    }

    @objc private func copyResult() {
        let text = resultView.plainText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        writeToPasteboard(text)
        Log.info("复制: 译文 \(text.count) 字")
    }

    private func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// 钉住 / 取消钉住。钉住之后点面板外面不再收起，
    /// 适合对照着原文慢慢改，或者拿面板当参照物看别的窗口。
    @objc private func togglePin() {
        isPinned.toggle()
        refreshPinButton()
        Log.info("面板固定: \(isPinned ? "开" : "关")")
    }

    private func refreshPinButton() {
        pinButton.image = NSImage(systemSymbolName: isPinned ? "pin.fill" : "pin",
                                  accessibilityDescription: isPinned ? "已固定" : "固定面板")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        pinButton.contentTintColor = isPinned ? Theme.accent : Theme.secondary
        pinButton.toolTip = isPinned ? "已固定：点外面不会收起" : "固定面板：点外面不自动收起"
    }

    @objc private func closePanel() {
        hide()
    }

    // MARK: - 外部调用

    /// 供 --snapshot 离线渲染使用：填充一段样例内容并把高度撑开。
    func prepareSnapshot(output: TranslateOutput) {
        queryTextView.setText("Character is destiny.")
        setState(.result(output))
        relayout(resultH: currentResultH, keepTopLeft: false)
        rootCard.layoutSubtreeIfNeeded()
    }

    /// 供 --snapshot 使用
    func snapshotView() -> NSView { rootCard }

    // MARK: - 自检接口

    var debugIsVisible: Bool { isShowing && panel.isVisible }
    var debugFrame: NSRect { panel.frame }
    var debugResultText: String { resultView.plainText() }

    func debugTranslate(text: String) {
        queryTextView.setText(text)
        translate(text: text)
    }

    /// 自检用：真的走一遍按钮的 target/action，再把剪贴板读回来。
    /// 只调 copyResult() 是测不出「按钮有没有连对」的。
    func debugClickCopyBadge(_ which: String) -> String {
        if which == "query" {
            queryCopyBadge.performClick(nil)
        } else {
            resultCopyBadge.performClick(nil)
        }
        return NSPasteboard.general.string(forType: .string) ?? "<剪贴板为空>"
    }

    /// 供 --snapshot 渲染「已固定」状态的图钉外观
    func debugSetPinned(_ on: Bool) {
        isPinned = on
        refreshPinButton()
    }

    var debugIsPinned: Bool { isPinned }

    func debugClickPin() { pinButton.performClick(nil) }

    /// 走一遍「点外面」的真实判断，返回面板是否还留在屏幕上
    func debugOutsideClick() -> Bool {
        handleOutsideClick()
        return debugIsVisible
    }

    func debugUseMockEngine() {
        guard let mock = engines.first(where: { $0.id == "mock" }) else { return }
        currentEngine = mock
        rebuildEngineMenu()
    }

    func debugUseEngine(id: String) {
        guard let engine = engines.first(where: { $0.id == id }) else { return }
        currentEngine = engine
        rebuildEngineMenu()
    }

    var debugQueryText: String { queryTextView.string }

    /// 让查询框拿焦点，并把 ⌘V 事件交给浮窗处理（验证非激活面板的粘贴兜底）
    func debugPasteIntoQuery(_ event: NSEvent) -> (handled: Bool, text: String) {
        if !panel.isVisible { showInput() }
        queryTextView.setText("")
        panel.makeKey()
        _ = panel.makeFirstResponder(queryTextView)
        let handled = panel.performKeyEquivalent(with: event)
        return (handled, queryTextView.string)
    }

    func reloadEngines() {
        engines = EngineRegistry.makeAll()
        currentEngine = EngineRegistry.current(from: engines)
        rebuildEngineMenu()
        if !queryTextView.string.isEmpty {
            translateCurrent()
        }
    }

    private func rebuildEngineMenu() {
        engineControl.setItems(engines.map { MenuControl.Item(title: $0.displayName, code: $0.id) },
                               selected: currentEngine.id)
    }
}
