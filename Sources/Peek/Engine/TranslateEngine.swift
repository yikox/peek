import Foundation

// MARK: - 数据模型

struct Sense {
    let pos: String       // 词性，如 "n." / "v."
    let defs: [String]    // 释义
}

struct TranslateOutput {
    var translation: String
    var phonetics: String?
    var senses: [Sense] = []
    var note: String?
    /// 引擎判定"原文本来就是目标语言"。面板据此自动换方向重翻一次
    var sameAsTarget: Bool = false

    var isDictionary: Bool { !senses.isEmpty }
}

enum TranslateError: LocalizedError {
    case noText
    case notConfigured
    case network(String)
    case http(Int, String)
    case badResponse(String)
    case system(String)

    var errorDescription: String? {
        switch self {
        case .noText:
            return "没有取到文字。选中文本后重试，或直接输入。"
        case .notConfigured:
            return "还没有配置翻译引擎。"
        case .network(let msg):
            return "网络请求失败：\(msg)"
        case .http(let code, let body):
            return "服务返回 HTTP \(code)。\(body.prefix(200))"
        case .badResponse(let msg):
            return "响应格式无法解析：\(msg.prefix(200))"
        case .system(let msg):
            return msg
        }
    }
}

// MARK: - 协议

protocol TranslateEngine: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var requiresConfiguration: Bool { get }

    func translate(_ text: String, from: Language, to: Language) async throws -> TranslateOutput
}

// MARK: - 契约

enum EngineRegistry {

    /// 新增引擎只需在这里登记一行。
    static func makeAll() -> [TranslateEngine] {
        var engines: [TranslateEngine] = []
        // 系统翻译放第一位：不需要任何配置，装了就能用（语言包由系统管）
        if SystemTranslateEngine.isAvailable {
            engines.append(SystemTranslateEngine())
        }
        engines.append(OpenAICompatEngine())
        engines.append(MockEngine())
        return engines
    }

    static func current(from engines: [TranslateEngine]) -> TranslateEngine {
        let saved = UserDefaults.standard.string(forKey: PrefKey.engineId)
        // 没保存过时默认仍是 OpenAI 兼容引擎：系统翻译要下语言包，
        // 不该在用户没选它的时候先弹一个下载框。
        return engines.first { $0.id == saved }
            ?? engines.first { $0.id == "openai" }
            ?? engines[0]
    }
}
