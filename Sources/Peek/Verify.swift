import AppKit
import Carbon.HIToolbox
import NaturalLanguage
import Translation

/// 无头自检里跨 Task 传值用的容器。
/// Task 闭包捕获 class 引用即可写回，避免用 inout 或全局可变状态。
final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

/// 无头自检：验证热键注册、面板显示、翻译链路、尺寸计算。
/// 用法: Peek --verify
enum Verify {

    static func run() {
        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            print(ok ? "  PASS  \(name) \(detail)" : "  FAIL  \(name) \(detail)")
            if !ok { failures += 1 }
        }

        print("Peek 自检")

        // 1. 窗口预热
        let controller = PanelController.shared
        let frame = controller.debugFrame
        check("面板预热", frame.width == Metrics.windowW,
              "size=\(Int(frame.width))x\(Int(frame.height))")

        // 2. 尺寸公式
        let expectedChrome = Metrics.margin + Metrics.topBarH + Metrics.gap
            + Metrics.whiteCardH + Metrics.gap + Metrics.margin
        check("固定区高度", Metrics.chromeH == expectedChrome,
              "chrome=\(Metrics.chromeH) 结果区min=\(Metrics.resultMinH)")
        check("窗口宽度", Metrics.windowW == 304, "W=\(Metrics.windowW)")

        // 3. 热键
        let option = UInt32(optionKey)
        let registered = HotKeyCenter.shared.register(keyCode: KeyCode.f, carbonModifiers: option) {}
        check("热键 ⌥F 注册", registered)

        // 4. 显示
        controller.showInput()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        check("面板显示", controller.debugIsVisible)

        // 5. 翻译链路（Mock 引擎走完整 async 路径）
        controller.debugUseMockEngine()
        controller.debugTranslate(text: "Hello, world.")
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        let result = controller.debugResultText
        check("翻译返回", result.count > 10, "len=\(result.count)")
        let preview = result.replacingOccurrences(of: "\n", with: " ⏎ ")
        print("        内容: \(preview.prefix(120))")

        let after = controller.debugFrame
        check("结果展开后高度变化", after.height >= frame.height,
              "\(Int(frame.height)) -> \(Int(after.height))")
        check("宽度未变", after.width == frame.width)

        // 6. 结果区不超过上限
        check("高度上限", after.height <= Metrics.windowH(resultH: Metrics.resultMaxH) + 1,
              "H=\(Int(after.height))")

