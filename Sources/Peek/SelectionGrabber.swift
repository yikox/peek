import AppKit
import ApplicationServices

/// 划词取词：剪贴板 + 模拟 ⌘C。
///
/// 相比原版有几处改动：
/// 1. 不预先清空剪贴板 —— 用户原有内容不被破坏，改用 changeCount 增量判断。
/// 2. 轮询 changeCount 而非固定睡 100ms —— 通常 10~40ms 就能返回。
/// 3. 热键触发时 ⌥ 往往还压着，立刻发 ⌘C 会被前台应用当成 ⌘⌥C：
///    先等修饰键抬起（最多 250ms），再发。
/// 4. ⌘C 发两次 —— 部分应用（Electron / 终端）首次合成按键会被丢弃。
enum SelectionGrabber {

    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// 弹系统授权引导。返回当前是否已授权。
    @discardableResult
    static func requestPermission() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// 从剪贴板直接取文本（不需要任何权限）。⌥V 的兜底路径用这个。
    static func clipboardText() -> String? {
        let pasteboard = NSPasteboard.general
        guard let raw = pasteboard.string(forType: .string) else {
            Log.info("剪贴板: 没有文本内容（types=\(pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "-")）")
            return nil
        }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        Log.info("剪贴板: 取到 \(cleaned.count) 字（changeCount=\(pasteboard.changeCount)）")
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 取当前选中文本。取不到（无选中 / 无权限）返回 nil。
    static func grab() -> String? {
        guard AXIsProcessTrusted() else {
            Log.info("取词: 无辅助功能权限，放弃（前台 \(frontAppName())）")
            return nil
        }

        // 先走 AX 直读：不动剪贴板、不依赖前台应用是否响应合成按键，最快也最干净。
        if let text = axSelectedText() {
            Log.info("取词: AX 直读成功 \(text.count) 字（前台 \(frontAppName())）")
            return text
        }

        return grabViaCopy()
    }

    /// 辅助功能 API 直接读选区。比模拟 ⌘C 干净，但浏览器 / Electron 首次可能返回空。
    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let focusErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard focusErr == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            Log.info("取词: AX 取不到焦点元素（err=\(focusErr.rawValue)）")
            return nil
        }
        let element = focusedRef as! AXUIElement

        var textRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &textRef) == .success,
           let raw = textRef as? String {
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { return cleaned }
        }

        // 退一步：拿选区范围，再按范围取字符串（部分应用只实现了这对参数化属性）
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID() else {
            return nil
        }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length > 0 else { return nil }

        var outRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            rangeRef as CFTypeRef,
            &outRef
        ) == .success, let out = outRef as? String else { return nil }

        let cleaned = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// 兜底：模拟 ⌘C 读剪贴板
    private static func grabViaCopy() -> String? {
        let pasteboard = NSPasteboard.general
        let baseline = pasteboard.changeCount

        // 发两轮 ⌘C：第一轮唤醒，第二轮兜底。
        // 有些应用（Electron、部分终端、Safari 阅读器）会吞掉第一发合成按键。
        for attempt in 1...2 {
            waitModifiersUp()
            let start = Date()
            postCommandC()

            let deadline = start.addingTimeInterval(attempt == 1 ? 0.16 : 0.22)
            while pasteboard.changeCount == baseline, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.004))
            }

            if pasteboard.changeCount == baseline {
                Log.info("取词: 第 \(attempt) 次 ⌘C 无响应（\(Int(-start.timeIntervalSinceNow * 1000))ms，前台 \(frontAppName())）")
                continue
            }

            let raw = pasteboard.string(forType: .string) ?? ""
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Int(-start.timeIntervalSinceNow * 1000)
            if cleaned.isEmpty {
                Log.info("取词: 剪贴板变了但没有文本（可能是图片等非文本内容）")
                return nil
            }
            Log.info("取词: 成功 \(cleaned.count) 字（\(elapsed)ms，第 \(attempt) 次）")
            return cleaned
        }

        Log.info("取词: 两次 ⌘C 都没拿到内容 —— 可能没选中文字，或前台应用不接受合成按键")
        return nil
    }

    private static func frontAppName() -> String {
        let front = NSWorkspace.shared.frontmostApplication
        return front?.localizedName ?? front?.bundleIdentifier ?? "?"
    }

    /// 等物理 ⌥ / ⌘ 抬起，否则 ⌘C 会被前台应用读成 ⌘⌥C。
    private static func waitModifiersUp() {
        let deadline = Date().addingTimeInterval(0.25)
        while Date() < deadline {
            let optionDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(KeyCode.option))
            let commandDown = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(KeyCode.command))
            if !optionDown && !commandDown { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(KeyCode.c)
        guard
            let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        // down/up 之间留 12ms：合成太快时部分应用只收到 keyDown、不触发 copy:
        RunLoop.current.run(until: Date().addingTimeInterval(0.012))
        up.post(tap: .cghidEventTap)
    }
}
