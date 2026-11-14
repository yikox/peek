import AppKit
import Foundation

/// 把 OCR 全部交给**独立进程**跑，GUI 主进程一次 Vision 都不碰。
///
/// 为什么（2026-11-14 实测定论）：
/// 冷编译那一次调用会把执行它的进程弄坏 —— 第一次调用还能出结果，之后同一个进程里
/// 所有识别都报 `TextRecognition.CRImageReaderError error 1`（底层 e5rt 建流失败），
/// 换设备 / 换像素格式 / 换尺寸都救不回来。冷编译之后**新起的进程**则完全正常。
///
/// 所以这里把两件事分开：
/// 1. `--ocr-warmup`：一次性进程，专门去踩冷编译这个雷，跑完就死；
/// 2. `--ocr-server`：冷编译之后才启动的常驻进程，负责真正的识别。
///
/// 主进程既不做预热也不做识别，因此永远不会被污染。独立进程要是也坏了，杀掉重来。
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
    private var process: Process?
    private var toHelper: FileHandle?
    private var fromHelper: FileHandle?
    private var buffer = Data()
    /// 本次 App 运行里是否已经做过冷编译
    private var warmedThisRun = false
    /// 独立进程冷加载要十几秒，给足余量；超时就杀掉重来
    private let timeout: TimeInterval = 90

    private init() {}

    /// 同步调用，调用方负责放在后台线程。
    func recognize(image: CGImage, enhance: OCR.Enhance) throws -> OCR.Result {
        try queue.sync {
            ensureWarmLocked()
            do {
                return try runOnHelper(image: image, enhance: enhance)
            } catch OCR.OCRError.failed(let message) where message.contains("CRImageReader") {
                // 独立进程自己也被冷编译污染了（说明启动时模型还是冷的）。
                // 编译结果这会儿肯定已经落盘，换个新进程必然恢复正常。
                Log.info("OCR bridge: 独立进程报 CRImageReader，杀掉重启后重试")
                teardown()
                return try runOnHelper(image: image, enhance: enhance)
            }
        }
    }

    /// 启动时在后台把冷编译做完（一次性进程），这样第一次截图不用等十几秒。
    func warmupInBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            self.ensureWarmLocked()
            Log.info("OCR bridge: 冷编译就绪，后续识别走独立进程")
        }
    }

    var isHelperRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - 内部

    /// 每个 App 生命周期里只做一次冷编译。
    private func ensureWarmLocked() {
        guard !warmedThisRun else { return }
        warmedThisRun = true
        performWarmup()
    }

    /// 冷编译：拉起 `--ocr-warmup`，等它自己跑完退出。
    ///
    /// 那个进程跑完一次识别就会进入坏状态，但这无所谓 —— 它马上就死了，
    /// 而编译结果留在系统里，后面的 `--ocr-server` 直接是热的。
    private func performWarmup() {
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
        } else {
            Log.info("OCR bridge: 冷编译进程完成 \(Int(-start.timeIntervalSinceNow * 1000))ms，退出码 \(task.terminationStatus)")
        }
    }

    private var executableURL: URL {
        Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    }
    private func runOnHelper(image: CGImage, enhance: OCR.Enhance) throws -> OCR.Result {
        let path = try writePNG(image)
        defer { try? FileManager.default.removeItem(atPath: path) }

        try startHelperIfNeeded()

        let request: [String: Any] = [
            "path": path,
            "enhance": enhance == .off ? "off" : (enhance == .force ? "force" : "auto")
        ]
        guard var payload = try? JSONSerialization.data(withJSONObject: request) else {
            throw BridgeError.encodeFailed
        }
        payload.append(0x0A)

        let started = Date()
        do {
            return try exchange(payload, startedAt: started)
        } catch BridgeError.helperClosed where Date().timeIntervalSince(started) < timeout {
            // 进程是刚死的（不是卡住），重启一次再试
            Log.info("OCR bridge: 独立进程已退出，重启后重试")
            teardown()
            try startHelperIfNeeded()
            return try exchange(payload, startedAt: Date())
        }
    }

    private func exchange(_ payload: Data, startedAt: Date) throws -> OCR.Result {
        guard let toHelper, let fromHelper else { throw BridgeError.helperClosed }
        toHelper.write(payload)

        // 看门狗：卡住不能无限等，直接杀掉进程让下一次重来
        let watchdog = DispatchWorkItem { [weak self] in
            Log.info("OCR bridge: 超时 \(Int(self?.timeout ?? 0)) 秒，杀掉独立进程")
            self?.teardown()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let line = try readLine(from: fromHelper)
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw BridgeError.badReply(String(data: line.prefix(120), encoding: .utf8) ?? "")
        }
        guard (obj["ok"] as? Bool) == true else {
            throw OCR.OCRError.failed(obj["error"] as? String ?? "未知错误")
        }
        let lines = obj["lines"] as? [String] ?? []
        guard !lines.isEmpty else { throw OCR.OCRError.noText }
        let elapsed = obj["elapsed"] as? Int ?? Int(Date().timeIntervalSince(startedAt) * 1000)
        Log.info("OCR bridge: 独立进程识别成功 \(lines.count) 行 / \(elapsed)ms")
        return OCR.Result(lines: lines,
                          text: lines.joined(separator: "\n"),
                          paragraph: obj["paragraph"] as? String ?? lines.joined(separator: " "),
                          confidence: Float(obj["confidence"] as? Double ?? 0),
                          elapsed: elapsed,
                          variant: obj["variant"] as? String ?? "独立进程")
    }

    /// 按行读。Vision 的结果不大，按块读再切行足够。
    ///
    /// 必须用 POSIX read：`FileHandle.read(upToCount:)` 会阻塞到读满请求的字节数或 EOF，
    /// 常驻进程不会关管道，用它就永远等不到响应（这个坑踩过）。
    private func readLine(from handle: FileHandle) throws -> Data {
        let fd = handle.fileDescriptor
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            if let index = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<index]
                buffer = buffer[(index + 1)...]
                return Data(line)
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

    private func startHelperIfNeeded() throws {
        if let process, process.isRunning, toHelper != nil, fromHelper != nil { return }
        teardown()

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
        process = task
        toHelper = input.fileHandleForWriting
        fromHelper = output.fileHandleForReading
        buffer = Data()
        Log.info("OCR bridge: 独立进程已启动 pid=\(task.processIdentifier)")
    }

    private func teardown() {
        toHelper?.closeFile()
        fromHelper?.closeFile()
        toHelper = nil
        fromHelper = nil
        buffer = Data()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }
}
