import AppKit
import ApplicationServices

/// 启动期诊断。写到 ~/Library/Logs/Peek.log，出问题时先看这里。
enum Log {

    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Peek.log")
    }()

    /// 单个日志文件的上限。剪贴板每收一条就写一行，不封顶的话会一直长。
    private static let maxBytes = 1_000_000

    /// 用 O_APPEND 打开的文件描述符，而不是 FileHandle + seekToEndFile。
    /// 主进程和独立 OCR 进程会同时写这个文件，seek 到尾部再写不是原子操作，
    /// 两边抢着写就会出现半行乱码（实测出现过）。O_APPEND 让每次 write 原子落尾。
    private static let handle: Int32 = {
        let fm = FileManager.default
        // 超限就把当前文件挪成 Peek.log.1，新文件从空开始。
        // 保留一份上一轮的内容，排障时够用，总占用封顶 2 MB。
        if let attrs = try? fm.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int,
           size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        return open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        NSLog("[Peek] %@", message)
        guard handle >= 0, let data = line.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(handle, base, buffer.count)
        }
    }

    /// 启动时把"为什么不能用"一次性全部摊开：位置、签名、权限、状态栏、热键。
    static func reportLaunchContext() {
        let bundle = Bundle.main.bundlePath
        let exe = CommandLine.arguments.first ?? "?"
        let isTrusted = AXIsProcessTrusted()
        let canRecord = CGPreflightScreenCaptureAccess()
        let onDiskVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        // 构建标识由 build.sh 注入：确认「装上去的」和「刚编的」是不是同一份
        let buildCommit = Bundle.main.infoDictionary?["PeekBuildCommit"] as? String ?? ""
        let buildTime = Bundle.main.infoDictionary?["PeekBuildTime"] as? String ?? ""

        info("──────── launch ────────")
        info("bundle: \(bundle)")
        info("exe:    \(exe)")
        let buildTag = buildCommit.isEmpty ? "" : " (\(buildCommit), \(buildTime))"
        info("ver:    \(onDiskVersion)\(buildTag)  pid: \(ProcessInfo.processInfo.processIdentifier)")
        info("parent: \(ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "-")")
        info("accessibility(取词): \(isTrusted ? "granted" : "NOT granted")")
        info("screenCapture(截图): \(canRecord ? "granted" : "not granted")")
    }
}
