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

    private static let handle: FileHandle? = {
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
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let h = try? FileHandle(forWritingTo: url)
        h?.seekToEndOfFile()
        return h
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) {
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        NSLog("[Peek] %@", message)
        if let data = line.data(using: .utf8) {
            handle?.write(data)
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
