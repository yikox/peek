import AppKit
import Carbon.HIToolbox

/// 一个可以绑定全局快捷键的动作。
/// 新增动作只要在这里加一个 case，注册、设置界面、冲突检测都会自动跟上。
enum HotKeyAction: String, CaseIterable {

    case input
    case selection
    case togglePanel
    case clipboard
    case clipboardHistory
    case capture
    case screenshotTranslate

    var title: String {
        switch self {
        case .input:             return "输入翻译"
        case .selection:         return "划词翻译"
        case .togglePanel:       return "显示 / 隐藏面板"
        case .clipboard:         return "翻译剪贴板"
        case .clipboardHistory:  return "剪贴板历史"
        case .capture:           return "截图"
        case .screenshotTranslate: return "截图翻译"
        }
    }

    /// 设置界面第二行小字：说明这个动作做什么、需要什么权限
    var detail: String {
        switch self {
        case .input:             return "唤起浮窗，手动输入或粘贴"
        case .selection:         return "读取当前选中的文字，需要辅助功能权限"
        case .togglePanel:       return "面板开着就收起，关着就弹出"
        case .clipboard:         return "翻译剪贴板内容，不需要任何权限"
        case .clipboardHistory:  return "列出最近 10 条复制内容，点一条放回剪贴板"
        case .capture:           return "框选后弹缩略图，可复制 / 保存 / 识别"
        case .screenshotTranslate: return "框选 → OCR → 翻译，需要屏幕录制权限"
        }
    }

    var defaultCombo: HotKeyCombo {
        switch self {
        case .input:               return HotKeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(optionKey))
        case .selection:           return HotKeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey))
        case .togglePanel:         return HotKeyCombo(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(optionKey | shiftKey))
        case .clipboard:           return HotKeyCombo(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey))
        case .clipboardHistory:    return HotKeyCombo(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(optionKey))
        case .capture:             return HotKeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: UInt32(optionKey))
        case .screenshotTranslate: return HotKeyCombo(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(optionKey))
        }
    }

    /// 真正执行动作。热键回调和菜单项都从这里走，保证两条入口行为一致。
    func perform() {
        switch self {
        case .input:               PanelController.shared.showInput()
        case .selection:           PanelController.shared.showWithSelection()
        case .togglePanel:         PanelController.shared.toggleInput()
        case .clipboard:           PanelController.shared.showFromClipboard()
        case .clipboardHistory:    ClipboardHistoryWindow.shared.toggle()
        case .capture:             PanelController.shared.showScreenshot(.capture)
        case .screenshotTranslate: PanelController.shared.showScreenshot(.translate)
        }
    }

    /// 菜单栏里对应的 Selector（菜单项仍走 @objc 方法）
    var menuTitle: String { title }
}

/// 一组键码 + Carbon 修饰键掩码。
struct HotKeyCombo: Equatable {

    var keyCode: UInt32
    /// Carbon 掩码（cmdKey / optionKey / shiftKey / controlKey），不是 NSEvent 的位域
    var modifiers: UInt32

    /// 至少要有 ⌘ / ⌥ / ⌃ 之一。
    /// 只有 ⇧ 的组合等于"打大写字母"，绑上去既不安全也用不了。
    var isUsable: Bool {
        modifiers & UInt32(cmdKey | optionKey | controlKey) != 0
    }

    var display: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text + HotKeyCombo.keyName(keyCode)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        var result: UInt32 = 0
        if device.contains(.command) { result |= UInt32(cmdKey) }
        if device.contains(.option) { result |= UInt32(optionKey) }
        if device.contains(.control) { result |= UInt32(controlKey) }
        if device.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// 反向：Carbon 掩码 → 菜单项能用的修饰键
    var eventModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    /// 菜单项右侧那一位快捷键字符。
    /// NSMenuItem 只认单个字符，F1 / 方向键这类返回空，交给调用方把文字拼进标题。
    var menuKeyEquivalent: String {
        let name = HotKeyCombo.keyName(keyCode)
        guard name.count == 1 else { return "" }
        return name.lowercased()
    }

    /// 键码 → 可读键名。
    /// 普通键走 UCKeyTranslate（跟着当前输入法/键盘布局走），特殊键查表。
    static func keyName(_ keyCode: UInt32) -> String {
        if let special = specialKeyNames[keyCode] { return special }

        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "键\(keyCode)"
        }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data

        var name = "键\(keyCode)"
        data.withUnsafeBytes { buffer in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDisplay),
                                        0,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        chars.count,
                                        &length,
                                        &chars)
            if status == noErr, length > 0 {
                name = String(utf16CodeUnits: chars, count: length).uppercased()
            }
        }
        return name
    }

    private static let specialKeyNames: [UInt32: String] = [
        UInt32(kVK_Space): "空格",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_ANSI_KeypadEnter): "⌤",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]
}

/// 快捷键配置的读写。存 UserDefaults，键为动作的 rawValue。
enum HotKeyStore {

    private static let storageKey = "hotkeys.v1"

    /// 返回 nil 表示这个动作的快捷键被用户清除了（不注册）
    static func combo(for action: HotKeyAction) -> HotKeyCombo? {
        guard let entry = storedEntry(for: action) else { return action.defaultCombo }
        if entry["off"] == 1 { return nil }
        guard let keyCode = entry["keyCode"], let modifiers = entry["modifiers"] else {
            return action.defaultCombo
        }
        return HotKeyCombo(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    static func set(_ combo: HotKeyCombo?, for action: HotKeyAction) {
        var raw = UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]
        if let combo {
            raw[action.rawValue] = ["keyCode": Int(combo.keyCode),
                                    "modifiers": Int(combo.modifiers),
                                    "off": 0]
        } else {
            raw[action.rawValue] = ["keyCode": 0, "modifiers": 0, "off": 1]
        }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }

    static func reset(_ action: HotKeyAction) {
        var raw = UserDefaults.standard.dictionary(forKey: storageKey) ?? [:]
        raw.removeValue(forKey: action.rawValue)
        UserDefaults.standard.set(raw, forKey: storageKey)
    }

    static func resetAll() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// 这个组合键是不是已经被别的动作占用了
    static func conflict(of combo: HotKeyCombo, excluding action: HotKeyAction) -> HotKeyAction? {
        HotKeyAction.allCases.first { other in
            guard other != action, let current = self.combo(for: other) else { return false }
            return current == combo
        }
    }

    private static func storedEntry(for action: HotKeyAction) -> [String: Int]? {
        guard let raw = UserDefaults.standard.dictionary(forKey: storageKey),
              let entry = raw[action.rawValue] as? [String: Int] else { return nil }
        return entry
    }
}
