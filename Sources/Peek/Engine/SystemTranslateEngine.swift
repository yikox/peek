import Foundation
import NaturalLanguage
import SwiftUI
#if canImport(Translation)
import Translation
#endif

/// macOS 自带的翻译能力（Translation.framework）。
///
/// 特点：
/// - 完全离线，译文不出本机，不需要 API Key
/// - 语言包由系统管理，首次使用某个语言对时可能要给系统下载（几百 MB）
/// - 支持 21 种语言：中英日韩法德西俄葡意荷波土泰越印尼阿乌都在内
///
/// 关键实现约束（踩过才知道）：
/// `TranslationSession` 不能自己 `new` 出来用 —— 手动构造的 session
/// `canRequestDownloads == false`，语言包没装时只能得到 "Unable to Translate"。
/// 苹果只对 **SwiftUI `.translationTask` 回调里拿到的 session** 开放下载权限。
/// 所以这里挂了一个 1×1 的透明窗口承载一个空 SwiftUI 视图，靠它取 session。
/// 每个语言对一个 slot，互不干扰。
final class SystemTranslateEngine: TranslateEngine {

    let id = "system"
    let displayName = "离线翻译"
    let requiresConfiguration = false

    static var isAvailable: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }

    func translate(_ text: String, from: Language, to: Language) async throws -> TranslateOutput {
        guard #available(macOS 15.0, *) else {
            throw TranslateError.system("系统翻译需要 macOS 15 或更新版本，当前是 \(ProcessInfo.processInfo.operatingSystemVersionString)。")
        }
        let result = try await SystemTranslationBridge.shared.translate(text, from: from.code, to: to.code)
        var output = TranslateOutput(translation: result.text)
        // 原文本来就是目标语言时，界面要说明白，否则看着像"没翻译"
        if result.source == result.target {
            output.sameAsTarget = true
            output.note = "原文已是\(SystemTranslationBridge.label(result.source))，没有需要翻译的内容。可在语言栏换目标语言。"
        }
        return output
    }
}

// MARK: - 调度层

@available(macOS 15.0, *)
@MainActor
final class SystemTranslationBridge {

    static let shared = SystemTranslationBridge()

    private var slots: [String: TranslationSlot] = [:]

