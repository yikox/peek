import AppKit
import Foundation

/// 把 OCR 交给一个**独立进程**跑，作为进程内识别失败后的兜底。
///
/// 为什么需要这一层（2026-11-14 定位）：
/// GUI 主进程在 Vision 模型**冷加载**（实测 13.6 秒，16 GB 机器上开机后常见）之后，
/// 有很高概率进入不可恢复状态 —— CPU / 默认 / GPU 三个计算设备**全部**报
/// `TextRecognition.CRImageReaderError error 1`（底层 e5rt 建流失败），
/// 而且进程内没有任何 API 能重置它，只能重启。
///
/// 同一时刻、同一份代码、同样的冷加载，**命令行进程**（`Peek --verify-ocr`）
/// 却能正常识别。差异在进程环境：GUI 进程挂起了 AppKit / Core Animation，
/// 而 Vision 的视觉计算路径在这套环境里冷加载完成后是坏的。
///
/// 所以：主进程先自己跑（热态 60~110 ms，最快），失败才切到这里。
/// 独立进程也坏了就杀掉重来 —— 这是唯一能自愈的做法。
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
    /// 独立进程冷加载要十几秒，给足余量；超时就杀掉重来
    private let timeout: TimeInterval = 90

    private init() {}

    /// 同步调用，调用方负责放在后台线程。
    func recognize(image: CGImage, enhance: OCR.Enhance) throws -> OCR.Result {
        try queue.sync {
            try runOnHelper(image: image, enhance: enhance)
        }
    }

    var isHelperRunning: Bool {
        process?.isRunning ?? false
    }

    // MARK: - 内部

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
        Log.info("OCR bridge: 独立进程识别成功 \(lines.count) 行 / \(elapsed)ms（主进程同一条路已失效）")
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
        let exe = Bundle.main.executableURL
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let task = Process()
        task.executableURL = exe
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
        Log.info("OCR bridge: 独立进程已启动 pid=\(task.processIdentifier)（首次要冷加载模型）")
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
