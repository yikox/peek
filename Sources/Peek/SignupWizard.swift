import AppKit

/// 服务商预设。只收录有公开免费额度或国内可直连的几家，
/// 其余情况走「自定义」，地址自己填。
struct ProviderPreset {
    let id: String
    let name: String
    let baseURL: String
    let signupURL: String
    let keysURL: String
    let note: String
    let freeLine: String

    static let all: [ProviderPreset] = [
        ProviderPreset(
            id: "openrouter",
            name: "OpenRouter（推荐，有免费额度）",
            baseURL: "https://openrouter.ai/api/v1",
            signupURL: "https://openrouter.ai/sign-up",
            keysURL: "https://openrouter.ai/keys",
            note: "一个 Key 调用 400+ 个模型，包含 GPT、Claude、Gemini、Qwen 等。不需要绑卡。",
            freeLine: "免费池 50 次/天、20 次/分（充值 $10 后 1000 次/天）"
        ),
        ProviderPreset(
            id: "siliconflow",
            name: "硅基流动 SiliconFlow（国内直连）",
            baseURL: "https://api.siliconflow.cn/v1",
            signupURL: "https://cloud.siliconflow.cn",
            keysURL: "https://cloud.siliconflow.cn/account/ak",
            note: "国内节点，延迟低。注册赠额度，Qwen、GLM 等部分模型长期免费。",
            freeLine: "以控制台显示为准"
        ),
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek（按量计费，价格低）",
            baseURL: "https://api.deepseek.com/v1",
            signupURL: "https://platform.deepseek.com/sign_up",
            keysURL: "https://platform.deepseek.com/api_keys",
            note: "没有免费额度，需要先充值。翻译质量好，成本大约是 GPT-4o 的 1/30。",
            freeLine: "无免费额度"
        ),
        ProviderPreset(
            id: "custom",
            name: "自定义 / 内部网关",
            baseURL: "",
            signupURL: "",
            keysURL: "",
            note: "已经有地址了，直接在设置里填 Base URL、Key 和模型名即可。",
            freeLine: ""
        ),
    ]
}

/// 三步注册向导：选服务商 → 注册并创建 Key → 校验并回填。
/// 不做账号体系，Peek 本身没有服务端；这里的「注册」指注册模型服务商。
final class SignupWizard: NSObject, NSWindowDelegate {

    static let shared = SignupWizard()

    private var panel: NSPanel?
    private let stepContainer = NSView()
    private var stepViews: [NSView] = []
    private let backButton = NSButton(title: "上一步", target: nil, action: nil)
    private let primaryButton = NSButton(title: "打开注册页面", target: nil, action: nil)
    private let skipButton = NSButton(title: "跳过", target: nil, action: nil)

    // Step 1
    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let providerNote = NSTextField(wrappingLabelWithString: "")
    private let providerFree = NSTextField(wrappingLabelWithString: "")

    // Step 2
    private let keyField = NSTextField()
    private let keyStatus = NSTextField(wrappingLabelWithString: "")
    private let openKeysButton = NSButton(title: "打开密钥页面", target: nil, action: nil)

    // Step 3
    private let doneTitle = NSTextField(labelWithString: "配置完成")
    private let doneDetail = NSTextField(wrappingLabelWithString: "")
    private let doneCheck = NSTextField(labelWithString: "✓")

    private var step = 0
    private var provider: ProviderPreset { ProviderPreset.all[max(0, providerPopup.indexOfSelectedItem)] }
    private var isVerifying = false
    private var onFinish: ((String, String, AccountInfo?) -> Void)?   // (baseURL, key, info)

    private override init() { super.init() }

    func show(baseURL: String, apiKey: String, onFinish: @escaping (String, String, AccountInfo?) -> Void) {
        if panel == nil { build() }
        self.onFinish = onFinish

        keyField.stringValue = apiKey
        keyStatus.stringValue = ""
        isVerifying = false

        // 当前地址已经属于某家预设时，直接定位到那一家
        if let match = ProviderPreset.all.firstIndex(where: {
            !$0.baseURL.isEmpty && baseURL.hasPrefix($0.baseURL)
        }) {
            providerPopup.selectItem(at: match)
        } else {
            providerPopup.selectItem(at: 0)
        }
        syncProviderUI()
        goto(0)

        NSApp.activate(ignoringOtherApps: true)
        panel?.center()
        panel?.makeKeyAndOrderFront(nil)
        panel?.makeFirstResponder(nil)
    }

