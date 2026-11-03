import AppKit

/// 高度测量专用 TextKit 栈。
/// 复用同一组对象、只 measure 不渲染 —— 每次翻译不新建 TextKit 对象树。
enum TextMetrics {

    private static let storage = NSTextStorage()
    private static let layoutManager = NSLayoutManager()
    private static let container: NSTextContainer = {
        let c = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        c.lineFragmentPadding = 0
        c.widthTracksTextView = false
        layoutManager.addTextContainer(c)
        storage.addLayoutManager(layoutManager)
        return c
    }()

    /// 返回给定宽度下渲染该属性串所需的高度。
    static func height(of attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        guard width > 0, attributed.length > 0 else { return 0 }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(attributed)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        return ceil(used.height)
    }

    /// 纯文本按指定字体估算高度（用于查询区自增高场景）。
    static func height(of text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let para = NSMutableParagraphStyle()
        para.lineHeightMultiple = 1.2
        let attr = NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: para])
        return height(of: attr, width: width)
    }
}
