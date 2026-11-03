import AppKit
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.reportLaunchContext()

        // bundle id 换过一次，先把旧域里的引擎配置搬过来（只跑一次）
        PrefsMigration.runIfNeeded()

        // 没有主菜单 = ⌘V/⌘C/⌘A 全部失效，必须在建窗口之前装好
        MainMenu.install()

        // 预热：启动时就把窗口与全部子视图建好并 orderOut。
        // 之后每次唤起只做字符串赋值 + orderFront，抹掉"第一次慢一拍"。
        _ = PanelController.shared

        statusItem = StatusItemController()

        registerHotKeys()
        promptInitialSetupIfNeeded()

        // OCR 预热：Vision 冷启动要十几秒，启动后先在后台把模型拉起来。
        // 代价是模型常驻内存（实测 phys_footprint 18 MB → 83 MB），所以给一个开关。
        if PrefKey.prewarmOCRDefault {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                OCR.prewarm()
            }
        } else {
            Log.info("OCR: 预热已关闭（首次截图会等模型加载）")
        }

        // 自检入口：launchctl setenv PEEK_SHOW_ON_LAUNCH 1 && open -a Peek
        if ProcessInfo.processInfo.environment["PEEK_SHOW_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                Log.info("自检: 请求显示面板")
                PanelController.shared.showInput()
            }
        }

        // 外部唤起：其他工具/脚本可以 post 这个通知来调起面板
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.showInput"),
            object: nil,
            queue: .main
        ) { _ in
            Log.info("收到外部唤起通知")
            PanelController.shared.showInput()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.hide"),
            object: nil,
            queue: .main
        ) { _ in
            PanelController.shared.hide()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.showClipboard"),
            object: nil,
            queue: .main
        ) { _ in
            PanelController.shared.showFromClipboard()
        }

        // 截图取词入口（外部触发/自动化验证用）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.screenshotTranslate"),
            object: nil,
            queue: .main
        ) { _ in
            Log.info("截图: 外部触发起始（翻译）perm=\(ScreenCapture.hasPermission)")
            PanelController.shared.showScreenshot(.translate)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.screenshotOCR"),
            object: nil,
            queue: .main
        ) { _ in
            Log.info("截图: 外部触发起始（OCR）perm=\(ScreenCapture.hasPermission)")
            PanelController.shared.showScreenshot(.ocr)
        }

        // OCR 自检：对磁盘上的图片跑一遍识别，结果写日志（不需要任何权限）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestOCR"),
            object: nil,
            queue: .main
        ) { note in
            let path = (note.userInfo?["path"] as? String) ?? ""
            Log.info("OCR 自检: 文件 \(path)")
            DispatchQueue.global(qos: .userInitiated).async {
                let outcome = Result {
                    guard let image = NSImage(contentsOfFile: path)?
                        .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        throw OCR.OCRError.imageUnreadable
                    }
                    return try OCR.recognize(image)
                }
                DispatchQueue.main.async {
                    switch outcome {
                    case .success(let result):
                        Log.info("OCR 自检: 成功 \(result.lines.count) 行 → \(result.text.replacingOccurrences(of: "\n", with: " / ").prefix(120))")
                        PanelController.shared.showScreenshotResult(result, mode: .ocr)
                    case .failure(let error):
                        Log.info("OCR 自检: 失败 \(error.localizedDescription)")
                    }
                }
            }
        }

        // 外部触发授权引导：弹系统的辅助功能授权框
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.requestAccessibility"),
            object: nil,
            queue: .main
        ) { _ in
            if SelectionGrabber.hasPermission {
                Log.info("辅助功能: 已授权，无需引导")
            } else {
                Log.info("辅助功能: 弹出系统授权引导")
                SelectionGrabber.requestPermission()
            }
        }

        // 划词链路自检：在真实 GUI 进程里走一遍取词，结果只写日志
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestGrab"),
            object: nil,
            queue: .main
        ) { _ in
            let front = NSWorkspace.shared.frontmostApplication
            Log.info("划词自检: trusted=\(SelectionGrabber.hasPermission) 前台=\(front?.localizedName ?? "?")")
            let text = SelectionGrabber.grab()
            Log.info("划词自检: 结果=\(text.map { "\($0.count) 字 → \($0.prefix(40))" } ?? "nil")")
        }

        // 走一遍 ⌥D 的完整入口（含无权限引导 + 授权轮询）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestSelection"),
            object: nil,
            queue: .main
        ) { _ in
            Log.info("划词入口自检: trusted=\(SelectionGrabber.hasPermission)")
            PanelController.shared.showWithSelection()
        }

        // 界面内翻译自检：在真实 GUI 进程里跑一次引擎，结果只写日志
        // userInfo: ["text": ..., "from": "auto"|"en"..., "to": "zh"|"en"..., "panel": "1"]
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftest"),
            object: nil,
            queue: .main
        ) { note in
            let info = note.userInfo ?? [:]
            let text = info["text"] as? String ?? "Hello, world."
            let fromCode = info["from"] as? String ?? "auto"
            let toCode = info["to"] as? String ?? "zh"

            // panel=1：走完整的面板路径（含自动换向、结果渲染）
            if (info["panel"] as? String) == "1" {
                Log.info("自检面板: 输入=\(text.prefix(30))")
                PanelController.shared.showInput()
                PanelController.shared.debugTranslate(text: text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    let shown = PanelController.shared.debugResultText
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .replacingOccurrences(of: "\n", with: " / ")
                    Log.info("自检面板: 结果=\(shown.prefix(120))")
                }
                return
            }

            let engine = EngineRegistry.current(from: EngineRegistry.makeAll())
            Log.info("自检翻译: 引擎=\(engine.id) \(fromCode)→\(toCode) 原文=\(text.prefix(30))")
            Task { @MainActor in
                do {
                    let out = try await engine.translate(text,
                                                         from: Language.named(fromCode),
                                                         to: Language.named(toCode))
                    Log.info("自检翻译: 成功 → \(out.translation.prefix(80))")
                } catch {
                    Log.info("自检翻译: 失败 → \(error.localizedDescription)")
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func registerHotKeys() {
        // Carbon 常量转 UInt32
        let option = UInt32(optionKey)
        let optionShift = UInt32(optionKey | shiftKey)

        let okF = HotKeyCenter.shared.register(keyCode: KeyCode.f, carbonModifiers: option) {
            PanelController.shared.showInput()
        }

        let okD = HotKeyCenter.shared.register(keyCode: KeyCode.d, carbonModifiers: option) {
            PanelController.shared.showWithSelection()
        }

        let okShiftD = HotKeyCenter.shared.register(keyCode: KeyCode.d, carbonModifiers: optionShift) {
            PanelController.shared.toggleInput()
        }

        // ⌥V：翻译剪贴板内容。不需要辅助功能权限，是划词取不到时的兜底。
        let okV = HotKeyCenter.shared.register(keyCode: KeyCode.v, carbonModifiers: option) {
            PanelController.shared.showFromClipboard()
        }

        // ⌥S / ⌥A：截图翻译 / 截图 OCR（需要屏幕录制权限）
        let okS = HotKeyCenter.shared.register(keyCode: KeyCode.s, carbonModifiers: option) {
            PanelController.shared.showScreenshot(.translate)
        }

        let okA = HotKeyCenter.shared.register(keyCode: KeyCode.a, carbonModifiers: option) {
            PanelController.shared.showScreenshot(.ocr)
        }

        Log.info("热键: ⌥F=\(okF ? "ok" : "FAIL") ⌥D=\(okD ? "ok" : "FAIL") ⌥⇧D=\(okShiftD ? "ok" : "FAIL") ⌥V=\(okV ? "ok" : "FAIL") ⌥S=\(okS ? "ok" : "FAIL") ⌥A=\(okA ? "ok" : "FAIL")")
        if !okF || !okD {
            Log.info("热键被占用：可能与其他应用冲突（Raycast / 输入法 / 其他翻译工具）")
        }
    }

    /// 首次启动且没配过引擎时，直接把设置面板推到面前。
    /// 辅助功能权限不在这里要 —— 等用户真的按了划词热键再要，少一次打扰。
    private func promptInitialSetupIfNeeded() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let defaults = UserDefaults.standard
            let base = defaults.string(forKey: PrefKey.baseURL) ?? ""
            let model = defaults.string(forKey: PrefKey.model) ?? ""
            let prompted = defaults.bool(forKey: "didShowOnboarding")
            guard base.isEmpty, model.isEmpty, !prompted else { return }
            defaults.set(true, forKey: "didShowOnboarding")
            SettingsWindow.shared.show()
        }
    }
}
