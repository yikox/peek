import Foundation

/// Key 校验结果。OpenRouter 能拿到额度信息，其他端点只能确认「能调通」。
struct AccountInfo {
    var label: String?
    var usageUSD: Double?
    var limitUSD: Double?          // nil = 未设置上限
    var isFreeTier: Bool?
    var rateLimitText: String?
    var note: String?

    /// 给界面上的一句总结
    var summary: String {
        if let usage = usageUSD {
            if let limit = limitUSD {
                return String(format: "已用 $%.2f / 上限 $%.2f", usage, limit)
            }
            if let tier = isFreeTier, tier {
                return String(format: "免费层 · 已用 $%.4f", usage)
            }
            return String(format: "已用 $%.4f", usage)
        }
        return note ?? "Key 有效"
    }
}

enum KeyVerifyError: LocalizedError {
    case invalid(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let m): return m
        case .network(let m): return "网络请求失败：\(m)"
        }
    }
}

enum KeyVerifier {

    /// 校验 Key。
    /// - OpenRouter 走 GET /key，能顺带拿到额度与限流信息；
    /// - 其他兼容端点退化为「拿指定模型发一次最小请求」。
    static func verify(baseURL: String, apiKey: String, fallbackModel: String) async throws -> AccountInfo {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw KeyVerifyError.invalid("API Key 为空") }

        if ModelCatalog.isOpenRouter(baseURL) {
            return try await verifyOpenRouter(key: key)
        }

        guard !fallbackModel.isEmpty else {
            throw KeyVerifyError.invalid("该端点不支持 Key 查询，请先填一个模型名再验证。")
        }
        let outcome = await ModelProbe.probe(model: fallbackModel, baseURL: baseURL, apiKey: key)
        switch outcome.status {
        case .ok, .risky:
            return AccountInfo(note: "Key 有效，模型 \(fallbackModel) 可调用（\(outcome.latencyMs) ms）")
        case .unauthorized:
            throw KeyVerifyError.invalid(outcome.note.isEmpty ? "API Key 无效" : outcome.note)
        default:
            throw KeyVerifyError.invalid("Key 已发送，但调用失败：\(outcome.note)")
        }
    }

    private static func verifyOpenRouter(key: String) async throws -> AccountInfo {
        guard let url = URL(string: ModelCatalog.openRouterBase + "/key") else {
            throw KeyVerifyError.network("URL 构造失败")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        ModelCatalog.attachOpenRouterHeaders(&request, url: url)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw KeyVerifyError.network(error.localizedDescription)
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""

        guard (200..<300).contains(code) else {
            if code == 401 || code == 403 {
                throw KeyVerifyError.invalid("Key 无效。请确认复制完整（以 sk-or-v1- 开头）。")
            }
            let msg = parseMessage(text) ?? "HTTP \(code)"
            throw KeyVerifyError.invalid(msg)
        }

        return parseAccount(data) ?? AccountInfo(note: "Key 有效")
    }

    private static func parseAccount(_ data: Data) -> AccountInfo? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["data"] as? [String: Any]
        else { return nil }

        var info = AccountInfo()
        info.label = payload["label"] as? String
        info.usageUSD = number(payload["usage"])
        info.limitUSD = number(payload["limit"])
        info.isFreeTier = payload["is_free_tier"] as? Bool

        if let rl = payload["rate_limit"] as? [String: Any] {
            let requests = number(rl["requests"])
            let interval = rl["interval"] as? String
            if let requests, let interval {
                info.rateLimitText = "限流 \(Int(requests)) 次 / \(interval)"
            }
        }
        return info
    }

    private static func number(_ raw: Any?) -> Double? {
        if let d = raw as? Double { return d }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    private static func parseMessage(_ body: String) -> String? {
        guard
            let data = body.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let err = root["error"] as? [String: Any] {
            return err["message"] as? String
        }
        return root["message"] as? String
    }
}
