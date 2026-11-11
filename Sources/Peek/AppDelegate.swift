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
        // PEEK_LAZY_PANEL=1 时跳过（只用于量「预热到底占多少」，不对外暴露）：
        // 实测 6 MB，见 README「三个硬指标」。
        if ProcessInfo.processInfo.environment["PEEK_LAZY_PANEL"] == nil {
            _ = PanelController.shared
        }

        statusItem = StatusItemController()

        registerHotKeys()
        promptInitialSetupIfNeeded()

        // 剪贴板历史：AppKit 没有变更通知，只能轮询 changeCount（0.4s，读一个整数）。
        // 记录被关掉时连轮询都不启动 —— 没有计时器就没有唤醒。
        if PrefKey.clipboardHistoryEnabled {
            ClipboardHistory.shared.start()
        } else {
            Log.info("剪贴板历史: 记录已关闭，不启动轮询")
        }

        // OCR 预热：Vision 冷启动要十几秒，启动后先在后台把模型拉起来。
        // 代价是模型常驻内存（实测 19 MB → 稳定 53 MB，加载瞬间峰值 84 MB），所以给一个开关。
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

        // 纯截图入口（外部触发/自动化验证用）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.screenshot"),
            object: nil,
            queue: .main
        ) { _ in
            Log.info("截图: 外部触发起始（纯截图）perm=\(ScreenCapture.hasPermission)")
            PanelController.shared.showScreenshot(.capture)
        }

        // OCR 自检：对磁盘上的图片跑一遍识别，结果写日志（不需要任何权限）
        // userInfo: ["path": ..., "mode": "translate"]
        // mode=translate 走的是缩略图窗「识别文字」那条链路：原文进输入框、译文进结果区
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestOCR"),
            object: nil,
            queue: .main
        ) { note in
            let path = (note.userInfo?["path"] as? String) ?? ""
            let wantsTranslate = (note.userInfo?["mode"] as? String) == "translate"
            Log.info("OCR 自检: 文件 \(path) 链路=\(wantsTranslate ? "识别+翻译" : "只识别")")

            if wantsTranslate {
                guard let image = NSImage(contentsOfFile: path)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                    Log.info("OCR 自检: 图片读不出来 \(path)")
                    return
                }
                PanelController.shared.recognizeScreenshot(image, mode: .translate)
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    let query = PanelController.shared.debugQueryText
                    let result = PanelController.shared.debugResultText
                    Log.info("面板自检: 输入框 \(query.count) 字「\(query.prefix(40))」 | 结果区 \(result.count) 字「\(result.prefix(60))」")
                }
                return
            }

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

        // 把当前面板原样导出成 PNG，用于验证真实链路跑完后的界面
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.snapshotPanel"),
            object: nil,
            queue: .main
        ) { note in
            let path = (note.userInfo?["path"] as? String) ?? "/tmp/peek-panel.png"
            Snapshot.captureLive(path: path)
            Log.info("面板快照: \(path)")
        }

        // 复制按钮自检：selftestCopy target=query|result。
        // 走 performClick，能把「按钮有没有连到回调」一起验证掉。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestCopy"),
            object: nil,
            queue: .main
        ) { note in
            let target = (note.userInfo?["target"] as? String) ?? "result"
            let got = PanelController.shared.debugClickCopyBadge(target)
            Log.info("复制自检[\(target)]: 剪贴板 → \(got.prefix(60))")
        }

        // 图钉自检：走真实按钮的 performClick，验证「点一下翻状态」这条链路
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestPin"),
            object: nil,
            queue: .main
        ) { _ in
            let c = PanelController.shared
            c.showInput()
            c.debugClickPin()
            let clickWorked = c.debugIsPinned
            let keptWhenPinned = c.debugOutsideClick()
            c.debugClickPin()
            let keptWhenFree = c.debugOutsideClick()
            Log.info("图钉自检: 点击翻转=\(clickWorked ? "ok" : "FAIL")；钉住时点外面→\(keptWhenPinned ? "仍显示" : "被收起")；未钉住时点外面→\(keptWhenFree ? "仍显示" : "被收起")")
        }

        // 外部触发：打开设置窗（自检 / 调试用，用来验证「关窗后有没有真的释放」）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.openSettings"),
            object: nil,
            queue: .main
        ) { _ in
            SettingsWindow.shared.show()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.closeSettings"),
            object: nil,
            queue: .main
        ) { _ in
            SettingsWindow.shared.debugClose()
        }

        // 外部触发：打开剪贴板历史窗（自检 / 调试用，等价于按 ⌥Z）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.showClipboardHistory"),
            object: nil,
            queue: .main
        ) { _ in
            ClipboardHistoryWindow.shared.toggle()
        }

        // 把当前历史窗导出成 PNG（真实数据，不是样板）
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.snapshotHistoryLive"),
            object: nil,
            queue: .main
        ) { note in
            let path = (note.userInfo?["path"] as? String) ?? "/tmp/peek-history.png"
            ClipboardHistoryWindow.shared.debugSnapshot(to: path)
        }

        // 自检：按索引选中一条，验证「写回剪贴板」这条链路
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestHistoryPick"),
            object: nil,
            queue: .main
        ) { note in
            let index = Int((note.userInfo?["index"] as? String) ?? "0") ?? 0
            let before = ClipboardHistory.shared.items.count
            ClipboardHistoryWindow.shared.debugPick(index: index)
            let text = NSPasteboard.general.string(forType: .string) ?? "<空>"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let after = ClipboardHistory.shared.items.count
                Log.info("历史选中自检: 剪贴板 → \(ClipboardHistory.preview(text)) | 条数 \(before) → \(after)\(before == after ? "（没有重复入库，ok）" : "（FAIL：自己写回的内容又被记了一遍）")")
            }
        }

        // 剪贴板历史自检：模拟一次外部复制 → 等一个轮询周期 → 读回。
        // 覆盖的是「轮询有没有抓到 + 写回有没有生效」这条完整链路。
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.peek.translator.selftestHistory"),
            object: nil,
            queue: .main
        ) { _ in
            let token = "Peek 剪贴板历史自检 \(Int(Date().timeIntervalSince1970))"
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(token, forType: .string)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                let history = ClipboardHistory.shared
                let caught = history.items.first?.text == token
                let total = history.items.count
                if caught {
                    history.copyToPasteboard(history.items[0])
                }
                let back = NSPasteboard.general.string(forType: .string) ?? "<空>"
                Log.info("剪贴板历史自检: 捕获=\(caught ? "ok" : "FAIL") 条数=\(total) 写回=\(back == token ? "ok" : "FAIL(\(back.prefix(24)))")")
                // 这条是测试注入的，别留在真实历史里
                history.debugRemove(item: token)
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

    /// 按当前配置注册全部全局热键。
    /// 键位不再是硬编码：每一次都从 HotKeyStore 读，用户在设置里改完即时生效。
    private func registerHotKeys() {
        var report: [String] = []
        var occupied: [String] = []

        for action in HotKeyAction.allCases {
            guard let combo = HotKeyStore.combo(for: action) else {
                report.append("\(action.title)=未设置")
                continue
            }
            let ok = HotKeyCenter.shared.register(keyCode: combo.keyCode,
                                                  carbonModifiers: combo.modifiers) {
                action.perform()
            }
            report.append("\(action.title)=\(combo.display)\(ok ? "" : "(FAIL)")")
            if !ok { occupied.append(combo.display) }
        }

        Log.info("热键: " + report.joined(separator: " "))
        if !occupied.isEmpty {
            Log.info("热键被占用：\(occupied.joined(separator: "、")) —— 可能与其他应用冲突（Raycast / 输入法 / 其他翻译工具），去设置里换一个组合键")
        }
    }

    /// 设置界面保存后调用：先全摘，再按新配置重来。
    /// 录制新键位期间也会先摘掉，否则按下的组合会被系统当全局热键吃掉。
    func reloadHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        registerHotKeys()
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
