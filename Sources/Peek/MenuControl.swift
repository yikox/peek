import AppKit

/// 自绘下拉控件。
/// 不用 NSPopUpButton 的原因：它把箭头固定贴在自己右边缘，
/// 一行只有两三个字时会留下几十 pt 的空白，视觉上很散。
/// 这里改成 [文字][3pt][8pt 箭头] 紧排，整体宽度由外部给定。
final class MenuControl: NSView {

    struct Item {
        let title: String
        let code: String
    }

    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    private(set) var items: [Item] = []
    private(set) var selectedCode: String = ""

    var onSelect: ((Item) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)

        chevron.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        chevron.contentTintColor = Theme.secondary
        addSubview(chevron)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// 内容整体右对齐（用于目标语言，让它贴住右侧槽位边缘，视觉更平衡）
    var alignRight = false

    /// 文字颜色（引擎名用次要色，语言用正文色）
    var textColor: NSColor = Theme.text {
        didSet { refreshTitle() }
    }

    override func layout() {
        super.layout()
        let textHeight: CGFloat = 15
        // NSTextField 的 cell 左右各留 ~2pt，这里补足，否则尾部会被截断
        let textWidth = min(measuredWidth() + 8, bounds.width - 14)
        let total = textWidth + 2 + 8
        let startX = alignRight ? max(0, bounds.width - total) : 0
        label.frame = NSRect(x: startX, y: (bounds.height - textHeight) / 2,
                             width: textWidth, height: textHeight)
        chevron.frame = NSRect(x: startX + textWidth + 2, y: (bounds.height - 8) / 2,
                               width: 8, height: 8)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    func setItems(_ items: [Item], selected: String) {
        self.items = items
        if items.contains(where: { $0.code == selected }) {
            self.selectedCode = selected
        } else {
            self.selectedCode = items.first?.code ?? ""
        }
        refreshTitle()
    }

    func select(code: String) {
        guard items.contains(where: { $0.code == code }) else { return }
        selectedCode = code
        refreshTitle()
    }

    var selectedTitle: String {
        items.first { $0.code == selectedCode }?.title ?? ""
    }

    var selectedItem: Item? {
        items.first { $0.code == selectedCode }
    }

    private func refreshTitle() {
        label.attributedStringValue = NSAttributedString(string: selectedTitle, attributes: [
            .font: Theme.smallFont,
            .foregroundColor: textColor,
        ])
        needsLayout = true
    }

    private func measuredWidth() -> CGFloat {
        let attr = NSAttributedString(string: selectedTitle, attributes: [.font: Theme.smallFont])
        return ceil(attr.size().width)
    }

    override func mouseDown(with event: NSEvent) {
        guard !items.isEmpty else { return }

        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.code
            menuItem.state = (item.code == selectedCode) ? .on : .off
            menuItem.attributedTitle = NSAttributedString(string: item.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
            ])
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -6), in: self)
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String,
              let item = items.first(where: { $0.code == code }) else { return }
        selectedCode = code
        refreshTitle()
        onSelect?(item)
    }
}
