import AppKit

/// 离线渲染：把面板渲染成 PNG，用于无头环境下的视觉自检。
/// 不显示窗口、不需要屏幕录制权限。
enum Snapshot {

    static func sample() -> TranslateOutput {
        TranslateOutput(
            translation: "一个人的性格就是他的命运。",
            phonetics: "/ˈkærəktə(r) ɪz ˈdestəni/",
            senses: [
                Sense(pos: "n.", defs: ["性格，品质；特征", "（电影、小说中的）角色，人物"]),
                Sense(pos: "v.", defs: ["使具有特征"]),
            ],
            note: "Mock 引擎 · 未发起网络请求"
        )
    }

    static func capture(dark: Bool, path: String) {
        if dark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        let controller = PanelController.shared
        controller.prepareSnapshot(output: sample())
        if CommandLine.arguments.contains("--pinned") {
            controller.debugSetPinned(true)
        }

        let view = controller.snapshotView()
        render(view, to: path)
    }

    /// 把「正在显示的面板」原样渲染成 PNG。用于验证真实链路（比如截图识别 + 翻译）
    /// 跑完之后的界面，而不是拿 sample() 假数据摆拍。
    static func captureLive(path: String) {
        render(PanelController.shared.snapshotView(), to: path)
    }

    /// 设置窗口的离线渲染。page: 0 引擎 / 1 快捷键 / 2 通用 / 3 关于
    static func captureSettings(dark: Bool, path: String, page: Int = 0) {
        if dark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        // 临时灌样例值看真实排版，渲染完原样还回去，不污染用户配置
        let defaults = UserDefaults.standard
        let savedBase = defaults.string(forKey: PrefKey.baseURL)
        let savedKey = defaults.string(forKey: PrefKey.apiKey)
        let savedModel = defaults.string(forKey: PrefKey.model)
        defer {
            restore(defaults, PrefKey.baseURL, savedBase)
            restore(defaults, PrefKey.apiKey, savedKey)
            restore(defaults, PrefKey.model, savedModel)
        }

        defaults.set("https://openrouter.ai/api/v1", forKey: PrefKey.baseURL)
        defaults.set("sk-or-v1-xxxxxxxxxxxxxxxx", forKey: PrefKey.apiKey)
        defaults.set("google/gemma-4-26b-a4b-it:free", forKey: PrefKey.model)

        SettingsWindow.shared.debugSelect(page: page)
        guard let view = SettingsWindow.shared.debugContentView() else { return }
        SettingsWindow.shared.debugSelect(page: page)
        render(view, to: path, fillBackground: true)
    }

    /// 模型浏览窗口的离线渲染：用一组带状态的假数据看排版
    static func captureModels(dark: Bool, path: String) {
        if dark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        let samples: [ModelEntry] = [
            ModelEntry(id: "google/gemma-4-26b-a4b-it:free", name: "Google: Gemma 4 26B A4B (free)",
                       contextLength: 262144, promptPricePerM: 0, completionPricePerM: 0, supportsTools: true),
            ModelEntry(id: "nvidia/nemotron-3.5-lightning:free", name: "NVIDIA: Nemotron 3.5 Lightning (free)",
                       contextLength: 1000000, promptPricePerM: 0, completionPricePerM: 0, supportsTools: true),
            ModelEntry(id: "xingchen-agi/xing4.0-29b-a4b:free", name: "Xingchen: Xing 4.0 29B A4B (free)",
                       contextLength: 262144, promptPricePerM: 0, completionPricePerM: 0, supportsTools: false),
            ModelEntry(id: "thinkingmachines/inkling-small:free", name: "Thinking Machines: Inkling Small (free)",
                       contextLength: 1000000, promptPricePerM: 0, completionPricePerM: 0, supportsTools: true),
            ModelEntry(id: "openai/gpt-4o-mini", name: "OpenAI: GPT-4o mini",
                       contextLength: 128000, promptPricePerM: 0.15, completionPricePerM: 0.6, supportsTools: true),
            ModelEntry(id: "anthropic/claude-sonnet-4", name: "Anthropic: Claude Sonnet 4",
                       contextLength: 200000, promptPricePerM: 3, completionPricePerM: 15, supportsTools: true),
        ]

        let outcomes: [String: ProbeOutcome] = [
            "google/gemma-4-26b-a4b-it:free": ProbeOutcome(status: .ok, latencyMs: 412, note: "正常返回文本"),
            "nvidia/nemotron-3.5-lightning:free": ProbeOutcome(status: .ok, latencyMs: 268, note: "正常返回文本"),
            "xingchen-agi/xing4.0-29b-a4b:free": ProbeOutcome(status: .risky, latencyMs: 731, note: "只返回推理过程"),
            "thinkingmachines/inkling-small:free": ProbeOutcome(status: .rateLimited, latencyMs: 96, note: "触发限流"),
            "openai/gpt-4o-mini": ProbeOutcome(status: .unauthorized, latencyMs: 88, note: "Key 无权访问"),
            "anthropic/claude-sonnet-4": ProbeOutcome(status: .ok, latencyMs: 640, note: "正常返回文本"),
        ]

        let window = ModelBrowserWindow.shared
        window.debugPrepare(baseURL: ModelCatalog.openRouterBase, samples: samples, outcomes: outcomes)
        guard let view = window.debugContentView() else { return }
        render(view, to: path, fillBackground: true)
    }