    // MARK: 构建

    private func build() {
        let rect = NSRect(x: 0, y: 0, width: 448, height: 438)
        let p = EditingWindow(contentRect: rect,
                        styleMask: [.titled, .closable],
                        backing: .buffered,
                        defer: false)
        p.title = "配置翻译服务"
        p.isFloatingPanel = true
        p.level = .modalPanel
        p.hidesOnDeactivate = false
        p.delegate = self

        let root = FlippedView(frame: NSRect(origin: .zero, size: rect.size))
        p.contentView = root

        stepContainer.frame = NSRect(x: 24, y: 20, width: 392, height: 318)
        root.addSubview(stepContainer)

        stepViews = [buildStepOne(), buildStepTwo(), buildStepThree()]
        for view in stepViews {
            view.frame = stepContainer.bounds
            stepContainer.addSubview(view)
        }

        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(goBack)
        backButton.frame = NSRect(x: 24, y: 362, width: 76, height: 26)
        root.addSubview(backButton)

        skipButton.bezelStyle = .rounded
        skipButton.target = self
        skipButton.action = #selector(skip)
        skipButton.frame = NSRect(x: 112, y: 362, width: 64, height: 26)
        root.addSubview(skipButton)

        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"
        primaryButton.target = self
        primaryButton.action = #selector(primaryAction)
        primaryButton.frame = NSRect(x: 236, y: 362, width: 188, height: 26)
        root.addSubview(primaryButton)

        panel = p
    }

    private func buildStepOne() -> NSView {
        let v = FlippedView(frame: stepContainer.bounds)

        let title = heading("1 · 选一个翻译服务")
        v.addSubview(title)

        providerPopup.frame = NSRect(x: 0, y: 34, width: 392, height: 26)
        providerPopup.font = .systemFont(ofSize: 12)
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        for preset in ProviderPreset.all {
            providerPopup.addItem(withTitle: preset.name)
        }
        v.addSubview(providerPopup)

        providerNote.font = .systemFont(ofSize: 11.5)
        providerNote.textColor = .secondaryLabelColor
        providerNote.frame = NSRect(x: 0, y: 70, width: 390, height: 52)
        v.addSubview(providerNote)

        providerFree.font = .systemFont(ofSize: 11.5)
        providerFree.textColor = .labelColor
        providerFree.frame = NSRect(x: 0, y: 128, width: 390, height: 20)
        v.addSubview(providerFree)

        let rule = NSBox(frame: NSRect(x: 0, y: 162, width: 392, height: 1))
        rule.boxType = .separator
        v.addSubview(rule)

        let why = heading("为什么用大模型翻译")
        why.font = .systemFont(ofSize: 12, weight: .semibold)
        why.frame = NSRect(x: 0, y: 180, width: 392, height: 16)
        v.addSubview(why)

        let bullets = bodyText("""
        · 能按语境选词，比传统翻译 API 更接近人工译文
        · 提示词可以改：双语对照、只翻术语、保留 Markdown 都能做到
        · 同一个 Key 既能翻译，也能做 OCR 后的润色
        """)
        bullets.frame = NSRect(x: 0, y: 202, width: 390, height: 66)
        v.addSubview(bullets)

        let privacy = bodyText("API Key 只保存在本机偏好设置里，Peek 没有服务端。")
        privacy.font = .systemFont(ofSize: 10.5)
        privacy.frame = NSRect(x: 0, y: 278, width: 390, height: 16)
        v.addSubview(privacy)

        return v
    }

