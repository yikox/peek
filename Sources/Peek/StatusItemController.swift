import AppKit
import ServiceManagement

final class StatusItemController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var launchAtLoginItem: NSMenuItem?
    private var prewarmOCRItem: NSMenuItem?
    /// 动作菜单项与其对应动作，菜单每次打开时按当前配置刷新快捷键
    private var actionItems: [(HotKeyAction, NSMenuItem)] = []

    override init() {
        super.init()

        configureButton()
        item.menu = buildMenu()
        Log.info("状态栏图标: visible=\(item.isVisible) length=\(item.length) button=\(item.button != nil)")
    }

    private func configureButton() {
        guard let button = item.button else {
            Log.info("状态栏图标: button 为 nil，菜单栏不可用")
            return
        }
        if let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Peek") {
            image.isTemplate = true
            button.image = image
            Log.info("状态栏图标: 使用 character.bubble")
        } else {
            // 符号缺失时宁可显示一个字，也不要留一个 0 宽的隐形位
            button.title = "译"
            Log.info("状态栏图标: SF Symbol 缺失，退化为文字")
        }
        button.toolTip = "Peek — ⌥F 输入翻译 / ⌥D 划词翻译"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        // 动作顺序按使用频率排，快捷键在 menuWillOpen 里按当前配置填
        let order: [HotKeyAction] = [.input, .selection, .capture,
                                     .screenshotTranslate,
                                     .clipboard, .togglePanel]
        for action in order {
            let menuItem = NSMenuItem(title: action.title,
                                      action: #selector(runAction(_:)),
                                      keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = action.rawValue
            menu.addItem(menuItem)
            actionItems.append((action, menuItem))
        }

        menu.addItem(.separator())
        menu.addItem(makeItem("设置…", action: #selector(openSettings), key: ",", modifiers: [.command]))
        menu.addItem(makeItem("检查辅助功能权限", action: #selector(checkPermission), key: "", modifiers: []))
        menu.addItem(makeItem("重置辅助功能授权…", action: #selector(resetAccessibility), key: "", modifiers: []))
        menu.addItem(makeItem("重启 Peek", action: #selector(restart), key: "", modifiers: []))
        let launchItem = makeItem("开机自动启动", action: #selector(toggleLaunchAtLogin), key: "", modifiers: [])
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        launchAtLoginItem = launchItem
        menu.addItem(launchItem)
        let prewarmItem = makeItem("启动时预热 OCR（内存 +20 MB 起）",
                                   action: #selector(togglePrewarmOCR), key: "", modifiers: [])
        prewarmItem.state = PrefKey.prewarmOCRDefault ? .on : .off
        prewarmOCRItem = prewarmItem
        menu.addItem(prewarmItem)
        menu.addItem(.separator())
        menu.addItem(makeItem("退出 Peek", action: #selector(quit), key: "q", modifiers: [.command]))
        return menu
    }

    private func makeItem(_ title: String, action: Selector, key: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.keyEquivalentModifierMask = modifiers
        menuItem.target = self
        return menuItem
    }

    /// 菜单一打开就按当前配置刷新：用户在设置里改完键位，这里立刻跟着变
    func menuWillOpen(_ menu: NSMenu) {
        for (action, menuItem) in actionItems {
            menuItem.title = action.title
            guard let combo = HotKeyStore.combo(for: action) else {
                menuItem.keyEquivalent = ""
                menuItem.keyEquivalentModifierMask = []
                continue
            }
            let key = combo.menuKeyEquivalent
            if key.isEmpty {
                // F1 / 方向键这类没法当 keyEquivalent，写进标题里
                menuItem.keyEquivalent = ""
                menuItem.keyEquivalentModifierMask = []
                menuItem.title = "\(action.title)　\(combo.display)"
            } else {
                menuItem.keyEquivalent = key
                menuItem.keyEquivalentModifierMask = combo.eventModifiers
            }
        }
        launchAtLoginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
        prewarmOCRItem?.state = PrefKey.prewarmOCRDefault ? .on : .off
    }

    // MARK: - 动作

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let action = HotKeyAction(rawValue: raw) else { return }
        action.perform()
    }

    /// 屏幕录制授权后必须重启进程才生效，给个一键重启。
    @objc private func restart() {
        let path = Bundle.main.bundlePath
        Log.info("重启: \(path)")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -a \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// 授权勾着却仍不生效时用：清掉 Peek 在 TCC 里的历史条目，重新走一次授权。
    /// （重装不同签名的版本会留下失效条目，界面看着是勾上的，实际不生效。）
    @objc private func resetAccessibility() {
        let alert = NSAlert()
        alert.messageText = "重置辅助功能授权？"
        alert.informativeText = """
        会执行 tccutil reset Accessibility com.peek.translator，
        清掉系统里 Peek 的历史授权记录，然后重新弹一次授权引导。

        适用于：系统设置里 Peek 看着已经勾上，划词却仍然取不到词。
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "重置并重新授权")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", "com.peek.translator"]
        do {
            try process.run()
            process.waitUntilExit()
            Log.info("辅助功能: tccutil reset 完成（status=\(process.terminationStatus)）")
        } catch {
            Log.info("辅助功能: tccutil reset 失败 \(error.localizedDescription)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            SelectionGrabber.requestPermission()
        }
    }

    @objc private func openSettings() {
        SettingsWindow.shared.show()
    }

    @objc private func checkPermission() {
        if SelectionGrabber.hasPermission {
            let alert = NSAlert()
            alert.messageText = "辅助功能权限已开启"
            alert.informativeText = "划词翻译可以正常工作。"
            alert.alertStyle = .informational
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        } else {
            SelectionGrabber.requestPermission()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("开机自启: 已关闭")
            } else {
                try service.register()
                Log.info("开机自启: 已开启")
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
        (launchAtLoginItem)?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Vision 的模型加载一次要十几秒，常驻后物理占用从 18 MB 涨到 83 MB。
    /// 想省内存就关掉；关掉后**首次截图会等模型加载**。
    @objc private func togglePrewarmOCR() {
        let next = !PrefKey.prewarmOCRDefault
        UserDefaults.standard.set(next, forKey: PrefKey.prewarmOCR)
        prewarmOCRItem?.state = next ? .on : .off
        Log.info("OCR 预热: \(next ? "开启" : "关闭")")

        if next {
            OCR.prewarm()
            return
        }

        // 模型已经加载进当前进程，主动卸载不可靠 —— 只有重启才真正还回去
        let alert = NSAlert()
        alert.messageText = "已关闭 OCR 预热"
        alert.informativeText = """
        Vision 的模型已经加载在当前进程里（实测物理占用 18 → 40 MB，
        真正跑过一次识别后到 83 MB），退出前不会释放。
        重启 Peek 后生效。现在重启吗？
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "现在重启")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            restart()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
