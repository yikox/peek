import AppKit
import Foundation

/// 把 OCR 交给**一次性的独立进程**：一次识别一个进程，出结果就退。
///
/// 为什么（2026-11-15 实测定论，推翻 11-14 那版「冷编译污染」的结论）：
/// - 同一个进程里连续跑识别**不会**坏 —— 实测连跑 5 次全成功，第 1 次 316ms、之后 ~100ms；
/// - 真正会坏的是「进程闲置一段时间之后」：日志里失败点全部落在保活 ping 的 20 分钟间隔上
///   （14:30 / 14:50 / 15:30 / 15:50 …），杀掉重启立刻恢复。底层 e5rt 的推理上下文
///   被系统回收后，在同一进程里建不回来，报 `CRImageReaderError 1`；
/// - 更糟的是失败之后的重启要 **13 秒**（系统刚经历过 e5rt 报错，得重新编译加载），
///   而全新进程在热态下只要 **236~248ms**。
///
/// 所以干脆不留常驻进程：每次识别 spawn 一个新进程，永远是「进程内第一次调用」，
/// 结构上就不可能踩到闲置失效。代价是每次多 ~130ms，换来永不报错、也没有保活定时器。
///
/// 冷编译（第一次调用要编译模型，实测 13~44 秒）仍然单独做一次，见 `--ocr-warmup`。
final class OCRBridge {

    static let shared = OCRBridge()

