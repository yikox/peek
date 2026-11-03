import AppKit

// MARK: - 行视图

/// 自绘选中态：系统蓝底会把自定义文字色压掉，这里用 14% 强调色 + 左侧竖条。
final class ModelRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 1)
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

        NSColor.controlAccentColor.setFill()
        let bar = NSRect(x: 4, y: bounds.midY - 8, width: 2, height: 16)
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }

    override var isEmphasized: Bool {
        get { false }
        set {}
    }
}

// MARK: - 单元格

final class ModelCellView: NSTableCellView {

    private let dot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let priceLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    private var priceTint: NSColor = .secondaryLabelColor
    private var priceIsBadge = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        addSubview(dot)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        addSubview(titleLabel)

        subLabel.font = .systemFont(ofSize: 10.5)
        subLabel.textColor = .secondaryLabelColor
        subLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(subLabel)

        contextLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        contextLabel.textColor = .secondaryLabelColor
        contextLabel.alignment = .right
        addSubview(contextLabel)

        priceLabel.font = .systemFont(ofSize: 10, weight: .medium)
        priceLabel.alignment = .center
        priceLabel.wantsLayer = true
        priceLabel.layer?.cornerRadius = 3
        addSubview(priceLabel)

        statusLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func layout() {
        super.layout()
        let h = bounds.height
        let W = bounds.width

        // 右侧三段固定宽度、依次左推；左侧文字吃掉剩余空间
        let statusW: CGFloat = 92
        let priceW: CGFloat = 92
        let ctxW: CGFloat = 58
        let statusX = W - 8 - statusW
        let priceX = statusX - 6 - priceW
        let ctxX = priceX - 6 - ctxW
        let textW = max(120, ctxX - 24)

        let titleH: CGFloat = 16
        let subH: CGFloat = 14
        let gap: CGFloat = 2
        let blockH = titleH + gap + subH
        let top = (h - blockH) / 2

        dot.frame = NSRect(x: 6, y: (h - 8) / 2, width: 8, height: 8)
        subLabel.frame = NSRect(x: 20, y: top, width: textW, height: subH)
        titleLabel.frame = NSRect(x: 20, y: top + subH + gap, width: textW, height: titleH)
        contextLabel.frame = NSRect(x: ctxX, y: (h - 14) / 2, width: ctxW, height: 14)
        statusLabel.frame = NSRect(x: statusX, y: (h - 14) / 2, width: statusW, height: 14)

        // 价格标签收紧到文字宽度，否则「免费」会拉成一整条色带
        if priceLabel.isHidden {
            priceLabel.frame = .zero
        } else {
            let textWidth = ceil(priceLabel.intrinsicContentSize.width) + 12
            let width = min(textWidth, priceW)
            priceLabel.frame = NSRect(x: priceX + (priceW - width) / 2,
                                      y: (h - 17) / 2,
                                      width: width, height: 17)
        }
    }

    func configure(model: ModelEntry, outcome: ProbeOutcome?, probing: Bool) {
        titleLabel.stringValue = model.title
        subLabel.stringValue = model.id
        contextLabel.stringValue = model.contextLabel

        if let price = model.priceLabel {
            priceLabel.stringValue = price
            priceLabel.isHidden = false
            priceIsBadge = model.isFree
            priceTint = model.isFree ? .systemGreen : .secondaryLabelColor
        } else {
            priceLabel.stringValue = ""
            priceLabel.isHidden = true
        }

        if probing {
            dot.layer?.backgroundColor = NSColor.systemYellow.cgColor
            statusLabel.stringValue = "检测中…"
            statusLabel.textColor = .tertiaryLabelColor
        } else if let outcome {
            switch outcome.status {
            case .ok:
                dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
                statusLabel.textColor = .systemGreen
            case .risky, .rateLimited:
                dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
                statusLabel.textColor = .systemOrange
            default:
                dot.layer?.backgroundColor = NSColor.systemRed.cgColor
                statusLabel.textColor = .systemRed
            }
            statusLabel.stringValue = outcome.shortLabel
        } else {
            dot.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
            statusLabel.stringValue = "未检测"
            statusLabel.textColor = .tertiaryLabelColor
        }

        applyPriceStyle()

        // 状态列只有一个短词，具体原因放 tooltip，避免撑破行宽
        if let outcome, !outcome.note.isEmpty {
            toolTip = "\(model.id)\n\(outcome.note)"
        } else {
            toolTip = model.id
        }
        // 价格标签宽度取决于文字，内容变了要重新排一次
        needsLayout = true
    }

