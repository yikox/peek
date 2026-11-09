import AppKit

/// 区域右上角的浮动复制按钮。
///
/// 面板只有 280pt 宽，按钮必须小到不打断阅读：
/// 常态 55% 不透明，鼠标移上去才实心，点完短暂变成对勾再退回去。
/// 只负责「画 + 触发回调」，复制什么由持有者决定。
final class CopyBadge: NSButton {

    /// 点中时调用
    var onCopy: (() -> Void)?

    private var hovering = false
    private var hoverArea: NSTrackingArea?
    private var restoreWork: DispatchWorkItem?

    private static let side: CGFloat = 20
    /// 0.55 试过一次，暗色下 secondary 本身就偏暗，再乘一遍看着像禁用状态
    private static let idleAlpha: CGFloat = 0.7

    init(toolTip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: CopyBadge.side, height: CopyBadge.side))
        self.toolTip = toolTip
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageOnly
        focusRingType = .none
        setSymbol("doc.on.doc")
        alphaValue = CopyBadge.idleAlpha
        target = self
        action = #selector(fire)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        // .activeAlways：面板是 nonactivatingPanel，窗口没激活时也要能收 hover
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        applyStyle()
    }

    private func applyStyle() {
        alphaValue = hovering ? 1 : CopyBadge.idleAlpha
        contentTintColor = hovering ? Theme.accent : Theme.secondary
    }

    // MARK: - 点击

    @objc private func fire() {
        onCopy?()
        flashConfirmed()
    }

    /// 换成对勾停 0.9 秒。没有这个反馈，点完界面一点变化都没有，
    /// 用户不知道到底复制成功没。
    private func flashConfirmed() {
        restoreWork?.cancel()
        setSymbol("checkmark")
        contentTintColor = Theme.accent
        alphaValue = 1

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setSymbol("doc.on.doc")
            self.applyStyle()
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func setSymbol(_ name: String) {
        image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
    }
}
