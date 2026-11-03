import AppKit

/// 无边框非激活浮窗。
/// - .nonactivatingPanel：出现时不抢焦点、不切 Space、不触发激活动画，
///   同时保证 ⌘C 能打到"上一个 App"而不是自己 —— 取词的前提。
/// - animationBehavior = .none：抹掉系统默认的淡入。
final class FloatingPanel: NSPanel {

    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .modalPanel
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // 圆角交给内容视图的 layer，窗口本身不裁切，避免阴影被切掉
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    // borderless 默认不能成为 key，必须重写，否则输入框拿不到键盘
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // 无标题栏窗口不允许通过双击/拖拽进入缩放
    override func zoom(_ sender: Any?) {}

    // 非激活面板拿不到主菜单分发时，⌘V/⌘C/⌘A 会失效，这里兜住
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        return EditingShortcuts.handle(event, in: self)
    }
}