    private func applyPriceStyle() {
        priceLabel.textColor = priceTint
        priceLabel.layer?.backgroundColor = priceIsBadge
            ? NSColor.systemGreen.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    /// 明暗切换时 CALayer 里的 CGColor 不会自动跟随，需要重解析
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let appearance = effectiveAppearance
        appearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = dot.layer?.backgroundColor
            applyPriceStyle()
        }
    }
}

// MARK: - 模型浏览窗口

final class ModelBrowserWindow: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {

    static let shared = ModelBrowserWindow()

    private var panel: NSPanel?
    private let titleLabel = NSTextField(labelWithString: "可用模型")
    private let sourceLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let filterPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let refreshButton = NSButton(title: "刷新列表", target: nil, action: nil)
    private let probeButton = NSButton(title: "检测可用性", target: nil, action: nil)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private let useButton = NSButton(title: "使用该模型", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    // 数据
    private var allModels: [ModelEntry] = []
    private var visibleModels: [ModelEntry] = []
    private var outcomes: [String: ProbeOutcome] = [:]
    private var probing: Set<String> = []

    // 上下文
    private var baseURL = ""
    private var apiKey = ""
    private var currentModel = ""
    private var onPick: ((ModelEntry) -> Void)?

    private var probeTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?

    private enum Filter: Int, CaseIterable {
        case all, free, usable, failed
        var title: String {
            switch self {
            case .all: return "全部模型"
            case .free: return "仅免费"
            case .usable: return "仅可用"
            case .failed: return "仅异常"
            }
        }
    }

    private override init() { super.init() }

    // MARK: 对外

    func show(baseURL: String, apiKey: String, currentModel: String,
              onPick: @escaping (ModelEntry) -> Void) {
        if panel == nil { build() }
        self.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentModel = currentModel
        self.onPick = onPick

        outcomes.removeAll()
        probing.removeAll()
        allModels.removeAll()
        visibleModels.removeAll()
        searchField.stringValue = ""
        filterPopup.selectItem(at: 0)
        tableView.reloadData()

        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)

        if self.baseURL.isEmpty {
            sourceLabel.stringValue = "还没有配置 Base URL"
            statusLabel.stringValue = "先在设置里填 Base URL，或点这里使用 OpenRouter"
            statusLabel.textColor = .systemOrange
            setBusy(false)
            return
        }

        loadModels()
    }

