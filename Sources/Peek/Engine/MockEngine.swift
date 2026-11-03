import Foundation

/// 离线占位引擎：不联网，用于验证 UI 三态与词典排版。
/// 也充当"新引擎照着抄"的模板。
final class MockEngine: TranslateEngine {

    let id = "mock"
    let displayName = "Mock（离线）"
    let requiresConfiguration = false

    func translate(_ text: String, from: Language, to: Language) async throws -> TranslateOutput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslateError.noText }

        // 模拟一点网络延迟，让"加载态"可见
        try? await Task.sleep(nanoseconds: 180_000_000)

        let src = from.code == "auto" ? "自动检测" : from.name

        return TranslateOutput(
            translation: "\(trimmed)",
            phonetics: "/ˈmɒk ˈɛndʒɪn/",
            senses: [
                Sense(pos: "n.", defs: ["占位译文，用于验证结果区排版", "配置真实引擎后此内容会被替换"]),
                Sense(pos: "adj.", defs: ["\(src) → \(to.name) 的模拟结果", "共 \(trimmed.count) 个字符"]),
            ],
            note: "当前使用 Mock 引擎，未发起任何网络请求。"
        )
    }
}
