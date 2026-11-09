import AppKit

/// 结果区：单个 NSTextView + 属性字符串。
///
/// 这是对原版 `WordResultView` 最直接的修正 —— 原版每次翻译
/// removeFromSuperview 再逐个重建 NSTextField + Masonry 约束，
/// 一个词约 20 个视图、20 套约束。这里只做一次 setAttributedString，
/// 无论内容多长都只有一次布局、一次绘制。
final class ResultView: NSView, NSTextViewDelegate {

    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private var contentHeight: CGFloat = 0

    /// 右侧留给浮动复制按钮的宽度。
    /// 不收窄的话，长行会从按钮底下穿过去，半透明图标压着字很难读。
    var trailingInset: CGFloat = 0

    /// 点结果区里的「打开设置」时回调
    var onOpenSettings: (() -> Void)?

    /// 当前内容在给定宽度下需要的总高度（含内边距），由外部用来定窗口高
    private(set) var desiredHeight: CGFloat = Metrics.resultMinH

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    private func applyBackground() {
        var cg = Theme.resultBG.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = Theme.resultBG.cgColor
        }
        layer?.backgroundColor = cg
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = Metrics.radius
        layer?.masksToBounds = true
        applyBackground()

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]
        scrollView.frame = bounds
        addSubview(scrollView)

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.selectedTextAttributes = [
            .backgroundColor: Theme.accent.withAlphaComponent(0.25),
            .foregroundColor: Theme.text,
        ]
        textView.linkTextAttributes = [
            .foregroundColor: Theme.accent,
            .underlineStyle: 0,
        ]
        textView.delegate = self
        scrollView.documentView = textView
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? String, url == "peek://settings" {
            onOpenSettings?()
            return true
        }
        return false
    }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        let width = scrollView.contentSize.width
        let textWidth = max(0, width - textView.textContainerInset.width * 2 - trailingInset)
        if textView.frame.width != textWidth || textView.frame.height != max(contentHeight, bounds.height) {
            textView.frame = NSRect(x: 0,
                                    y: 0,
                                    width: textWidth,
                                    height: max(contentHeight, bounds.height))
        }
    }

    // MARK: - 对外

    /// 渲染并返回该内容所需的窗口内结果区高度。
    @discardableResult
    func render(_ attributed: NSAttributedString) -> CGFloat {
        let textWidth = max(0, Metrics.contentW - textView.textContainerInset.width * 2 - trailingInset)
        contentHeight = TextMetrics.height(of: attributed, width: textWidth)
            + textView.textContainerInset.height * 2
            + 2 // 余量，避免滚动条出现时闪一下

        textView.textStorage?.setAttributedString(attributed)

        desiredHeight = min(max(contentHeight, Metrics.resultMinH), Metrics.resultMaxH)
        needsLayout = true
        return desiredHeight
    }

    func plainText() -> String {
        textView.string
    }
}

// MARK: - 属性串构造

enum ResultBuilder {

    static func loading(_ text: String) -> NSAttributedString {
        let para = Theme.bodyParagraph()
        return NSAttributedString(string: text, attributes: [
            .font: Theme.bodyFont,
            .foregroundColor: Theme.secondary,
            .paragraphStyle: para,
        ])
    }

    static func error(_ message: String) -> NSAttributedString {
        let para = Theme.bodyParagraph()
        let m = NSMutableAttributedString(string: message, attributes: [
            .font: Theme.bodyFont,
            .foregroundColor: Theme.text,
            .paragraphStyle: para,
        ])
        m.append(NSAttributedString(string: "\n\n", attributes: [.font: Theme.smallFont]))
        m.append(NSAttributedString(string: "打开设置", attributes: [
            .font: Theme.smallFont,
            .foregroundColor: Theme.accent,
            .link: "peek://settings",
        ]))
        return m
    }

    static func output(_ o: TranslateOutput) -> NSAttributedString {
        let m = NSMutableAttributedString()

        let bodyPara = Theme.bodyParagraph()
        m.append(NSAttributedString(string: o.translation, attributes: [
            .font: Theme.bodyFont,
            .foregroundColor: Theme.text,
            .paragraphStyle: bodyPara,
        ]))

        if let phonetics = o.phonetics, !phonetics.isEmpty {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.15
            p.paragraphSpacingBefore = 5
            m.append(NSAttributedString(string: "\n" + phonetics, attributes: [
                .font: Theme.dictFont,
                .foregroundColor: Theme.secondary,
                .paragraphStyle: p,
            ]))
        }

        for (index, sense) in o.senses.enumerated() {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.2
            p.paragraphSpacingBefore = index == 0 ? 10 : 6
            p.headIndent = 22 // 释义换行后与首行文字对齐
            p.lineBreakMode = .byWordWrapping

            // 每个义项必须是独立段落，否则段间距不生效、会和上一行粘连
            m.append(NSAttributedString(string: "\n" + sense.pos, attributes: [
                .font: Theme.dictBold,
                .foregroundColor: Theme.secondary,
                .paragraphStyle: p,
            ]))
            m.append(NSAttributedString(string: "  " + sense.defs.joined(separator: "；"), attributes: [
                .font: Theme.dictFont,
                .foregroundColor: Theme.text,
                .paragraphStyle: p,
            ]))
        }

        if let note = o.note, !note.isEmpty {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.15
            p.paragraphSpacingBefore = 12
            m.append(NSAttributedString(string: "\n" + note, attributes: [
                .font: Theme.smallFont,
                .foregroundColor: Theme.secondary,
                .paragraphStyle: p,
            ]))
        }

        return m
    }
}
