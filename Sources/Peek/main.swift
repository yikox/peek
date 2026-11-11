import AppKit

let app = NSApplication.shared

/// 取某个 flag 后面的值
func argument(after flag: String) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: flag),
          index + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[index + 1]
}

// 无头自检
if CommandLine.arguments.contains("--verify") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Verify.run()
}

// 模型目录：Peek --verify-catalog [baseURL]
if CommandLine.arguments.contains("--verify-catalog") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Verify.runCatalog(baseURL: argument(after: "--verify-catalog") ?? ModelCatalog.openRouterBase)
}

// 可用性探测：Peek --verify-probe <baseURL> [apiKey] [数量]
if let base = argument(after: "--verify-probe") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let key = argument(after: "--key") ?? ""
    let limit = Int(argument(after: "--limit") ?? "") ?? 5
    Verify.runProbe(baseURL: base, apiKey: key, limit: limit)
}

// 粘贴链路自检：Peek --verify-paste [--log 路径]
// 环境变量入口供 `open`（真实 LaunchServices 启动）使用：
//   launchctl setenv PEEK_PASTE_SELFTEST 1
//   open -n dist/Peek.app
if CommandLine.arguments.contains("--verify-paste")
    || CommandLine.arguments.contains("--paste-selftest")
    || ProcessInfo.processInfo.environment["PEEK_PASTE_SELFTEST"] != nil {
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    let logPath = argument(after: "--log")
        ?? ProcessInfo.processInfo.environment["PEEK_SELFTEST_LOG"]
    Verify.runPaste(logPath: logPath)
}

// 系统翻译自检：--verify-system [--download]
// 环境变量入口供 `open`（真实 app 上下文）使用，stdout 重定向到日志文件
if CommandLine.arguments.contains("--verify-system")
    || ProcessInfo.processInfo.environment["PEEK_SYSTEM_SELFTEST"] != nil {
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    if let path = ProcessInfo.processInfo.environment["PEEK_SELFTEST_LOG"] {
        freopen(path, "w", stdout)
        setvbuf(stdout, nil, _IONBF, 0)
    }
    Verify.runSystem(download: CommandLine.arguments.contains("--download")
                     || ProcessInfo.processInfo.environment["PEEK_SYSTEM_DOWNLOAD"] != nil)
}

// HTTP 端到端自检：--verify-http http://127.0.0.1:18923/v1
if let base = argument(after: "--verify-http") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Verify.runHTTP(baseURL: base)
    exit(0)
}

// 直接打开设置窗口（冒烟测试用）：--open-settings [秒数]
if CommandLine.arguments.contains("--open-settings") {
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    MainMenu.install()
    SettingsWindow.shared.show()
    let seconds = Double(argument(after: "--open-settings") ?? "") ?? 0
    if seconds > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print("settings window alive, exiting")
            exit(0)
        }
    }
    app.run()
}

// 直接打开模型浏览窗口（冒烟测试用）：--open-models <baseURL> [--seconds N]
if let base = argument(after: "--open-models") {
    app.setActivationPolicy(.regular)
    app.finishLaunching()
    ModelBrowserWindow.shared.show(baseURL: base, apiKey: "", currentModel: "") { model in
        print("picked: \(model.id)")
    }
    let seconds = Double(argument(after: "--seconds") ?? "") ?? 0
    if seconds > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            print("models window alive, exiting")
            exit(0)
        }
    }
    app.run()
}

// 设置窗口渲染
if let path = argument(after: "--snapshot-settings") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Snapshot.captureSettings(dark: CommandLine.arguments.contains("--dark"),
                             path: path,
                             page: Int(argument(after: "--page") ?? "0") ?? 0)
    exit(0)
}

// 模型浏览窗口渲染
if let path = argument(after: "--snapshot-models") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Snapshot.captureModels(dark: CommandLine.arguments.contains("--dark"), path: path)
    exit(0)
}

// OCR 自检（纯文件，不需要任何权限）：Peek --verify-ocr <图片> [--write 输出]
if let path = argument(after: "--verify-ocr") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Verify.runOCRImage(path: path)
}

// 截图能力自检：Peek --verify-capture
if CommandLine.arguments.contains("--verify-capture") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Verify.runCaptureCheck()
}

// 截图遮罩渲染：--snapshot-screenshot <底图> --out <输出png>
if let src = argument(after: "--snapshot-screenshot"), let out = argument(after: "--out") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Snapshot.captureScreenshotOverlay(imagePath: src, path: out)
    exit(0)
}

// 截图缩略图窗渲染：--snapshot-capture <图> --out <输出png>
if let src = argument(after: "--snapshot-capture"), let out = argument(after: "--out") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Snapshot.captureResult(imagePath: src, dark: CommandLine.arguments.contains("--dark"), path: out)
    exit(0)
}

// 剪贴板历史小窗渲染：--snapshot-history <输出png> [--dark]
if let path = argument(after: "--snapshot-history") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Snapshot.captureHistory(dark: CommandLine.arguments.contains("--dark"), path: path)
    exit(0)
}

// 注册向导渲染：--snapshot-signup <路径> [--step 0|1|2]
if let path = argument(after: "--snapshot-signup") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    let step = Int(argument(after: "--step") ?? "") ?? 0
    Snapshot.captureSignup(step: step, dark: CommandLine.arguments.contains("--dark"), path: path)
    exit(0)
}

// 翻译浮窗渲染：--snapshot <路径> [--dark]
if let path = argument(after: "--snapshot") {
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    Snapshot.capture(dark: CommandLine.arguments.contains("--dark"), path: path)
    exit(0)
}

let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
