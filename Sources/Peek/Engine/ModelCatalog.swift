import Foundation

/// 从 /models 端点拿到的一条模型记录。
/// 字段全部做可选处理：OpenAI 官方只给 id，OpenRouter 才给价格和模态。
struct ModelEntry: Equatable {
    let id: String
    let name: String
    let contextLength: Int
    let promptPricePerM: Double?      // $ / 1M input tokens，nil = 该端点不公开价格
    let completionPricePerM: Double?
    let supportsTools: Bool

    var isFree: Bool {
        guard let p = promptPricePerM, let c = completionPricePerM else { return false }
        return p == 0 && c == 0
    }

    /// 价格未知时返回 nil，UI 用它决定是否显示价格列
    var priceLabel: String? {
        guard let p = promptPricePerM, let c = completionPricePerM else { return nil }
        if p == 0 && c == 0 { return "免费" }
        if p < 0.01 && c < 0.01 {
            return String(format: "$%.3f/$%.3f", p, c)
        }
        return String(format: "$%.2f/$%.2f", p, c)
    }

    var contextLabel: String {
        guard contextLength > 0 else { return "—" }
        if contextLength >= 1_000_000 {
            let millions = Double(contextLength) / 1_000_000
            // 1M 和 1.05M 都保留可读性，超过 10M 就不显示小数了
            return millions >= 10
                ? "\(Int(millions))M"
                : String(format: "%.1fM", millions).replacingOccurrences(of: ".0M", with: "M")
        }
        if contextLength >= 1000 {
            return "\(contextLength / 1000)K"
        }
        return "\(contextLength)"
    }

    var provider: String {
        id.split(separator: "/").first.map(String.init) ?? id
    }

    var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// 列表主标题：OpenRouter 的 name 可读性最好，其余退回短 id
    var title: String {
        if name != id, !name.isEmpty { return name }
        return shortName
    }
}

enum CatalogError: LocalizedError {
    case badBaseURL(String)
    case network(String)
    case http(Int, String)
    case parse(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .badBaseURL(let b): return "Base URL 不合法：\(b)"
        case .network(let m): return "网络请求失败：\(m)"
        case .http(let code, let body):
            let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return "HTTP \(code)\(detail.isEmpty ? "" : "：" + String(detail.prefix(140)))"
        case .parse(let m): return "响应格式无法解析：\(m)"
        case .empty: return "该端点没有返回任何模型"
        }
    }
}

/// 通用 OpenAI 兼容模型目录。
/// 判定「能不能用来翻译」刻意不靠命名，而是靠价格字段 + 输出模态；
/// 命名只用来排除 embedding / 语音 / 图像 / 审核这几类确定不做对话的模型。
enum ModelCatalog {

    static let openRouterBase = "https://openrouter.ai/api/v1"

    static func isOpenRouter(_ baseURL: String) -> Bool {
        baseURL.lowercased().contains("openrouter.ai")
    }

    static func modelsURL(from baseURL: String) -> URL? {
        var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("/") { s.removeLast() }
        // 用户可能把 /chat/completions 整条粘进来
        if s.hasSuffix("/chat/completions") {
            s = String(s.dropLast("/chat/completions".count))
        }
        return URL(string: s + "/models")
    }

    static func fetch(baseURL: String, apiKey: String?) async throws -> [ModelEntry] {
        guard let url = modelsURL(from: baseURL) else {
            throw CatalogError.badBaseURL(baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        attachOpenRouterHeaders(&request, url: url)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CatalogError.network(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CatalogError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        let models = try parse(data)
        guard !models.isEmpty else { throw CatalogError.empty }
        return models
    }

    static func parse(_ data: Data) throws -> [ModelEntry] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CatalogError.parse("不是 JSON 对象")
        }

        // 标准是 {data:[...]}，少数网关直接给数组
        let list: [[String: Any]]
        if let l = root["data"] as? [[String: Any]] {
            list = l
        } else if let l = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            list = l
        } else {
            throw CatalogError.parse("找不到 data 数组")
        }

        var result: [ModelEntry] = []
        result.reserveCapacity(list.count)

        for raw in list {
            guard let id = raw["id"] as? String, !id.isEmpty else { continue }
            guard isChatCapable(id) else { continue }

            // 输出模态：只有 text 能翻译。Lyria 这类音频模型标价也是 0，必须排除。
            let arch = raw["architecture"] as? [String: Any] ?? [:]
            let outputs = arch["output_modalities"] as? [String] ?? ["text"]
            guard outputs.contains("text"),
                  !outputs.contains("audio"),
                  !outputs.contains("image"),
                  !outputs.contains("video") else { continue }

            let pricing = raw["pricing"] as? [String: Any] ?? [:]
            let prompt = pricePerMillion(pricing["prompt"])
            let completion = pricePerMillion(pricing["completion"])

            let params = raw["supported_parameters"] as? [String] ?? []

            result.append(ModelEntry(
                id: id,
                name: raw["name"] as? String ?? id,
                contextLength: raw["context_length"] as? Int
                    ?? raw["context_window"] as? Int
                    ?? raw["max_context_length"] as? Int
                    ?? 0,
                promptPricePerM: prompt,
                completionPricePerM: completion,
                supportsTools: params.contains("tools")
            ))
        }

        result.sort(by: rank)
        return result
    }

    /// 排序：免费优先 → 上下文大的优先 → 字母序稳定
    private static func rank(_ a: ModelEntry, _ b: ModelEntry) -> Bool {
        if a.isFree != b.isFree { return a.isFree }
        if a.contextLength != b.contextLength { return a.contextLength > b.contextLength }
        return a.id < b.id
    }

    /// OpenRouter 的 price 是「每 token 的美元」，展示时换算成每百万 token
    private static func pricePerMillion(_ raw: Any?) -> Double? {
        let value: Double?
        if let s = raw as? String {
            value = Double(s)
        } else if let d = raw as? Double {
            value = d
        } else if let n = raw as? NSNumber {
            value = n.doubleValue
        } else {
            value = nil
        }
        guard let v = value, v >= 0 else { return nil }
        return v * 1_000_000
    }

    /// 排除明确不做对话的类别。这是命名唯一被允许介入的地方。
    static func isChatCapable(_ id: String) -> Bool {
        let lower = id.lowercased()
        let banned = [
            "embedding", "-embed", "embed-", "embed_",
            "whisper", "tts-", "-tts", "text-to-speech",
            "dall-e", "gpt-image", "stable-diffusion", "sdxl", "flux-", "playground-v2",
            "moderation", "rerank", "bge-", "clip-", "lyria",
            "guard", "safety", "prompt-guard",
        ]
        return !banned.contains { lower.contains($0) }
    }

    static func attachOpenRouterHeaders(_ request: inout URLRequest, url: URL) {
        guard url.host?.contains("openrouter.ai") == true else { return }
        request.setValue("Peek", forHTTPHeaderField: "X-Title")
        request.setValue("https://github.com/peek", forHTTPHeaderField: "HTTP-Referer")
    }
}
