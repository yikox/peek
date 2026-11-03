import Foundation

/// 单个模型的可用性探测结果。
/// 探测方式是发一次真实的 chat 请求（max_tokens=1），而不是只看列表里的元数据 ——
/// 列表里有名字但没权限、没额度、已被下线的情况很常见。
struct ProbeOutcome: Equatable {
    enum Status: Equatable {
        case ok            // 能正常返回文本
        case risky         // 能调通，但只吐推理过程 / 输出异常，不适合直接当翻译用
        case rateLimited   // 429
        case unauthorized  // 401 / 403
        case noCredit      // 402
        case unavailable   // 404，模型不存在或未开放
        case notChat       // 400，明确不支持对话
        case failed        // 其他
    }

    let status: Status
    let latencyMs: Int
    let note: String

    var isUsable: Bool { status == .ok }

    var symbol: String {
        switch status {
        case .ok: return "✓"
        case .risky: return "!"
        case .rateLimited: return "!"
        case .unauthorized: return "✕"
        case .noCredit: return "✕"
        case .unavailable, .notChat, .failed: return "✕"
        }
    }

    var shortLabel: String {
        switch status {
        case .ok: return "✓ \(latencyMs) ms"
        case .risky: return "! 仅推理"
        case .rateLimited: return "! 限流"
        case .unauthorized: return "✕ 无权"
        case .noCredit: return "✕ 余额"
        case .unavailable: return "✕ 不可用"
        case .notChat: return "✕ 非对话"
        case .failed: return "✕ 失败"
        }
    }
}

enum ModelProbe {

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 25
        cfg.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: cfg)
    }()

    /// 探测用的最小请求：一句话 + 1 个输出 token，费用可忽略。
    static func probe(model: String, baseURL: String, apiKey: String) async -> ProbeOutcome {
        guard let url = chatURL(from: baseURL) else {
            return ProbeOutcome(status: .failed, latencyMs: 0, note: "Base URL 不合法")
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": "hi"]],
            "max_tokens": 1,
            "temperature": 0,
            "stream": false,
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        ModelCatalog.attachOpenRouterHeaders(&request, url: url)
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            return ProbeOutcome(status: .failed, latencyMs: 0, note: "请求体构造失败")
        }

        let started = Date()
        func elapsed() -> Int { Int(Date().timeIntervalSince(started) * 1000) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            return ProbeOutcome(status: .failed, latencyMs: elapsed(), note: error.localizedDescription)
        }

        let latency = elapsed()
        let text = String(data: data, encoding: .utf8) ?? ""
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        switch code {
        case 200..<300:
            return interpretSuccess(data: data, latency: latency)

        case 401, 403:
            // 没填 Key 时服务商回的是认证后端的内部措辞，对用户没有信息量
            let note = key.isEmpty ? "未填 API Key" : (apiError(text) ?? "API Key 无效或无权访问该模型")
            return ProbeOutcome(status: .unauthorized, latencyMs: latency, note: note)

        case 402:
            return ProbeOutcome(status: .noCredit, latencyMs: latency,
                                note: apiError(text) ?? "账户余额不足")

        case 404:
            return ProbeOutcome(status: .unavailable, latencyMs: latency,
                                note: apiError(text) ?? "模型不存在或未开放")

        case 429:
            return ProbeOutcome(status: .rateLimited, latencyMs: latency,
                                note: apiError(text) ?? "触发限流，稍后再试")

        case 400:
            let msg = apiError(text) ?? text
            let lower = msg.lowercased()
            let notChatHints = ["not a chat", "does not support", "unsupported", "not supported",
                                "invalid model", "is not available", "no endpoints found"]
            if notChatHints.contains(where: { lower.contains($0) }) {
                return ProbeOutcome(status: .notChat, latencyMs: latency, note: msg)
            }
            return ProbeOutcome(status: .failed, latencyMs: latency, note: msg)

        default:
            return ProbeOutcome(status: .failed, latencyMs: latency,
                                note: apiError(text) ?? "HTTP \(code)")
        }
    }

    /// 200 不代表能翻译：推理模型可能只给 reasoning，或返回空 content
    private static func interpretSuccess(data: Data, latency: Int) -> ProbeOutcome {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = root["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any]
        else {
            return ProbeOutcome(status: .risky, latencyMs: latency, note: "返回结构不像 chat 响应")
        }

        if let content = message["content"] as? String, !content.isEmpty {
            return ProbeOutcome(status: .ok, latencyMs: latency, note: "正常返回文本")
        }
        if let parts = message["content"] as? [[String: Any]],
           !parts.isEmpty,
           parts.contains(where: { ($0["text"] as? String)?.isEmpty == false }) {
            return ProbeOutcome(status: .ok, latencyMs: latency, note: "正常返回文本")
        }
        if message["reasoning_content"] != nil || message["reasoning"] != nil {
            return ProbeOutcome(status: .risky, latencyMs: latency,
                                note: "只返回推理过程，没有正文")
        }
        // max_tokens=1 时 content 为空但 finish_reason=length 是正常的
        if (choices.first?["finish_reason"] as? String) == "length" {
            return ProbeOutcome(status: .ok, latencyMs: latency, note: "正常（输出被 max_tokens 截断）")
        }
        return ProbeOutcome(status: .risky, latencyMs: latency, note: "返回内容为空")
    }

    private static func apiError(_ body: String) -> String? {
        guard
            let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(160))
        }
        if let err = root["error"] as? [String: Any] {
            if let m = err["message"] as? String { return m }
            if let m = err["code"] as? String { return m }
        }
        if let err = root["error"] as? String { return err }
        if let m = root["message"] as? String { return m }
        return nil
    }

    static func chatURL(from baseURL: String) -> URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/chat/completions") { return URL(string: s) }
        return URL(string: s + "/chat/completions")
    }
}