    private func buildStepTwo() -> NSView {
        let v = FlippedView(frame: stepContainer.bounds)

        let title = heading("2 · 创建并粘贴 API Key")
        v.addSubview(title)

        let steps = bodyText("""
        ① 在弹出的网页里完成注册（或登录）
        ② 打开密钥页面，点「Create Key / 新建 API Key」
        ③ 复制生成的 Key，粘贴到下面
        """)
        steps.frame = NSRect(x: 0, y: 34, width: 390, height: 66)
        v.addSubview(steps)

        openKeysButton.bezelStyle = .rounded
        openKeysButton.controlSize = .small
        openKeysButton.font = .systemFont(ofSize: 11)
        openKeysButton.target = self
        openKeysButton.action = #selector(openKeysPage)
        openKeysButton.frame = NSRect(x: 0, y: 104, width: 108, height: 24)
        v.addSubview(openKeysButton)

        let keyLabel = NSTextField(labelWithString: "API Key")
        keyLabel.font = .systemFont(ofSize: 11)
        keyLabel.textColor = .secondaryLabelColor
        keyLabel.frame = NSRect(x: 0, y: 142, width: 392, height: 16)
        v.addSubview(keyLabel)

        keyField.placeholderString = "sk-…"
        keyField.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        keyField.frame = NSRect(x: 0, y: 160, width: 392, height: 26)
        keyField.delegate = self
        v.addSubview(keyField)

        keyStatus.font = .systemFont(ofSize: 11)
        keyStatus.textColor = .secondaryLabelColor
        keyStatus.frame = NSRect(x: 0, y: 194, width: 390, height: 48)
        v.addSubview(keyStatus)

        let hint = bodyText("验证会向服务商发一次真实请求，用于确认 Key 有效并读取额度。")
        hint.font = .systemFont(ofSize: 10.5)
        hint.frame = NSRect(x: 0, y: 250, width: 390, height: 16)
        v.addSubview(hint)

        return v
    }

