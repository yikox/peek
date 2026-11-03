import AppKit

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class SettingsWindow: NSObject, NSWindowDelegate {

    static let shared = SettingsWindow()

    private var window: NSPanel?
    private let enginePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let engineHint = NSTextField(labelWithString: "")
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelField = NSTextField()
    private let browseButton = NSButton(title: "浏览可用模型…", target: nil, action: nil)
    private let promptField = NSTextField()
    private let autoCopyCheck = NSButton(checkboxWithTitle: "翻译完成后自动复制译文", target: nil, action: nil)
    private let signupLink = NSTextField(labelWithString: "还没有 Key？免费注册 →")
    private let endpointHint = NSTextField(labelWithString: "")
    private let heading = NSTextField(labelWithString: "OpenAI 兼容引擎")
    private let openAIBodyHint = NSTextField(labelWithString: "填 OpenAI / OpenRouter / vLLM / Ollama 的兼容地址。\n选中「离线翻译」时这一整块不生效，可以留空。")
    private let packStatus = NSTextField(labelWithString: "")
    private let downloadPacksButton = NSButton(title: "下载语言包…", target: nil, action: nil)

    private override init() { super.init() }

    /// 引擎下拉的选项直接来自注册表，新增引擎不用再改这里
    private var engineOptions: [TranslateEngine] { EngineRegistry.makeAll() }

    func show() {
        if window == nil { build() }
        loadValues()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func close() {
        window?.orderOut(nil)
    }

    /// 供离线渲染使用
    func debugContentView() -> NSView? {
        if window == nil { build() }
        loadValues()
        return window?.contentView
    }

    private func build() {
        let width: CGFloat = 460
        let panel = EditingWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
        panel.title = "Peek 设置"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.delegate = self

        let root = FlippedView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        root.autoresizingMask = [.width, .height]
        panel.contentView = root

        var y: CGFloat = 16

        // ── 翻译引擎 ─────────────────────────────
        let engineLabel = NSTextField(labelWithString: "翻译引擎")
        engineLabel.font = .systemFont(ofSize: 11)
        engineLabel.textColor = .secondaryLabelColor
        engineLabel.frame = NSRect(x: 20, y: y, width: 420, height: 16)
        root.addSubview(engineLabel)
        y += 18

        enginePopup.frame = NSRect(x: 20, y: y, width: 420, height: 26)
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
        root.addSubview(enginePopup)
        y += 33

        engineHint.font = .systemFont(ofSize: 11)
        engineHint.textColor = .secondaryLabelColor
        engineHint.cell?.wraps = true
        engineHint.frame = NSRect(x: 20, y: y, width: 420, height: 56)
        root.addSubview(engineHint)
        y += 64

        // 语言包：离线翻译真正的"入口"——没装包选了也翻不出来
        packStatus.font = .systemFont(ofSize: 11)
        packStatus.textColor = .secondaryLabelColor
        packStatus.cell?.wraps = true
        packStatus.frame = NSRect(x: 20, y: y, width: 280, height: 32)
        root.addSubview(packStatus)

        downloadPacksButton.bezelStyle = .rounded
        downloadPacksButton.controlSize = .small
        downloadPacksButton.font = .systemFont(ofSize: 11)
        downloadPacksButton.target = self
        downloadPacksButton.action = #selector(downloadPacks)
        downloadPacksButton.frame = NSRect(x: 300, y: y + 2, width: 140, height: 22)
        root.addSubview(downloadPacksButton)
        y += 40

        let rule = NSBox(frame: NSRect(x: 20, y: y, width: 420, height: 1))
        rule.boxType = .separator
        root.addSubview(rule)
        y += 14

        // ── OpenAI 兼容引擎配置 ───────────────────
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.frame = NSRect(x: 20, y: y, width: 260, height: 18)
        root.addSubview(heading)

        endpointHint.font = .systemFont(ofSize: 11)
        endpointHint.textColor = .secondaryLabelColor
        endpointHint.alignment = .right
        endpointHint.frame = NSRect(x: 280, y: y + 1, width: 160, height: 16)
        root.addSubview(endpointHint)
        y += 22

        openAIBodyHint.font = .systemFont(ofSize: 11)
        openAIBodyHint.textColor = .secondaryLabelColor
        openAIBodyHint.cell?.wraps = true
        openAIBodyHint.frame = NSRect(x: 20, y: y, width: 420, height: 32)
        root.addSubview(openAIBodyHint)
        y += 42

        addRow(to: root, y: &y, title: "Base URL",
               placeholder: "https://openrouter.ai/api/v1", field: baseURLField)

        // API Key 行：右边挂注册入口
        let keyLabel = NSTextField(labelWithString: "API Key")
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.frame = NSRect(x: 20, y: y, width: 200, height: 16)
        root.addSubview(keyLabel)

        // 用 label + 手势做链接：.inline 按钮在深色/非 key window 下会渲染成灰，
        // 看起来像不可点击
        signupLink.font = .systemFont(ofSize: 10.5)
        signupLink.textColor = .controlAccentColor
        signupLink.alignment = .right
        signupLink.frame = NSRect(x: 300, y: y - 1, width: 140, height: 16)
        signupLink.toolTip = "打开注册向导：选服务商 → 创建 Key → 自动校验"
        signupLink.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(openSignup)))
        root.addSubview(signupLink)

        apiKeyField.placeholderString = "sk-…（本地服务可留空）"
        apiKeyField.font = .systemFont(ofSize: 12)
        apiKeyField.frame = NSRect(x: 20, y: y + 18, width: 420, height: 24)
        root.addSubview(apiKeyField)
        y += 54

        // 模型行：右侧挂模型浏览器
        let modelLabel = NSTextField(labelWithString: "模型")
        modelLabel.font = .systemFont(ofSize: 11)
        modelLabel.textColor = .secondaryLabelColor
        modelLabel.frame = NSRect(x: 20, y: y, width: 420, height: 16)
        root.addSubview(modelLabel)

        modelField.placeholderString = "gpt-4o-mini / qwen2.5-7b-instruct"
        modelField.font = .systemFont(ofSize: 12)
        modelField.frame = NSRect(x: 20, y: y + 18, width: 300, height: 24)
        root.addSubview(modelField)

        browseButton.bezelStyle = .rounded
        browseButton.controlSize = .small
        browseButton.font = .systemFont(ofSize: 11)
        browseButton.target = self
        browseButton.action = #selector(openModelBrowser)
        browseButton.frame = NSRect(x: 328, y: y + 20, width: 112, height: 20)
        root.addSubview(browseButton)
        y += 54

        let promptLabel = NSTextField(labelWithString: "系统提示词（留空使用内置翻译 prompt）")
        promptLabel.font = .systemFont(ofSize: 11)
        promptLabel.textColor = .secondaryLabelColor
        promptLabel.frame = NSRect(x: 20, y: y, width: 420, height: 16)
        root.addSubview(promptLabel)
        y += 20

        promptField.placeholderString = "你是专业翻译引擎，只输出译文…"
        promptField.font = .systemFont(ofSize: 12)
        promptField.frame = NSRect(x: 20, y: y, width: 420, height: 56)
        promptField.cell?.wraps = true
        promptField.cell?.isScrollable = false
        root.addSubview(promptField)
        y += 68

        autoCopyCheck.frame = NSRect(x: 18, y: y, width: 300, height: 20)
        autoCopyCheck.font = .systemFont(ofSize: 12)
        root.addSubview(autoCopyCheck)
        y += 34

        let closeButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        closeButton.bezelStyle = .rounded
        closeButton.frame = NSRect(x: 300, y: y, width: 68, height: 26)
        root.addSubview(closeButton)

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"
        saveButton.frame = NSRect(x: 372, y: y, width: 68, height: 26)
        root.addSubview(saveButton)

        y += 46
        panel.setContentSize(NSSize(width: width, height: y))
        window = panel
    }

    private func addRow(to root: NSView, y: inout CGFloat, title: String,
                        placeholder: String, field: NSTextField) {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 20, y: y, width: 420, height: 16)
        root.addSubview(label)

        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        field.frame = NSRect(x: 20, y: y + 18, width: 420, height: 24)
        root.addSubview(field)

        y += 54
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
        if id == "system" {
            refreshPackStatus()
        }
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
    }

    /// 顶部右侧那句「已识别为 OpenRouter」的提示，让用户确认地址填对了
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

    // MARK: - 模型浏览

    @objc private func openModelBrowser() {
        let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else {
            // 没配地址时，直接引导去注册，比弹一个空列表有用
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

    // MARK: - 注册向导

    @objc private func openSignup() {
        SignupWizard.shared.show(baseURL: baseURLField.stringValue,
                                 apiKey: apiKeyField.stringValue) { [weak self] base, key, _ in
            guard let self else { return }
            if !base.isEmpty {
                self.baseURLField.stringValue = base
            }
            self.apiKeyField.stringValue = key
            self.refreshEndpointHint()
            // 注册完不必让用户再点一次保存：先落盘，再直接打开模型列表
            self.applyValues()
            self.openModelBrowser()
        }
    }

    // MARK: - 保存

    private func applyValues() {
        let defaults = UserDefaults.standard
        let base = baseURLField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defaults.set(base, forKey: PrefKey.baseURL)
        defaults.set(apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: PrefKey.apiKey)
        defaults.set(modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: PrefKey.model)
        defaults.set(promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                     forKey: PrefKey.systemPrompt)
        defaults.set(autoCopyCheck.state == .on, forKey: PrefKey.autoCopy)
        defaults.set(selectedEngineId, forKey: PrefKey.engineId)
        refreshEndpointHint()
        PanelController.shared.reloadEngines()
    }

    @objc private func save() {
        applyValues()
        close()
    }

    @objc private func cancel() {
        close()
    }

    // MARK: - 自检辅助

    /// 让 Key 输入框拿到焦点，用于验证粘贴链路
    @discardableResult
    func debugFocusKeyField() -> Bool {
        if window == nil { build() }
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
}
