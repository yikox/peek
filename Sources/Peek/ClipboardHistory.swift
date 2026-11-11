import AppKit

/// 最近剪贴板历史。
///
/// AppKit 没有剪贴板变更通知，只能轮询 `NSPasteboard.changeCount`。这个值是个整数，
/// 没变化时读它的成本可以忽略，变了才去取内容 —— 所以 0.4s 一次的间隔不会让进程空转，
/// 也不需要为此常驻后台线程。
///
/// 只收纯文本：图片和文件在「复制粘贴一段话」的场景里占比很低，而落盘体积不可控。
/// 带 `org.nspasteboard.ConcealedType` 标记的一律跳过 —— 那是密码管理器在声明
/// 「这是敏感内容，别记」。
final class ClipboardHistory {

    static let shared = ClipboardHistory()

    static let limit = 10

    struct Item: Codable, Equatable {
        let text: String
        var at: Date
    }

    private(set) var items: [Item] = []

    /// 条目发生变化（新增 / 清空）后回调，界面用它刷新
    var onChange: (() -> Void)?

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    /// 由本 App 写回剪贴板造成的变更，不能当成「用户复制了新东西」
    private var skipChangeCount = -1
    private let fileURL: URL
    /// 落盘专用（串行，保证写入顺序，且不占用主线程）
    private let ioQueue = DispatchQueue(label: "com.peek.clipboard.persist", qos: .utility)

    /// 单条上限：防止把一个几百兆的日志文件塞进历史
    private static let maxLength = 200_000
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peek", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("clipboard-history.json")
        load()
    }

    // MARK: - 监听

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        // .common 模式：面板 / 菜单跟踪期间 RunLoop 会切到别的模式，默认模式会让轮询停摆
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Log.info("剪贴板历史: 开始监听，已有 \(items.count) 条")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        Log.info("剪贴板历史: 停止监听")
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        if count == skipChangeCount {
            skipChangeCount = -1
            return
        }

        guard PrefKey.clipboardHistoryEnabled else { return }

        let types = pasteboard.types ?? []
        guard !types.contains(Self.concealedType), !types.contains(Self.transientType) else {
            Log.info("剪贴板历史: 跳过被标记为敏感 / 临时的一条")
            return
        }
        guard let text = pasteboard.string(forType: .string) else { return }
        ingest(text)
    }

    // MARK: - 写入历史

    /// 收一条文本。轮询和自检都走这里，保证入库规则只有一份。
    func ingest(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard text.count <= Self.maxLength else {
            Log.info("剪贴板历史: 内容过长（\(text.count) 字），跳过")
            return
        }
        // 连续复制同一段内容（比如反复点复制按钮）不该把历史刷成一堆重复项
        if items.first?.text == text { return }

        items.insert(Item(text: text, at: Date()), at: 0)
        if items.count > Self.limit {
            items.removeLast(items.count - Self.limit)
        }
        persist()
        Log.info("剪贴板历史: +1 → \(Self.preview(text))，共 \(items.count) 条")
        onChange?()
    }

    /// 把某一条重新放回剪贴板，下次 ⌘V 就能粘出来
    func copyToPasteboard(_ item: Item) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)
        // 这次变更由我们自己发起：不记进历史，也别让它把顺序搅乱
        skipChangeCount = pasteboard.changeCount
        lastChangeCount = pasteboard.changeCount
        Log.info("剪贴板历史: 写回剪贴板 \(item.text.count) 字")
    }

    func clear() {
        items.removeAll()
        persist()
        onChange?()
        Log.info("剪贴板历史: 已清空")
    }

    /// 自检用：把注入的那一条撤掉，别污染真实历史
    func debugRemove(item text: String) {
        items.removeAll { $0.text == text }
        persist()
        onChange?()
    }

    // MARK: - 落盘

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else { return }
        items = Array(decoded.prefix(Self.limit))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        let target = fileURL
        // 落盘丢到串行队列：入库发生在主线程（轮询回调 / 点历史条目），
        // 编码 + 写盘 + 改权限不该堵在 UI 上。串行队列保证写入顺序。
        ioQueue.async {
            guard (try? data.write(to: target, options: [.atomic])) != nil else { return }
            // 剪贴板里会有别人贴进来的东西，权限收到只有本人可读。
            // .atomic 每次都会换 inode，权限跟着回到默认值，所以必须重设一次。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                   ofItemAtPath: target.path)
        }
    }

    // MARK: - 展示辅助

    /// 单行摘要：换行压成符号，过长截断
    static func preview(_ text: String, limit: Int = 44) -> String {
        let flat = text
            .replacingOccurrences(of: "\r\n", with: " ⏎ ")
            .replacingOccurrences(of: "\n", with: " ⏎ ")
            .replacingOccurrences(of: "\t", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }
}
