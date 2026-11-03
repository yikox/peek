import Foundation

/// 全局尺寸常量。所有数字都从 12pt 栅格推导，改一处即可整体缩放。
enum Metrics {
    static let margin: CGFloat = 12       // 内容边距 / 栅格基准
    static let radius: CGFloat = 4        // 全应用唯一圆角
    static let gap: CGFloat = 10          // 卡片间距
    static let innerPad: CGFloat = 6      // 白卡内上下留白

    static let topBarH: CGFloat = 24
    static let queryH: CGFloat = 110
    static let serviceBarH: CGFloat = 24
    static let resultMinH: CGFloat = 116
    static let resultMaxH: CGFloat = 500

    /// 窗口宽度 = 12 + 280 + 12
    static let contentW: CGFloat = 280
    static var windowW: CGFloat { contentW + margin * 2 }

    /// 白卡高度
    static var whiteCardH: CGFloat { innerPad * 2 + queryH + 8 + serviceBarH }

    /// 除结果区之外的全部固定高度（含上下 margin）
    static var chromeH: CGFloat {
        margin + topBarH + gap + whiteCardH + gap + margin
    }

    static func windowH(resultH: CGFloat) -> CGFloat {
        chromeH + resultH
    }
}

enum PrefKey {
    static let engineId = "engineId"
    static let baseURL = "openai.baseURL"
    static let apiKey = "openai.apiKey"
    static let model = "openai.model"
    static let systemPrompt = "openai.systemPrompt"
    static let autoCopy = "autoCopy"
    static let hotkeyEnabled = "hotkeyEnabled"
    /// 启动时预热 OCR（Vision 模型常驻，物理占用 +约 65 MB）
    static let prewarmOCR = "prewarmOCR"

    /// 默认 true：没写过这个键时当作开启。UserDefaults.bool 默认是 false，不能直接用。
    static var prewarmOCRDefault: Bool {
        UserDefaults.standard.object(forKey: prewarmOCR) == nil
            ? true
            : UserDefaults.standard.bool(forKey: prewarmOCR)
    }
}

struct Language: Hashable {
    let code: String
    let name: String

    static let auto = Language(code: "auto", name: "自动检测")

    static let supported: [Language] = [
        .auto,
        Language(code: "zh", name: "简体中文"),
        Language(code: "zh-TW", name: "繁体中文"),
        Language(code: "en", name: "英语"),
        Language(code: "ja", name: "日语"),
        Language(code: "ko", name: "韩语"),
        Language(code: "fr", name: "法语"),
        Language(code: "de", name: "德语"),
        Language(code: "es", name: "西班牙语"),
        Language(code: "ru", name: "俄语"),
        Language(code: "pt", name: "葡萄牙语"),
        Language(code: "it", name: "意大利语"),
    ]

    /// 目标语言候选（不含自动检测）
    static var targets: [Language] { Array(supported.dropFirst()) }

    static func named(_ code: String) -> Language {
        supported.first { $0.code == code } ?? .auto
    }
}