    func translate(_ text: String, from sourceCode: String, to targetCode: String)
        async throws -> (text: String, source: Locale.Language, target: Locale.Language) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranslateError.noText }

        let target = Self.language(targetCode)
        // auto：先确定源语言。后面 LanguageAvailability / installedSource 都需要确定的源语言
        let source: Locale.Language
        if sourceCode == "auto" {
            source = await Self.detectSource(trimmed, target: target)
            Log.info("系统翻译: 语种判定 → \(source.maximalIdentifier ?? "?")")
        } else {
            source = Self.language(sourceCode)
        }

        if source == target {
            Log.info("系统翻译: 源目标同语种，原文返回")
            return (trimmed, source, target)
        }

        // 语言包已装 → 直接建 session，不经过隐藏窗口（macOS 26+ 的公开通道）。
        // GUI 进程里 slot 通道曾经出现「准备失败：Unable to Translate」，直连绕开它。
        let status = await LanguageAvailability().status(from: source, to: target)
        Log.info("系统翻译: \(source.maximalIdentifier ?? "?")→\(target.maximalIdentifier ?? "?") 包状态 \(status == .installed ? "已装" : status == .supported ? "需下载" : "不支持")")
        if status == .installed, #available(macOS 26.0, *) {
            do {
                let session = TranslationSession(installedSource: source, target: target)
                let response = try await session.translate(trimmed)
                Log.info("系统翻译: 直连成功 → \(response.targetText.prefix(40))")
                return (response.targetText, source, target)
            } catch {
                Log.info("系统翻译: 直连失败 \(error.localizedDescription)，回退 slot 通道")
            }
        }

        // 未安装 / 直连失败 → slot 通道（语言包缺失时能拉起系统下载框）
        let key = "\(source.maximalIdentifier ?? "auto")>\(target.maximalIdentifier)"
        let slot = slot(for: source, target: target, key: key)

        do {
            let session = await slot.session()
            do {
                // 语言包没装时，这一步会拉起系统自己的下载确认框；已装则是空操作。
                try await session.prepareTranslation()
            } catch {
                slot.reset() // 会话可能已坏，丢弃，下次重取
                throw TranslateError.system(Self.downloadHint(error, source: source, target: target))
            }

            do {
                let response = try await session.translate(trimmed)
                return (response.targetText, source, target)
            } catch {
                slot.reset()
                throw TranslateError.system(Self.translateError(error))
            }
        } catch let error as TranslateError {
            throw error
        } catch {
            slot.reset()
            throw TranslateError.system("系统翻译失败：\(error.localizedDescription)")
        }
    }

    /// 语言包状态：给设置面板显示用
    func packState(from source: Locale.Language?, to targetCode: String) async -> String {
        let target = Self.language(targetCode)
        guard let source else { return "自动检测（首次使用需下载语言包）" }
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed: return "已安装"
        case .supported: return "需下载"
        default: return "不支持"
        }
    }

    /// 触发某个语言对的语言包准备。语言包没装时，系统会弹自己的下载确认框。
    func prepare(from sourceCode: String, to targetCode: String) async throws {
        let target = Self.language(targetCode)
        let source: Locale.Language? = sourceCode == "auto" ? nil : Self.language(sourceCode)
        let key = "\(source?.maximalIdentifier ?? "auto")>\(target.maximalIdentifier)"
        let slot = slot(for: source, target: target, key: key)
        let session = await slot.session()
        try await session.prepareTranslation()
    }

    private func slot(for source: Locale.Language?, target: Locale.Language, key: String) -> TranslationSlot {
        if let existing = slots[key] { return existing }
        let created = TranslationSlot(source: source, target: target)
        slots[key] = created
        return created
    }

    // MARK: 文案

    private static func downloadHint(_ error: Error, source: Locale.Language?, target: Locale.Language) -> String {
        if TranslationError.unsupportedLanguagePairing ~= error {
            return "系统翻译不支持 \(label(source)) → \(label(target)) 这一对语言。"
        }
        if #available(macOS 26.0, *), TranslationError.notInstalled ~= error {
            let pair = "\(label(source)) → \(label(target))"
            return "系统缺 \(pair) 的语言包。\n打开设置 →「翻译引擎 → 下载语言包…」即可安装（几百 MB，系统会弹确认框），装完完全离线可用。"
        }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return "系统没能判断原文语种，请在语言栏手动指定源语言。"
        }
        if TranslationError.internalError ~= error {
            return "系统翻译会话异常，已重置，请再试一次。反复出现时到「系统设置 → 通用 → 语言与地区 → 翻译语言」确认语言包状态。"
        }
        return "系统翻译准备失败：\(error.localizedDescription)"
    }

    private static func translateError(_ error: Error) -> String {
        if TranslationError.nothingToTranslate ~= error {
            return "这段内容没有需要翻译的部分。"
        }
        if TranslationError.unableToIdentifyLanguage ~= error {
            return "系统没能判断原文语种，请在语言栏手动指定源语言。"
        }
        return "系统翻译失败：\(error.localizedDescription)"
    }

    private static func language(_ code: String) -> Locale.Language {
        switch code {
        case "zh": return Locale.Language(identifier: "zh-Hans")
        case "zh-TW": return Locale.Language(identifier: "zh-Hant")
        default: return Locale.Language(identifier: code)
        }
    }

    nonisolated static func label(_ language: Locale.Language?) -> String {
        guard let language else { return "自动检测" }
        if let hit = Language.supported.first(where: { $0.code == language.maximalIdentifier }) {
            return hit.name
        }
        return language.languageCode?.identifier ?? "未知"
    }

    // MARK: - 语种判定

    /// NLLanguageRecognizer 对短文本极不可靠：`magic` 判成土耳其语、
    /// `Transformer 架构` 判成法语、`OpenAI` 判成葡萄牙语、`你好，世界` 判成繁体。
    /// 所以先按字符集给硬候选，再拼上统计候选，最后**优先选语言包已装的那个** ——
    /// 反正只有装了的包才翻得出来。
    static func detectSource(_ text: String, target: Locale.Language) async -> Locale.Language {
        // 1) 字符集能判的（中日韩）直接认，包没装也认 —— 让上层报"缺 XX 语言包"，而不是瞎猜成别国语言
        if let scripted = scriptCandidates(text) {
            // 原文和目标是同一门语言（简繁都算中文）→ 直接返回目标，交给上层自动换向
            if let head = scripted.first,
               head.languageCode?.identifier == target.languageCode?.identifier {
                Log.info("系统翻译: 字符集判定与目标同语种（\(head.maximalIdentifier ?? "?")）")
                return target
            }
            for candidate in scripted where candidate.languageCode != target.languageCode {
                if await LanguageAvailability().status(from: candidate, to: target) == .installed {
                    Log.info("系统翻译: 字符集候选 \(candidate.maximalIdentifier ?? "?")（包已装）")
                    return candidate
                }
            }
            let first = scripted.first { $0.languageCode != target.languageCode } ?? scripted[0]
            Log.info("系统翻译: 字符集候选 \(first.maximalIdentifier ?? "?")（包未装，仍采用）")
            return first
        }

        // 2) 拉丁/其它：先找"非目标且包已装"的统计候选
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var ranked = recognizer.languageHypotheses(withMaximum: 8)
            .sorted { $0.value > $1.value }
            .map { language($0.key.rawValue) }
        if containsLatinLetter(text) { ranked.append(language("en")) }

        var seen = Set<String>()
        let unique = ranked.filter { lang in
            let key = lang.maximalIdentifier ?? lang.languageCode?.identifier ?? "?"
            return seen.insert(key).inserted
        }

        for candidate in unique where candidate.languageCode != target.languageCode {
            if await LanguageAvailability().status(from: candidate, to: target) == .installed {
                Log.info("系统翻译: 统计候选 \(candidate.maximalIdentifier ?? "?")（包已装）")
                return candidate
            }
        }

        // 3) 都不行：原文可能本来就等于目标语言（英文翻英文），交给上层原样返回
        if unique.contains(where: { $0.languageCode == target.languageCode }) {
            Log.info("系统翻译: 判定为 \(target.maximalIdentifier ?? "?") 本身，无需翻译")
            return target
        }

        let fallback = unique.first ?? language("en")
        Log.info("系统翻译: 无已装包候选，暂用 \(fallback.maximalIdentifier ?? "?")")
        return fallback
    }

    /// 按字符集给硬候选。返回 nil 表示交给统计模型。
    private static func scriptCandidates(_ text: String) -> [Locale.Language]? {
        var han = 0, kana = 0, hangul = 0, total = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.punctuationCharacters.contains(scalar)
                || CharacterSet.symbols.contains(scalar) { continue }
            total += 1
            switch scalar.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            case 0x3040...0x309F, 0x30A0...0x30FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            default: break
            }
        }
        guard total > 0 else { return nil }
        // 日文靠假名占比判（日语文本里汉字往往更多）
        if kana * 10 >= total { return [language("ja")] }
        if hangul * 10 >= total { return [language("ko")] }
        // 汉字占 15% 以上就当中文（中英混排很常见，如 "Transformer 架构"）
        if han * 100 >= total * 15 {
            // 简繁都给，让"包已装"来决定：短句上 NLLanguageRecognizer 常把简体判成繁体
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(text)
            let hyps = recognizer.languageHypotheses(withMaximum: 4)
            let hansScore = hyps.first { $0.key.rawValue.hasPrefix("zh-Hans") }?.value ?? 0
            let hantScore = hyps.first { $0.key.rawValue.hasPrefix("zh-Hant") }?.value ?? 0
            let hans = language("zh")
            let hant = language("zh-TW")
            return hantScore > hansScore ? [hant, hans] : [hans, hant]
        }
        return nil
    }

    private static func containsLatinLetter(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
    }
}

