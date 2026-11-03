import AppKit

/// 配色全部用动态 NSColor，由 AppKit 在外观切换时自行重解析。
/// 对比原版：不订阅任何通知、不保存订阅、没有泄漏可能。
enum Theme {

    private static func dynamic(_ name: String,
                                dark: NSColor,
                                light: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark ? dark : light
        }
    }

    /// 窗口底（白卡与结果卡之间的缝隙色）—— 亮色纯白，暗色近黑
    static let panel = dynamic("panel",
                               dark: NSColor(white: 0.11, alpha: 1),
                               light: .white)

    /// 查询区
    static let queryBG = dynamic("queryBG",
                                 dark: NSColor(white: 0.15, alpha: 1),
                                 light: .white)

    /// 结果区
    static let resultBG = dynamic("resultBG",
                                  dark: NSColor(white: 0.17, alpha: 1),
                                  light: NSColor(white: 0.933, alpha: 1))

    /// 主文字
    static let text = dynamic("text",
                              dark: NSColor(white: 0.92, alpha: 1),
                              light: NSColor(white: 0.13, alpha: 1))

    /// 次要文字（词性、音标、提示）
    static let secondary = dynamic("secondary",
                                   dark: NSColor(white: 0.55, alpha: 1),
                                   light: NSColor(white: 0.60, alpha: 1))

    /// 唯一强调色
    static let accent = NSColor(srgbRed: 0.0, green: 0.478, blue: 1.0, alpha: 1)

    /// 亮色态不描边，靠系统阴影分界；暗色态补 1pt 15% 白边
    static let border = dynamic("border",
                                dark: NSColor(white: 1, alpha: 0.15),
                                light: NSColor(white: 1, alpha: 0))

    static let borderWidth: CGFloat = 0.5

    // MARK: - 字体

    static let bodyFont = NSFont.systemFont(ofSize: 14)
    static let bodyBold = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let smallFont = NSFont.systemFont(ofSize: 12)
    static let dictFont = NSFont.systemFont(ofSize: 13)
    static let dictBold = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// 正文段落样式：行高 ×1.2、段后 5、缩进 8/12
    static func bodyParagraph(spacingAfter: CGFloat = 5) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = 1.2
        p.paragraphSpacing = spacingAfter
        p.lineBreakMode = .byWordWrapping
        return p
    }
}