    // MARK: 构建界面

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: 700, height: 566)
        let p = EditingWindow(contentRect: rect,
                        styleMask: [.titled, .closable, .resizable],
                        backing: .buffered,
                        defer: false)
        p.title = "选择模型"
        p.minSize = NSSize(width: 620, height: 420)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.delegate = self

        let root = FlippedView(frame: NSRect(origin: .zero, size: rect.size))
        p.contentView = root

        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 16, width: 300, height: 18)
        root.addSubview(titleLabel)

        sourceLabel.font = .systemFont(ofSize: 11)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingMiddle
        sourceLabel.frame = NSRect(x: 320, y: 18, width: 360, height: 15)
        sourceLabel.alignment = .right
        root.addSubview(sourceLabel)

        searchField.placeholderString = "搜索模型名"
        searchField.font = .systemFont(ofSize: 12)
        searchField.frame = NSRect(x: 20, y: 45, width: 240, height: 24)
        searchField.target = self
        searchField.action = #selector(filtersChanged)
        searchField.sendsSearchStringImmediately = true
        root.addSubview(searchField)

        filterPopup.removeAllItems()
        for f in Filter.allCases { filterPopup.addItem(withTitle: f.title) }
        filterPopup.selectItem(at: 0)
        filterPopup.font = .systemFont(ofSize: 11)
        filterPopup.controlSize = .small
        filterPopup.frame = NSRect(x: 268, y: 45, width: 104, height: 24)
        filterPopup.target = self
        filterPopup.action = #selector(filtersChanged)
        root.addSubview(filterPopup)

        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.font = .systemFont(ofSize: 11)
        refreshButton.target = self
        refreshButton.action = #selector(loadModels)
        refreshButton.frame = NSRect(x: 382, y: 45, width: 80, height: 24)
        root.addSubview(refreshButton)

        probeButton.bezelStyle = .rounded
        probeButton.controlSize = .small
        probeButton.font = .systemFont(ofSize: 11)
        probeButton.target = self
        probeButton.action = #selector(probeVisible)
        probeButton.frame = NSRect(x: 468, y: 45, width: 100, height: 24)
        root.addSubview(probeButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.frame = NSRect(x: 576, y: 49, width: 16, height: 16)
        root.addSubview(spinner)

        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(useSelected)
        if #available(macOS 11.0, *) {
            tableView.style = .plain
        }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("model"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        root.addSubview(scrollView)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        root.addSubview(cancelButton)

        useButton.bezelStyle = .rounded
        useButton.keyEquivalent = "\r"
        useButton.isEnabled = false
        useButton.target = self
        useButton.action = #selector(useSelected)
        root.addSubview(useButton)

        // 首次布局时按内容区高度摆放一次；之后随窗口拉伸重排
        layoutChrome(size: rect.size)
        p.contentView?.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentResized(_:)),
            name: NSView.frameDidChangeNotification, object: root)

        panel = p
    }

    @objc private func contentResized(_ note: Notification) {
        guard let view = note.object as? NSView else { return }
        layoutChrome(size: view.bounds.size)
    }

    private func layoutChrome(size: NSSize) {
        let W = size.width
        let H = size.height
        let bottomBar: CGFloat = 48

        scrollView.frame = NSRect(x: 16, y: 80, width: W - 32, height: H - 80 - bottomBar)
        statusLabel.frame = NSRect(x: 20, y: H - bottomBar + 16, width: W - 360, height: 16)
        cancelButton.frame = NSRect(x: W - 232, y: H - bottomBar + 10, width: 76, height: 26)
        useButton.frame = NSRect(x: W - 148, y: H - bottomBar + 10, width: 116, height: 26)
        sourceLabel.frame = NSRect(x: 320, y: 18, width: W - 340, height: 15)
        probeButton.frame = NSRect(x: 468, y: 45, width: 100, height: 24)
        spinner.frame = NSRect(x: 576, y: 49, width: 16, height: 16)
    }

    // MARK: 拉列表

    @objc private func loadModels() {
        guard !baseURL.isEmpty else { return }
        loadTask?.cancel()
        probeTask?.cancel()
        setBusy(true)
        refreshButton.isEnabled = false
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "正在获取模型列表…"

        let base = baseURL
        let key = apiKey

        loadTask = Task { [weak self] in
            do {
                let models = try await ModelCatalog.fetch(baseURL: base, apiKey: key)
                await MainActor.run {
                    guard let self else { return }
                    self.allModels = models
                    self.outcomes.removeAll()
                    self.refreshButton.isEnabled = true
                    self.sourceLabel.stringValue = self.sourceDescription(count: models.count)
                    self.applyFilter()
                    self.setBusy(false)
                    self.autoProbeFreeModels()
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.refreshButton.isEnabled = true
                    self.setBusy(false)
                    self.allModels = []
                    self.visibleModels = []
                    self.tableView.reloadData()
                    let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    self.statusLabel.textColor = .systemRed
                    self.statusLabel.stringValue = message
                }
            }
        }
    }

    private func sourceDescription(count: Int) -> String {
        let host = URL(string: baseURL)?.host ?? baseURL
        return "\(host) · \(count) 个"
    }

    // MARK: 探测

    /// 打开后自动探测免费模型：免费池不产生费用，且是大部分人真正会用的一档。
    /// 付费模型一律不自动测，避免替用户花钱。
    private func autoProbeFreeModels() {
        let free = visibleModels.filter { $0.isFree }
        guard !free.isEmpty else {
            updateStatus()
            return
        }
        run(free, announce: "正在检测 \(free.count) 个免费模型…")
    }

    @objc private func probeVisible() {
        let targets = visibleModels
        guard !targets.isEmpty else { return }

        let paid = targets.filter { !$0.isFree && $0.promptPricePerM != nil }
        if !paid.isEmpty {
            let alert = NSAlert()
            alert.messageText = "其中 \(paid.count) 个是付费模型"
            alert.informativeText = "检测会对每个模型发一次真实请求（最多 1 个输出 token），会产生极少量费用。继续吗？"
            alert.addButton(withTitle: "继续检测")
            alert.addButton(withTitle: "只测免费")
            alert.addButton(withTitle: "取消")
            let response = alert.runModal()
            if response == .alertThirdButtonReturn { return }
            if response == .alertSecondButtonReturn {
                run(targets.filter { $0.isFree }, announce: nil)
                return
            }
        }
        run(targets, announce: nil)
    }

    private func run(_ targets: [ModelEntry], announce: String?) {
        guard !targets.isEmpty else { return }
        probeTask?.cancel()

        let base = baseURL
        let key = apiKey
        let ids = targets.map(\.id)

        for id in ids {
            probing.insert(id)
            outcomes[id] = nil
        }
        reloadRows(for: ids)
        setBusy(true)
        if let announce { statusLabel.stringValue = announce }
        updateStatus()

        // 并发 2：OpenRouter 免费池限制 20 次/分，并发过高会直接 429
        let limit = 2
        probeTask = Task { [weak self] in
            await withTaskGroup(of: (String, ProbeOutcome).self) { group in
                var index = 0
                func addNext() {
                    guard index < ids.count else { return }
                    let id = ids[index]
                    index += 1
                    group.addTask {
                        let outcome = await ModelProbe.probe(model: id, baseURL: base, apiKey: key)
                        return (id, outcome)
                    }
                }
                for _ in 0..<min(limit, ids.count) { addNext() }

                for await (id, outcome) in group {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        guard let self else { return }
                        self.probing.remove(id)
                        self.outcomes[id] = outcome
                        self.reloadRows(for: [id])
                        self.updateStatus()
                    }
                    addNext()
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.setBusy(false)
                self.applyFilterKeepingSelection()
                self.updateStatus()
            }
        }
    }

    private func reloadRows(for ids: [String]) {
        var indexes = IndexSet()
        for (row, model) in visibleModels.enumerated() where ids.contains(model.id) {
            indexes.insert(row)
        }
        guard !indexes.isEmpty else { return }
        tableView.reloadData(forRowIndexes: indexes,
                             columnIndexes: IndexSet(integer: 0))
    }

    // MARK: 筛选

    @objc private func filtersChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespaces)
            .lowercased()
        let filter = Filter(rawValue: filterPopup.indexOfSelectedItem) ?? .all

        visibleModels = allModels.filter { model in
            if !query.isEmpty {
                let hit = model.id.lowercased().contains(query)
                    || model.name.lowercased().contains(query)
                if !hit { return false }
            }
            switch filter {
            case .all:
                return true
            case .free:
                return model.isFree
            case .usable:
                return outcomes[model.id]?.isUsable == true
            case .failed:
                guard let o = outcomes[model.id] else { return false }
                return !o.isUsable
            }
        }
        tableView.reloadData()
        updateStatus()
    }

    private func applyFilterKeepingSelection() {
        let selectedId = selectedModel()?.id
        applyFilter()
        if let selectedId,
           let row = visibleModels.firstIndex(where: { $0.id == selectedId }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    private func updateStatus() {
        guard !allModels.isEmpty else { return }
        let free = allModels.filter(\.isFree).count
        let tested = outcomes.count
        let usable = outcomes.values.filter(\.isUsable).count
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.stringValue = "共 \(allModels.count) 个 · 免费 \(free) 个 · 已检测 \(tested) 个 · 可用 \(usable) 个"
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    // MARK: 表格

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleModels.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        ModelRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visibleModels.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("ModelCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ModelCellView
            ?? {
                let view = ModelCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: 38))
                view.identifier = identifier
                return view
            }()

        let model = visibleModels[row]
        cell.configure(model: model,
                       outcome: outcomes[model.id],
                       probing: probing.contains(model.id))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        useButton.isEnabled = selectedModel() != nil
    }

    private func selectedModel() -> ModelEntry? {
        let row = tableView.selectedRow
        guard row >= 0, row < visibleModels.count else { return nil }
        return visibleModels[row]
    }

    @objc private func useSelected() {
        guard let model = selectedModel() else { return }
        onPick?(model)
        cancel()
    }

    @objc private func cancel() {
        probeTask?.cancel()
        loadTask?.cancel()
        probeTask = nil
        loadTask = nil
        setBusy(false)
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        probeTask?.cancel()
        loadTask?.cancel()
    }

    // MARK: 离线渲染

    func debugPrepare(baseURL: String, samples: [ModelEntry], outcomes: [String: ProbeOutcome]) {
        if panel == nil { build() }
        self.baseURL = baseURL
        self.allModels = samples
        self.outcomes = outcomes
        self.filterPopup.selectItem(at: 0)
        self.searchField.stringValue = ""
        self.sourceLabel.stringValue = sourceDescription(count: samples.count)
        applyFilter()
        setBusy(false)
    }

    func debugContentView() -> NSView? {
        if panel == nil { build() }
        return panel?.contentView
    }
}