// MARK: - 每个语言对一个 slot

/// 一个 slot 承载一个不可见的 SwiftUI 视图，用它的 `.translationTask` 换 session。
@available(macOS 15.0, *)
@MainActor
final class TranslationSlot: ObservableObject {

    @Published var config: TranslationSession.Configuration
    private(set) var acquired: TranslationSession?

    private var waiter: CheckedContinuation<TranslationSession, Never>?
    private var window: NSWindow?

    init(source: Locale.Language?, target: Locale.Language) {
        config = TranslationSession.Configuration(source: source, target: target)
    }

    func session() async -> TranslationSession {
        if let acquired { return acquired }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            ensureWindow()
            // 视图可能已经用初始 config 跑过一轮（那时 waiter 还没挂上），
            // invalidate 让 version 变化，强制再触发一次。
            config.invalidate()
        }
    }

    func receive(_ session: TranslationSession) {
        if acquired == nil { acquired = session }
        waiter?.resume(returning: session)
        waiter = nil
    }

    /// 会话坏了（比如首次取到时语言包还没装好）。丢弃，下次重取新 session。
    func reset() {
        acquired = nil
        waiter = nil
        config.invalidate()
    }

    private func ensureWindow() {
        guard window == nil else { return }
        let host = NSHostingView(rootView: SlotView(slot: self))
        host.frame = NSRect(x: 0, y: 0, width: 1, height: 1)

        let w = NSWindow(contentRect: NSRect(x: -300, y: -300, width: 1, height: 1),
                         styleMask: [.borderless],
                         backing: .buffered,
                         defer: false)
        w.contentView = host
        w.alphaValue = 0.02          // 不能设 0，完全透明时 SwiftUI 不跑 task
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.isReleasedWhenClosed = false
        w.level = .normal
        w.orderFront(nil)            // 必须在窗口层级里，task 才会触发
        window = w
    }
}

@available(macOS 15.0, *)
private struct SlotView: View {
    @ObservedObject var slot: TranslationSlot

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .translationTask(slot.config) { session in
                await slot.receive(session)
            }
    }
}
