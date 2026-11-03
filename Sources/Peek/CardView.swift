import AppKit

/// 圆角卡片容器。背景/描边在 appearance 变化时重新解析 —— 不订阅通知。
final class CardView: NSView {

    private let fill: NSColor
    private let bordered: Bool

    init(fill: NSColor, bordered: Bool = false, radius: CGFloat = Metrics.radius) {
        self.fill = fill
        self.bordered = bordered
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        layer?.backgroundColor = resolved(fill)
        if bordered {
            layer?.borderWidth = Theme.borderWidth
            layer?.borderColor = resolved(Theme.border)
        }
    }

    /// 动态 NSColor 必须在目标 appearance 下解析成 CGColor，
    /// 否则切到暗色时 CALayer 仍拿着亮色的值。
    private func resolved(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = color.cgColor
        }
        return cg
    }
}