    /// 注册向导的离线渲染
    static func captureSignup(step: Int, dark: Bool, path: String) {
        if dark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        let wizard = SignupWizard.shared
        wizard.debugShow(step: step,
                         key: step == 0 ? "" : "sk-or-v1-4f8c2a9e7b1d6c3f5a0e9d8b7c6a5f4e",
                         status: step == 1 ? "Key 有效 · 免费层 · 已用 $0.0000" : "",
                         detail: step == 2 ? """
                         服务商：OpenRouter（推荐，有免费额度）
                         额度：免费层 · 已用 $0.0000
                         限流 20 次 / 10s
                         模型列表已就绪，下一步可以直接挑一个。
                         """ : "")
        guard let view = wizard.debugContentView() else { return }
        render(view, to: path, fillBackground: true)
    }

    /// 截图遮罩的离线渲染：拿一张图当"冻结画面"，摆一个选区看挖洞/放大镜的排版。
    /// 不需要屏幕录制权限，正好用来在没有权限的机器上验证绘制。
    static func captureScreenshotOverlay(imagePath: String, path: String) {
        guard let image = NSImage(contentsOfFile: imagePath)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("读图失败: \(imagePath)")
            return
        }
        let size = NSSize(width: 735, height: 478)
        let view = ScreenshotView(frame: NSRect(origin: .zero, size: size), image: image)
        view.debugSetSelection(NSRect(x: 120, y: 180, width: 380, height: 200))
        render(view, to: path, fillBackground: true)
    }

    /// 截图缩略图窗的离线渲染：拿一张图当「刚截完的结果」，看排版和按钮。
    /// 完全走视图离屏绘制，不需要屏幕录制权限。
    static func captureResult(imagePath: String, dark: Bool, path: String) {
        if dark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        guard let image = NSImage(contentsOfFile: imagePath)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("读图失败: \(imagePath)")
            return
        }
        let thumb = CaptureResultPanel.thumbSize(for: image)
        let size = CaptureResultPanel.windowSize(thumb: thumb)
        let panel = CaptureResultPanel(size: size, thumb: thumb)
        panel.setImage(image)
        guard let view = panel.contentView else {
            print("内容视图缺失")
            return
        }
        view.frame = NSRect(origin: .zero, size: size)
        render(view, to: path, fillBackground: true)
    }

    private static func restore(_ defaults: UserDefaults, _ key: String, _ value: String?) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// 剪贴板历史小窗的离线渲染。用假数据，不碰真实剪贴板。
    static func captureHistory(dark: Bool, path: String) {
        if dark {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }

        let now = Date()
        let texts: [String] = [
            "https://github.com/yikox/peek",
            "swift build -c release --disable-sandbox",
            "剪贴板历史要支持键盘导航：↑↓ 选、⏎ 复制、1-9 直选",
            "The quick brown fox jumps over the lazy dog. It predicts your next edit.",
            "git log --oneline -5 --decorate",
            "screencapture -x -t png /tmp/shot.png",
            "这段文字稍微长一点，用来验证单行截断之后不会把右侧的时间挤掉，也不会在末尾糊成一团。",
            "make -j8",
            "NSPasteboard.changeCount 是不会回退的整数，只能在轮询里比大小",
            "curl -s https://api.github.com/repos/yikox/peek/releases/latest",
        ]
        let items = texts.enumerated().map { index, text in
            ClipboardHistory.Item(text: text, at: now.addingTimeInterval(Double(-index) * 317))
        }

        let size = ClipboardListView.windowSize(count: items.count)
        let view = ClipboardListView(items: items, frame: NSRect(origin: .zero, size: size))
        render(view, to: path, fillBackground: true)
    }

    /// 把任意视图渲染成 PNG（不做样式注入，原样导出）
    static func captureView(_ view: NSView, to path: String) {
        render(view, to: path, fillBackground: true)
    }

    private static func render(_ view: NSView, to path: String, fillBackground: Bool = false) {
        // 离屏渲染不经过窗口，外观不会自动继承 NSApp，得显式挂上
        if let appearance = NSApp.appearance {
            view.appearance = appearance
        }

        view.layoutSubtreeIfNeeded()
        // 给 TextKit 一次排版机会
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        view.display()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("bitmap 创建失败")
            return
        }

        // 窗口类界面要补一层窗口底色，否则透明区域在 PNG 里是纯白，
        // 暗色模式下深色控件会直接消失。
        if fillBackground {
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: view.bounds.size).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }

        view.cacheDisplay(in: view.bounds, to: rep)

        guard let data = rep.representation(using: .png, properties: [:]) else {
            print("PNG 编码失败")
            return
        }
        let url = URL(fileURLWithPath: path)
        do {
            try data.write(to: url)
            print("snapshot ok: \(path)  \(Int(view.bounds.width))x\(Int(view.bounds.height)) @\(rep.pixelsWide)x\(rep.pixelsHigh)")
        } catch {
            print("写入失败: \(error)")
        }
    }
}
