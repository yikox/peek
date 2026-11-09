import AppKit
import Carbon.HIToolbox

/// Carbon RegisterEventHotKey 封装。
/// 关键点：走系统回调，不装 CGEventTap、不轮询 —— 空闲 CPU 为 0 的前提。
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var nextID: UInt32 = 1
    private var installed = false

    private init() {}

    @discardableResult
    func register(keyCode: UInt32, carbonModifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        installIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: OSType(0x424F424B), id: id) // 'BOBK'
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode,
                                         carbonModifiers,
                                         hotKeyID,
                                         GetApplicationEventTarget(),
                                         0,
                                         &ref)
        guard status == noErr, let ref else {
            NSLog("[Peek] 热键注册失败 keyCode=\(keyCode) status=\(status)")
            return false
        }
        handlers[id] = handler
        refs[id] = ref
        return true
    }

    fileprivate func fire(_ id: UInt32) {
        handlers[id]?()
    }

    /// 全部注销。设置界面录制新键位时必须先摘掉，
    /// 否则按下的组合键会被系统当成全局热键吃掉，录制控件根本收不到 keyDown。
    func unregisterAll() {
        for (_, ref) in refs {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        handlers.removeAll()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(),
                            bobKitHotKeyCallback,
                            1,
                            &spec,
                            nil,
                            nil)
    }
}

/// C 回调，不捕获任何上下文。
private func bobKitHotKeyCallback(_ next: EventHandlerCallRef?,
                                 _ event: EventRef?,
                                 _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let err = GetEventParameter(event,
                                EventParamName(kEventParamDirectObject),
                                EventParamType(typeEventHotKeyID),
                                nil,
                                MemoryLayout<EventHotKeyID>.size,
                                nil,
                                &hotKeyID)
    guard err == noErr else { return OSStatus(eventNotHandledErr) }

    let id = hotKeyID.id
    // 回调发生在主 runloop，但仍显式切到 main 以免在事件派发栈里直接改窗口
    DispatchQueue.main.async {
        HotKeyCenter.shared.fire(id)
    }
    return noErr
}

enum KeyCode {
    static let d: UInt32 = UInt32(kVK_ANSI_D)
    static let f: UInt32 = UInt32(kVK_ANSI_F)
    static let c: UInt32 = UInt32(kVK_ANSI_C)
    static let v: UInt32 = UInt32(kVK_ANSI_V)
    static let s: UInt32 = UInt32(kVK_ANSI_S)
    static let a: UInt32 = UInt32(kVK_ANSI_A)
    static let x: UInt32 = UInt32(kVK_ANSI_X)
    static let escape: UInt32 = UInt32(kVK_Escape)
    static let enter: UInt32 = UInt32(kVK_Return)
    static let keypadEnter: UInt32 = UInt32(kVK_ANSI_KeypadEnter)
    /// 注意：这两个是**虚拟键码**（CGKeyCode），不是修饰键掩码。
    /// 之前误写成 optionKey / cmdKey（0x0800 / 0x1000，修饰键掩码），
    /// 传给 CGEventSource.keyState 永远返回 false —— 于是"等 ⌥ 抬起"形同虚设，
    /// ⌘C 在 ⌥ 还压着时发出，被前台应用读成 ⌘⌥C，取词必然失败。
    static let option: UInt32 = UInt32(kVK_Option)
    static let command: UInt32 = UInt32(kVK_Command)
}
