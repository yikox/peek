import Foundation

/// OpenAI 兼容的 Chat Completions 引擎。
/// 接内部网关 / vLLM / Ollama / One-API / 官方 API 都只需改 baseURL + model。
/// 响应解析刻意用 JSONSerialization 而非 Codable —— 各家网关对 content
/// 的表示（字符串 / 分段数组）并不统一，手写解析更容易做兼容。
final class OpenAICompatEngine: TranslateEngine {

    let id = "openai"
    let displayName = "OpenAI 兼容"
    let requiresConfiguration = true

    private var baseURL: String { UserDefaults.standard.string(forKey: PrefKey.baseURL) ?? "" }
    private var apiKey: String { UserDefaults.standard.string(forKey: PrefKey.apiKey) ?? "" }
    private var model: String { UserDefaults.standard.string(forKey: PrefKey.model) ?? "" }

    private var systemPrompt: String {
        let custom = UserDefaults.standard.string(forKey: PrefKey.systemPrompt) ?? ""
        if !custom.isEmpty { return custom }
        return "你是一个专业翻译引擎。把用户给出的文本翻译成目标语言。"
            + "只输出译文本身，不要解释、不要加引号、不要重复原文。"
            + "保留原文的换行与标点风格。"
    }

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 45
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: cfg)
    }()

    func translate(_ text: String, from: Language, to: Language) async throws -> TranslateOutput {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslateError.noText }

        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !model.isEmpty else { throw TranslateError.notConfigured }

        guard let url = Self.endpoint(from: base) else {
            throw TranslateError.network("baseURL 不合法：\(base)")
        }

        var instruction = "目标语言：\(to.name)（\(to.code)）。"
        if from.code != "auto" {
            instruction += "源语言：\(from.name)（\(from.code)）。"
        } else {
            instruction += "源语言请自动判断。"
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": instruction + "\n\n" + trimmed],
            ],
            "temperature": 0.2,
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        // OpenRouter 的可选统计头，用于区分应用来源（不影响计费）
        if url.host?.contains("openrouter.ai") == true {
            request.setValue("Peek", forHTTPHeaderField: "X-Title")
            request.setValue("https://github.com/peek", forHTTPHeaderField: "HTTP-Referer")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw TranslateError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let snippet = String(data: data, encoding: .utf8) ?? ""
            throw TranslateError.http(http.statusCode, snippet)
        }

        let content = try Self.extractContent(from: data)
        let cleaned = Self.stripFormatting(content)
        guard !cleaned.isEmpty else { throw TranslateError.badResponse("返回内容为空") }

        return TranslateOutput(translation: cleaned)
    }

    // MARK: - 工具

    private static func endpoint(from base: String) -> URL? {
        var s = base
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/chat/completions") {
            return URL(string: s)
        }
        return URL(string: s + "/chat/completions")
    }

    private static func extractContent(from data: Data) throws -> String {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            throw TranslateError.badResponse(String(data: data, encoding: .utf8) ?? "<binary>")
        }

        if let s = message["content"] as? String {
            return s
        }
        // 少数网关把 content 拆成分段数组
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        // 推理模型有时只吐 thinking 不给正文。这种情况宁可报错，
        // 也不能把思考过程当译文贴到结果区。
        if message["reasoning_content"] != nil || message["reasoning"] != nil {
            throw TranslateError.badResponse("模型只返回了推理过程，没有正文。换一个非推理模型再试。")
        }
        throw TranslateError.badResponse("没有 content 字段")
    }

    /// 模型偶尔会自作主张包一层代码块或引号，去掉一层外壳
    private static func stripFormatting(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)

        if t.hasPrefix("```") {
            if let firstNewline = t.firstIndex(of: "\n") {
                t = String(t[t.index(after: firstNewline)...])
            }
            if t.hasSuffix("```") {
                t.removeLast(3)
            }
            t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」")]
        for (open, close) in pairs where t.count >= 2 {
            if t.first == open, t.last == close {
                t.removeFirst()
                t.removeLast()
                return t.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return t
    }
}
