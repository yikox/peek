import AppKit

/// 查询输入框。
/// 自己接管 ⌘V/⌘A/⌘C/⌘Z —— 无菜单栏的 accessory app 里，标准命令不会自动到达这里。
/// Enter 提交、Shift+Enter 换行、Esc 关闭。
final class QueryTextView: NSTextView {

    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    private let placeholderLabel = NSTextField(labelWithString: "输入或粘贴要翻译的文字…")

    override func keyDown(with event: NSEvent) {
        let code = UInt32(event.keyCode)

        if code == KeyCode.escape {
            onCancel?()
            return
        }

        if code == KeyCode.enter || code == KeyCode.keypadEnter {
            if event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option) {
                insertNewline(nil)
            } else {
                onSubmit?()
            }
            return
        }

        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "v": paste(nil); return
            case "c": copy(nil); return
            case "x": cut(nil); return
            case "a": selectAll(nil); return
            case "z":
                if event.modifierFlags.contains(.shift) {
                    undoManager?.redo()
                } else {
                    undoManager?.undo()
                }
                return
            default: break
            }
        }

        super.keyDown(with: event)
    }

    // 粘贴时剥离富文本，避免把网页样式带进来
    override func paste(_ sender: Any?) {
        guard let str = NSPasteboard.general.string(forType: .string) else { return }
        insertText(str, replacementRange: selectedRange())
    }

    func configure() {
        isRichText = false
        allowsUndo = true
        font = Theme.bodyFont
        textColor = Theme.text
        insertionPointColor = Theme.accent
        drawsBackground = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        textContainerInset = NSSize(width: 12, height: 8)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false

        placeholderLabel.font = Theme.bodyFont
        placeholderLabel.textColor = Theme.secondary
        placeholderLabel.isEditable = false
        placeholderLabel.isBordered = false
        placeholderLabel.drawsBackground = false
        placeholderLabel.isHidden = !string.isEmpty
        addSubview(placeholderLabel)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textChanged),
            name: NSText.didChangeNotification,
            object: self
        )
    }

    @objc private func textChanged() {
        let empty = string.isEmpty
        if placeholderLabel.isHidden == empty {
            placeholderLabel.isHidden = !empty
        }
    }

    func layoutPlaceholder(bounds: NSRect) {
        placeholderLabel.sizeToFit()
        let h = placeholderLabel.frame.height
        placeholderLabel.frame = NSRect(x: textContainerInset.width,
                                        y: bounds.height - textContainerInset.height - h,
                                        width: bounds.width - textContainerInset.width * 2,
                                        height: h)
    }

    func setText(_ text: String) {
        string = text
        placeholderLabel.isHidden = !text.isEmpty
    }
}
