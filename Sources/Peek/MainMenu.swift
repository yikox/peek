import AppKit

/// 主菜单。
///
/// 为什么必须有：AppKit 的 ⌘V / ⌘C / ⌘A / ⌘Z 不是文本控件自己处理的，
/// 而是 `NSApplication` 在 sendEvent 里交给 mainMenu 做 key equivalent 匹配，
/// 命中后再沿响应链发给 `paste:` / `copy:` 等 action。
/// 纯代码启动的 app 不设 mainMenu，这些快捷键就全部无从触发 ——
/// 表现就是「输入框能打字，但按 ⌘V 毫无反应」。
///
/// 菜单项 target 全部留 nil，让 action 走响应链到当前的 firstResponder。
/// 本 app 是 accessory（无 Dock 图标、不显示菜单栏），但 key equivalent 依然生效。
enum MainMenu {

    static func install() {
        let main = NSMenu()

        main.addItem(appMenuItem())
        main.addItem(editMenuItem())

        NSApp.mainMenu = main
    }

    // MARK: - 应用菜单

    private static func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        let name = ProcessInfo.processInfo.processName
        menu.addItem(withTitle: "关于 \(name)",
                     action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())

        let hide = menu.addItem(withTitle: "隐藏 \(name)",
                                action: #selector(NSApplication.hide(_:)),
                                keyEquivalent: "h")
        hide.keyEquivalentModifierMask = [.command]

        let hideOthers = menu.addItem(withTitle: "隐藏其他",
                                      action: #selector(NSApplication.hideOtherApplications(_:)),
                                      keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]

        menu.addItem(withTitle: "显示全部",
                     action: #selector(NSApplication.unhideAllApplications(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 \(name)",
                     action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - 编辑菜单（粘贴能力就在这里）

    private static func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "编辑")

        menu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]

        menu.addItem(.separator())
        menu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")

        let pastePlain = menu.addItem(withTitle: "粘贴并匹配样式",
                                      action: #selector(NSTextView.pasteAsPlainText(_:)),
                                      keyEquivalent: "v")
        pastePlain.keyEquivalentModifierMask = [.command, .option, .shift]

        menu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        item.submenu = menu
        return item
    }
}

// MARK: - 兜底

/// 编辑类快捷键的窗口层处理。
///
/// 有些场景 mainMenu 的 key equivalent 不会走到（非激活浮窗、窗口层级特殊、
/// 或系统把事件直接投给了窗口）。这里在窗口层面再兜一次，只认编辑类快捷键。
enum EditingShortcuts {

    /// 返回 true 表示已处理。未命中返回 false，交回 super 继续。
    static func handle(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.modifierFlags.contains(.command),
              let chars = event.charactersIgnoringModifiers?.lowercased() else {
            return false
        }
        let action: Selector?
        switch chars {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSText.selectAll(_:))
        default: action = nil
        }
        guard let action else { return false }

        // 显式指定本窗口的 firstResponder，而不是传 nil 让 NSApp 去找 keyWindow。
        // 两者在正常使用时等价，但 keyWindow 为 nil 时 nil-target 会落空，
        // 直接把目标钉在当前输入焦点上更不容易失效。
        let target = window.firstResponder ?? window.contentView
        return NSApp.sendAction(action, to: target, from: nil)
    }
}

final class EditingWindow: NSPanel {

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return EditingShortcuts.handle(event, in: self)
    }
}
