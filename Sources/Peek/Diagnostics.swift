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

    private static let handle: FileHandle? = {
        let fm = FileManager.default
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

        info("──────── launch ────────")
        info("bundle: \(bundle)")
        info("exe:    \(exe)")
        info("ver:    \(onDiskVersion)  pid: \(ProcessInfo.processInfo.processIdentifier)")
        info("parent: \(ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "-")")
        info("accessibility(取词): \(isTrusted ? "granted" : "NOT granted")")
        info("screenCapture(截图): \(canRecord ? "granted" : "not granted")")
    }
}