        print(failures == 0 ? "\n全部通过" : "\n失败 \(failures) 项")
        exit(failures == 0 ? 0 : 1)
    }

    /// 检测模型目录（无头）：Peek --verify-catalog [baseURL]
    static func runCatalog(baseURL: String) {
        print("拉取模型目录 \(baseURL) …")
        let box = Box<[ModelEntry]>([])
        var failure: String?
        var done = false

        Task {
            do {
                box.value = try await ModelCatalog.fetch(baseURL: baseURL, apiKey: nil)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            done = true
        }

        waitUntil { done }

        if let failure {
            print("FAIL: \(failure)")
            exit(1)
        }
        guard done else {
            print("FAIL: 超时")
            exit(1)
        }

        let models = box.value
        let free = models.filter(\.isFree)
        print("共 \(models.count) 个可对话模型，其中免费 \(free.count) 个\n")
        print("  免费模型：")
        for model in free {
            let price = model.priceLabel ?? "—"
            print("  \(model.id.padding(toLength: 50, withPad: " ", startingAt: 0)) \(model.contextLabel.padding(toLength: 7, withPad: " ", startingAt: 0)) \(price)")
        }
        exit(0)
    }

    /// 探测真实可用性：Peek --verify-probe <baseURL> [apiKey] [数量]
    static func runProbe(baseURL: String, apiKey: String, limit: Int) {
        print("从 \(baseURL) 拉模型列表…")
        let box = Box<[ModelEntry]>([])
        var failure: String?
        var done = false

        Task {
            do {
                box.value = try await ModelCatalog.fetch(baseURL: baseURL, apiKey: apiKey.isEmpty ? nil : apiKey)
            } catch {
                failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            done = true
        }
        waitUntil { done }

        if let failure {
            print("FAIL: \(failure)")
            exit(1)
        }

        let targets = Array(box.value.prefix(limit))
        guard !targets.isEmpty else {
            print("列表为空")
            exit(1)
        }

        print("列表 \(box.value.count) 个，探测前 \(targets.count) 个…\n")
        let outcomes = Box<[String: ProbeOutcome]>([:])
        let finished = Box(false)

        Task {
            for model in targets {
                let outcome = await ModelProbe.probe(model: model.id, baseURL: baseURL, apiKey: apiKey)
                outcomes.value[model.id] = outcome
                let mark = outcome.isUsable ? "OK " : "-- "
                print("  \(mark)\(model.id.padding(toLength: 48, withPad: " ", startingAt: 0)) \(outcome.shortLabel.padding(toLength: 10, withPad: " ", startingAt: 0)) \(outcome.note)")
            }
            finished.value = true
        }
        waitUntil { finished.value }

        let usable = outcomes.value.values.filter(\.isUsable).count
        print("\n可用 \(usable) / \(targets.count)")
        exit(usable > 0 ? 0 : 1)
    }

    private static func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// 走真实 HTTP 的端到端检查：把 baseURL 指向本地假服务，验证请求/解析/渲染。
    static func runHTTP(baseURL: String) {        UserDefaults.standard.set(baseURL, forKey: PrefKey.baseURL)
        UserDefaults.standard.set("test-model", forKey: PrefKey.model)

        let controller = PanelController.shared
        controller.debugUseEngine(id: "openai")
        controller.showInput()
        controller.debugTranslate(text: "Character is destiny.")
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        let text = controller.debugResultText
        print(text)
        print("---")
        print("窗口高度: \(Int(controller.debugFrame.height))")
    }

    /// 验证 ⌘V 能真的把剪贴板内容送进 Key 输入框。
    ///
    /// 分两条路：
    ///   A. 真实按键入口：mainMenu 的 key equivalent（需要窗口是 key window）
    ///   B. 响应链：直接向 firstResponder 发 paste:（不依赖焦点，命令行也能测）
    /// CLI 启动的进程抢不到焦点，A 会退化成 B，所以两条都记下来。
    static func runPaste(logPath: String? = nil) {
        var log: [String] = []
        func emit(_ s: String) {
            print(s)
            log.append(s)
            // 被 LaunchServices 启动时 stdout 丢失，逐步落盘才能看到停在哪
            if let logPath {
                try? log.joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
            }
        }

        var failures = 0
        func check(_ name: String, _ ok: Bool, _ detail: String = "") {
            emit(ok ? "  PASS  \(name) \(detail)" : "  FAIL  \(name) \(detail)")
            if !ok { failures += 1 }
        }

        emit("粘贴链路自检")
        MainMenu.install()
        check("主菜单已安装", NSApp.mainMenu != nil)

        let allItems = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items) ?? []
        let pasteItem = allItems.first { $0.action == #selector(NSText.paste(_:)) }
        check("存在「粘贴」菜单项", pasteItem != nil,
              pasteItem.map { "key=\($0.keyEquivalent)" } ?? "未找到")
        check("粘贴绑定 ⌘V", pasteItem?.keyEquivalent == "v")

        let payload = "sk-or-v1-paste-test-9f3a2b"
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(payload, forType: .string)
        check("剪贴板已写入", NSPasteboard.general.string(forType: .string) == payload)

        let settings = SettingsWindow.shared
        settings.debugApiKey = ""
        settings.debugFocusKeyField()

        // 等窗口真正成为 key window（LaunchServices 启动时通常 < 0.5s）
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if NSApp.isActive, settings.debugWindow?.isKeyWindow == true { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        guard let window = settings.debugWindow, window.isVisible else {
            emit("  FAIL  设置窗口不可见")
            finish(log, failures + 1, logPath)
        }

        let active = NSApp.isActive && window.isKeyWindow
        emit("  · 环境：appActive=\(NSApp.isActive) isKey=\(window.isKeyWindow) " +
             "firstResponder=\(type(of: window.firstResponder ?? NSResponder()))")

        // A. 真实按键：sendEvent → mainMenu key equivalent → paste:
        settings.debugApiKey = ""
        settings.debugFocusKeyField()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        let keyEvent = NSEvent.keyEvent(with: .keyDown,
                                        location: .zero,
                                        modifierFlags: .command,
                                        timestamp: ProcessInfo.processInfo.systemUptime,
                                        windowNumber: window.windowNumber,
                                        context: nil,
                                        characters: "v",
                                        charactersIgnoringModifiers: "v",
                                        isARepeat: false,
                                        keyCode: 9)

        if active, let keyEvent {
            NSApp.sendEvent(keyEvent)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check("⌘V 经系统事件链进入输入框", settings.debugApiKey == payload,
                  "len=\(settings.debugApiKey.count)")
        } else {
            emit("  SKIP  ⌘V 真实按键（进程无激活权限，改由 B/C 覆盖同一路径）")
        }

        // B. 窗口层：NSWindow 在 sendEvent 里会先问 performKeyEquivalent，
        //    这条和真实按键走的是同一个入口，不依赖 keyWindow。
        settings.debugApiKey = ""
        settings.debugFocusKeyField()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let keyEvent {
            let handled = window.performKeyEquivalent(with: keyEvent)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check("窗口处理 ⌘V", handled)
            check("⌘V 内容进入输入框", settings.debugApiKey == payload,
                  "len=\(settings.debugApiKey.count)")
        }

        // C. 响应链底层：确认字段编辑器本身能吃 paste:
        settings.debugApiKey = ""
        settings.debugFocusKeyField()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        if let responder = window.firstResponder {
            let ok = NSApp.sendAction(#selector(NSText.paste(_:)), to: responder, from: nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            check("paste: 可送达 firstResponder", ok, "\(type(of: responder))")
            check("粘贴内容正确", settings.debugApiKey == payload,
                  "len=\(settings.debugApiKey.count)")
        } else {
            check("firstResponder 存在", false)
        }

        // D. 查询浮窗：非激活面板，主菜单分发最容易落空的地方
        let controller = PanelController.shared
        if let panelEvent = NSEvent.keyEvent(with: .keyDown,
                                             location: .zero,
                                             modifierFlags: .command,
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: 0,
                                             context: nil,
                                             characters: "v",
                                             charactersIgnoringModifiers: "v",
                                             isARepeat: false,
                                             keyCode: 9) {
            let outcome = controller.debugPasteIntoQuery(panelEvent)
            check("查询浮窗处理 ⌘V", outcome.handled)
            check("查询框收到粘贴内容", outcome.text == payload, "len=\(outcome.text.count)")
            controller.debugTranslate(text: "")
        }

        settings.debugApiKey = ""
        finish(log, failures, logPath)
    }

    /// 系统翻译自检：--verify-system [--download]
    ///
    /// 默认只查状态，不下载语言包（几百 MB，且会弹系统确认框）。
    static func runSystem(download: Bool) {
        print("系统翻译自检")
        print("  系统版本：\(ProcessInfo.processInfo.operatingSystemVersionString)")
        print("  引擎可见：\(SystemTranslateEngine.isAvailable)")
        print("  引擎列表：\(EngineRegistry.makeAll().map { "\($0.displayName)[\($0.id)]" }.joined(separator: " / "))")
        fflush(stdout)

        guard #available(macOS 15.0, *) else {
            print("  系统翻译需要 macOS 15+")
            exit(1)
        }
        runSystemInner(download: download)
    }

    @available(macOS 15.0, *)
    private static func runSystemInner(download: Bool) {
        Task { @MainActor in
            let available = LanguageAvailability()
            let languages = await available.supportedLanguages
            print("  支持语言 \(languages.count) 种：\(languages.compactMap { $0.languageCode?.identifier }.joined(separator: " "))")

            for (s, t) in [("en", "zh"), ("zh", "en"), ("ja", "zh"), ("en", "ja")] {
                let src = Locale.Language(identifier: s == "zh" ? "zh-Hans" : s)
                let dst = Locale.Language(identifier: t == "zh" ? "zh-Hans" : t)
                let status = await available.status(from: src, to: dst)
                let label: String
                switch status {
                case .installed: label = "已装"
                case .supported: label = "需下载"
                default: label = "不支持"
                }
                print("  \(s) → \(t)：\(label)")
            }

            let recognizer = NLLanguageRecognizer()
            recognizer.processString("Good morning, how are you doing today?")
            print("  语种识别：→ \(recognizer.dominantLanguage?.rawValue ?? "nil")")

            let enZh = await available.status(from: Locale.Language(identifier: "en"),
                                              to: Locale.Language(identifier: "zh-Hans"))
            if enZh == .installed {
                print("  引擎调用（en→zh 语言包已装）：")
                do {
                    let out = try await SystemTranslateEngine().translate("Hello, world.",
                                                                         from: Language.named("en"),
                                                                         to: Language.named("zh"))
                    print("    → \(out.translation)")
                } catch {
                    print("    → \(error.localizedDescription)")
                }
                print("  引擎调用（auto→zh，走语种识别 + 直连 session）：")
                do {
                    let out = try await SystemTranslateEngine().translate("Good morning, how are you doing today?",
                                                                         from: Language.named("auto"),
                                                                         to: Language.named("zh"))
                    print("    → \(out.translation)")
                } catch {
                    print("    → \(error.localizedDescription)")
                }
            } else {
                print("  引擎调用：跳过（en→zh 语言包未装，实际调用会弹系统下载框；加 --download 可触发）")
            }

            if download {
                print("  触发语言包准备（会弹系统确认框，需要点同意）…")
                do {
                    let result = try await SystemTranslationBridge.shared.translate(
                        "Good morning, how are you doing today?", from: "en", to: "zh")
                    print("    译文：\(result.text)")
                } catch {
                    print("    失败：\(error.localizedDescription)")
                }
            }

            fflush(stdout)
            exit(0)
        }

        RunLoop.current.run()
    }

    private static func finish(_ log: [String], _ failures: Int, _ logPath: String?) -> Never {
        let tail = failures == 0 ? "\n全部通过" : "\n失败 \(failures) 项"
        print(tail)
        let full = (log + [tail]).joined(separator: "\n")
        if let logPath {
            try? full.write(toFile: logPath, atomically: true, encoding: .utf8)
        }
        exit(failures == 0 ? 0 : 1)
    }
}