    private func buildStepThree() -> NSView {
        let v = FlippedView(frame: stepContainer.bounds)

        doneCheck.font = .systemFont(ofSize: 34, weight: .light)
        doneCheck.textColor = .systemGreen
        doneCheck.frame = NSRect(x: 0, y: 8, width: 40, height: 40)
        v.addSubview(doneCheck)

        doneTitle.font = .systemFont(ofSize: 15, weight: .semibold)
        doneTitle.frame = NSRect(x: 0, y: 56, width: 392, height: 20)
        v.addSubview(doneTitle)

        doneDetail.font = .systemFont(ofSize: 11.5)
        doneDetail.textColor = .secondaryLabelColor
        doneDetail.frame = NSRect(x: 0, y: 86, width: 390, height: 84)
        v.addSubview(doneDetail)

        let tip = bodyText("""
        现在可以：
        ⌥F  输入翻译
        ⌥D  划词翻译（首次需要「辅助功能」授权）
        """)
        tip.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tip.textColor = .secondaryLabelColor
        tip.frame = NSRect(x: 0, y: 186, width: 390, height: 60)
        v.addSubview(tip)

        return v
    }

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.frame = NSRect(x: 0, y: 0, width: 392, height: 20)
        return label
    }

    private func bodyText(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11.5)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }

    // MARK: 步骤切换

    private func goto(_ index: Int) {
        step = max(0, min(index, stepViews.count - 1))
        for (i, view) in stepViews.enumerated() {
            view.isHidden = (i != step)
        }
        // 走到完成页就没有「回退」的含义了，藏掉比置灰干净
        backButton.isHidden = (step == 2)
        skipButton.isHidden = (step == 2)

        switch step {
        case 0:
            primaryButton.title = "打开注册页面"
            primaryButton.isEnabled = !provider.signupURL.isEmpty
        case 1:
            primaryButton.title = "验证并完成"
            primaryButton.isEnabled = !keyField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            primaryButton.title = "完成"
            primaryButton.isEnabled = true
        }
        primaryButton.bezelColor = primaryButton.isEnabled ? .controlAccentColor : nil
        // 未显示的窗口不设焦点：否则 NSTextField 一成为 first responder 就会全选，
        // 离线渲染出来是一整条选中高亮。
        if panel?.isVisible == true {
            panel?.makeFirstResponder(step == 1 ? keyField : nil)
        }
    }

    private func syncProviderUI() {
        let p = provider
        providerNote.stringValue = p.note
        providerFree.stringValue = p.freeLine.isEmpty ? "" : "额度：\(p.freeLine)"
        openKeysButton.isEnabled = !p.keysURL.isEmpty
        primaryButton.isEnabled = !p.signupURL.isEmpty
        primaryButton.bezelColor = primaryButton.isEnabled ? .controlAccentColor : nil
    }

    @objc private func providerChanged() {
        syncProviderUI()
    }

    @objc private func goBack() {
        guard step > 0, !isVerifying else { return }
        goto(step - 1)
    }

    // MARK: 主按钮

    @objc private func primaryAction() {
        switch step {
        case 0:
            open(provider.signupURL)
            // 注册和创建 Key 是连续动作，直接进下一步减少一次点击
            goto(1)
        case 1:
            verifyKey()
        default:
            finish()
        }
    }

    @objc private func openKeysPage() {
        open(provider.keysURL)
    }

    private func open(_ urlString: String) {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func verifyKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        isVerifying = true
        primaryButton.isEnabled = false
        primaryButton.title = "验证中…"
        keyField.isEnabled = false
        keyStatus.textColor = .secondaryLabelColor
        keyStatus.stringValue = "正在向 \(provider.name) 验证…"

        let preset = provider

        Task { [weak self] in
            do {
                let info = try await Self.verify(key: key, provider: preset)
                await MainActor.run {
                    guard let self else { return }
                    self.isVerifying = false
                    self.keyField.isEnabled = true
                    self.primaryButton.isEnabled = true
                    self.primaryButton.title = "验证并完成"
                    self.keyStatus.textColor = .systemGreen
                    self.keyStatus.stringValue = "Key 有效 · \(info.summary)"
                    self.showSuccess(key: key, info: info)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isVerifying = false
                    self.keyField.isEnabled = true
                    self.primaryButton.isEnabled = true
                    self.primaryButton.title = "验证并完成"
                    self.keyStatus.textColor = .systemRed
                    self.keyStatus.stringValue = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                }
            }
        }
    }

    private static func verify(key: String, provider: ProviderPreset) async throws -> AccountInfo {
        if provider.id == "openrouter" {
            return try await KeyVerifier.verify(baseURL: provider.baseURL, apiKey: key, fallbackModel: "")
        }
        // 其他服务商没有 /key 端点：先列模型，拿第一个能对话的试一次
        let models: [ModelEntry]
        do {
            models = try await ModelCatalog.fetch(baseURL: provider.baseURL, apiKey: key)
        } catch CatalogError.http(let code, _) where code == 401 || code == 403 {
            throw KeyVerifyError.invalid("Key 无效或未开通权限（HTTP \(code)）")
        }
        guard let probeModel = models.first else {
            throw KeyVerifyError.invalid("该账号下列不出可用模型，请先确认已开通服务。")
        }
        return try await KeyVerifier.verify(baseURL: provider.baseURL,
                                            apiKey: key,
                                            fallbackModel: probeModel.id)
    }

    private func showSuccess(key: String, info: AccountInfo) {
        var lines: [String] = []
        lines.append("服务商：\(provider.name)")
        lines.append("额度：\(info.summary)")
        if let rate = info.rateLimitText {
            lines.append(rate)
        }
        if let label = info.label, !label.isEmpty {
            lines.append("Key 名称：\(label)")
        }
        lines.append("模型列表已就绪，下一步可以直接挑一个。")
        doneDetail.stringValue = lines.joined(separator: "\n")
        goto(2)
    }

    private func finish() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = provider.baseURL.isEmpty ? providerPresetBase() : provider.baseURL
        onFinish?(base, key, nil)
        close()
    }

    private func providerPresetBase() -> String {
        provider.baseURL
    }

    @objc private func skip() {
        close()
    }

    private func close() {
        isVerifying = false
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        isVerifying = false
    }

    // MARK: 离线渲染

    func debugShow(step: Int, key: String = "", status: String = "", detail: String = "") {
        if panel == nil { build() }
        providerPopup.selectItem(at: 0)
        if !key.isEmpty { keyField.stringValue = key }
        // 先灌值再切步：否则按钮的启用状态是按空输入框算的
        syncProviderUI()
        goto(step)
        if !status.isEmpty {
            keyStatus.stringValue = status
            keyStatus.textColor = .secondaryLabelColor
        }
        if !detail.isEmpty {
            doneDetail.stringValue = detail
        }
    }

    func debugContentView() -> NSView? {
        if panel == nil { build() }
        return panel?.contentView
    }
}

extension SignupWizard: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard step == 1 else { return }
        primaryButton.isEnabled = !keyField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
        keyStatus.stringValue = ""
    }
}