    enum BridgeError: LocalizedError {
        case encodeFailed
        case startFailed(String)
        case helperClosed
        case badReply(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .encodeFailed: return "图片编码失败"
            case .startFailed(let m): return "独立识别进程起不来：\(m)"
            case .helperClosed: return "独立识别进程断开了"
            case .badReply(let m): return "独立识别进程返回异常：\(m)"
            case .timeout: return "独立识别进程超时"
            }
        }
    }

    private let queue = DispatchQueue(label: "com.peek.ocr.bridge", qos: .userInitiated)
    /// 本次 App 运行里是否已经做过冷编译
    private var warmedThisRun = false
    /// 一次性进程正常 250ms 内出结果；冷启动（模型还没编译过）要给足余量
    private let timeout: TimeInterval = 30

    private init() {}

    /// 同步调用，调用方负责放在后台线程。
    func recognize(image: CGImage, enhance: OCR.Enhance) throws -> OCR.Result {
        try queue.sync {
            ensureWarmLocked()
            let path = try writePNG(image)
            defer { try? FileManager.default.removeItem(atPath: path) }
            do {
                return try runOnce(path: path, enhance: enhance)
            } catch OCR.OCRError.failed(let message) where message.contains("CRImageReader") {
                // 理论上不会走到这里（新进程不该坏）。真踩到了就再来一个进程 ——
                // 编译结果已经在系统里，重试是毫秒级的。
                Log.info("OCR bridge: 一次性进程报 CRImageReader，换新进程重试")
                return try runOnce(path: path, enhance: enhance)
            }
        }
    }

    /// 启动时在后台把冷编译做完，这样第一次截图不用等十几秒。
    func warmupInBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureWarmLocked()
            Log.info("OCR bridge: 冷编译就绪，后续识别走一次性进程")
        }
    }

    /// 睡眠唤醒后强制执行一次（模型页可能已被回收，编译结果也失效了）。
    func rewarm() {
        queue.async { [weak self] in
            guard let self else { return }
            self.warmedThisRun = true
            self.performWarmup(force: true)
        }
    }

    // MARK: - 内部

    /// 每个 App 生命周期里只做一次冷编译。
    private func ensureWarmLocked() {
        guard !warmedThisRun else { return }
        warmedThisRun = true
        performWarmup(force: false)
    }

    /// 冷编译：拉起 `--ocr-warmup`，等它自己跑完退出。
    ///
    /// 那个进程只做一次识别，编译结果落在系统里；此后每次新的 `--ocr-server`
    /// 进程都能在 250ms 量级内直接跑起来。
    private func performWarmup(force: Bool) {
        if !force, OCRWarmMarker.matchesThisBoot() {
            Log.info("OCR bridge: 本次开机已经编译过，跳过冷编译")
            return
        }
        let start = Date()
        let task = Process()
        task.executableURL = executableURL
        task.arguments = ["--ocr-warmup"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            Log.info("OCR bridge: 冷编译进程起不来（\(error.localizedDescription)）")
            return
        }
        let deadline = Date().addingTimeInterval(180)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
        }
        if task.isRunning {
            Log.info("OCR bridge: 冷编译超时，杀掉")
            task.terminate()
            task.waitUntilExit()
        } else {
            Log.info("OCR bridge: 冷编译进程完成 \(Int(-start.timeIntervalSinceNow * 1000))ms，退出码 \(task.terminationStatus)")
        }
    }

    private var executableURL: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }

    /// 起一个进程、问一次、收工。
    private func runOnce(path: String, enhance: OCR.Enhance) throws -> OCR.Result {
        // 用自己这个可执行文件，只是换个参数：同一个二进制，命令行模式，没有 AppKit 事件循环
        let task = Process()
        task.executableURL = executableURL
        task.arguments = ["--ocr-server"]
        let input = Pipe()
        let output = Pipe()
        task.standardInput = input
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            throw BridgeError.startFailed(error.localizedDescription)
        }
        defer { finish(task, input: input, output: output) }

        let request: [String: Any] = [
            "path": path,
            "enhance": enhance == .off ? "off" : (enhance == .force ? "force" : "auto")
        ]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
            throw BridgeError.encodeFailed
        }
        payload.append(0x0A)
        input.fileHandleForWriting.write(payload)

        // 看门狗：卡住不能无限等，直接杀掉
        let watchdog = DispatchWorkItem { [timeout] in
            Log.info("OCR bridge: 一次性进程超过 \(Int(timeout)) 秒，杀掉")
            if task.isRunning { task.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let started = Date()
        let line = try readLine(from: output.fileHandleForReading)
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw BridgeError.badReply(String(data: line.prefix(120), encoding: .utf8) ?? "")
        }
        guard (obj["ok"] as? Bool) == true else {
            throw OCR.OCRError.failed(obj["error"] as? String ?? "未知错误")
        }
        let lines = obj["lines"] as? [String] ?? []
        guard !lines.isEmpty else { throw OCR.OCRError.noText }
        let elapsed = obj["elapsed"] as? Int ?? Int(Date().timeIntervalSince(started) * 1000)
        Log.info("OCR bridge: 一次性进程识别成功 \(lines.count) 行 / \(elapsed)ms（总 \(Int(Date().timeIntervalSince(started) * 1000))ms）")
        return OCR.Result(lines: lines,
                          text: lines.joined(separator: "\n"),
                          paragraph: obj["paragraph"] as? String ?? lines.joined(separator: " "),
                          confidence: Float(obj["confidence"] as? Double ?? 0),
                          elapsed: elapsed,
                          variant: obj["variant"] as? String ?? "独立进程")
    }

    /// 收尾：关 stdin 让子进程读到 EOF 自己退，等一下就回收，不等就杀。
    private func finish(_ task: Process, input: Pipe, output: Pipe) {
        input.fileHandleForWriting.closeFile()
        output.fileHandleForReading.closeFile()
        let deadline = Date().addingTimeInterval(1.0)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if task.isRunning { task.terminate() }
        task.waitUntilExit()
    }

    /// 按行读。
    ///
    /// 必须用 POSIX read：`FileHandle.read(upToCount:)` 会阻塞到读满请求的字节数或 EOF，
    /// 对端不关管道就永远等不到响应（这个坑踩过）。
    private func readLine(from handle: FileHandle) throws -> Data {
        let fd = handle.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 65536)
        var buffer = Data()
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                return Data(buffer[buffer.startIndex..<index])
            }
            let got = Darwin.read(fd, &chunk, chunk.count)
            if got < 0 {
                if errno == EINTR { continue }
                throw BridgeError.helperClosed
            }
            if got == 0 { throw BridgeError.helperClosed }
            buffer.append(contentsOf: chunk[0..<got])
        }
    }

    private func writePNG(_ image: CGImage) throws -> String {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw BridgeError.encodeFailed
        }
        let path = NSTemporaryDirectory() + "peek-ocr-\(UUID().uuidString).png"
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}

/// 「本次开机已经冷编译过」的标记。
///
/// 编译结果跨进程共享，所以重启 App 没必要再花十几秒重来一遍。
/// 用开机时间当 key：关机重启后自动失效。
enum OCRWarmMarker {

    static var bootTime: Int {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return tv.tv_sec
    }

    private static var url: URL {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Peek", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("ocr-warmed.json")
    }

    /// 本次开机内是否已经编译过。
    static func matchesThisBoot() -> Bool {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let boot = obj["boot"] as? Int else { return false }
        return boot != 0 && boot == bootTime
    }

    static func write() {
        let object: [String: Any] = ["boot": bootTime, "at": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: url, options: [.atomic])
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
