import AppKit

/// 截图 / OCR 相关的命令行自检。
///
/// 为什么要单独做 CLI：OCR 只依赖磁盘上的图片，完全不需要屏幕录制权限，
/// 所以可以在无头进程里稳定回归；而有权限门槛的抓屏只能靠 GUI 进程验证。
extension Verify {

    /// Peek --verify-ocr <图片路径> [--write 输出文本路径] [--compare]
    ///
    /// `--compare` 会跑三路（原图 / 增强 / auto）并排打印，用来验证预处理到底有没有用。
    static func runOCRImage(path: String) -> Never {
        print("OCR 自检: \(path)")

        guard let image = NSImage(contentsOfFile: path)?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("  FAIL  读不出图片")
            exit(1)
        }
        print("  图片: \(image.width)×\(image.height)px")

        if CommandLine.arguments.contains("--matrix") {
            // 对照实验：原图 / 仅增强（不放大）/ 2× / 3×，用来定"到底该不该放大"
            let variants: [(String, CGFloat?)] = [("增强1x", 1.0), ("增强2x", 2.0), ("增强3x", 3.0)]
            do {
                let plain = try OCR.run(image, variant: "原图")
                report(plain)
            } catch {
                print("  ── 原图 ── FAIL \(error.localizedDescription)")
            }
            for (label, scale) in variants {
                guard let boosted = OCR.prepared(image, upscale: scale) else { continue }
                do {
                    report(try OCR.run(boosted, variant: label))
                } catch {
                    print("  ── \(label) ── FAIL \(error.localizedDescription)")
                }
            }
            exit(0)
        }

        if CommandLine.arguments.contains("--compare") {
            for (mode, label) in [(OCR.Enhance.off, "原图"), (.force, "增强"), (.auto, "auto")] {
                print("  ── \(label) ──")
                do {
                    let result = try OCR.recognize(image, enhance: mode)
                    print("  行数 \(result.lines.count)  置信度 \(String(format: "%.2f", result.confidence))  耗时 \(result.elapsed)ms  路径 \(result.variant)")
                    for line in result.lines { print("    | \(line)") }
                } catch {
                    print("  FAIL  \(error.localizedDescription)")
                }
            }
            exit(0)
        }

        do {
            let result = try OCR.recognize(image)
            print("  行数: \(result.lines.count)  置信度: \(String(format: "%.2f", result.confidence))  耗时: \(result.elapsed)ms")
            print("  ── 逐行 ──")
            for (i, line) in result.lines.enumerated() {
                print("  \(i + 1). \(line)")
            }
            print("  ── 段落 ──")
            print("  \(result.paragraph)")

            if let out = argument(after: "--write") {
                try result.text.write(toFile: out, atomically: true, encoding: .utf8)
                print("  已写入: \(out)")
            }
            exit(0)
        } catch {
            print("  FAIL  \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func report(_ result: OCR.Result) {
        print("  ── \(result.variant) ── \(result.lines.count) 行  置信度 \(String(format: "%.2f", result.confidence))  \(result.elapsed)ms")
        for line in result.lines { print("    | \(line)") }
    }

    /// Peek --ocr-warmup：**一次性**冷编译进程，跑完一次就退。
    ///
    /// 冷编译会把执行它的进程弄坏（第一次调用之后，同一进程里所有识别都报
    /// `CRImageReaderError 1`），但编译结果会留在系统里。所以让这个进程去踩雷、
    /// 踩完就死，紧接着启动的 `--ocr-server` 就是干净的、热的。
    static func runOCRWarmup() -> Never {
        let start = Date()
        guard let warm = OCR.warmupImage() else {
            print("no warmup image")
            exit(1)
        }
        do {
            let result = try OCR.recognize(warm, enhance: .off)
            print("warmup ok \(Int(-start.timeIntervalSinceNow * 1000))ms \(result.lines.count) lines")
            exit(0)
        } catch {
            print("warmup failed \(error.localizedDescription)")
            exit(2)
        }
    }

    /// Peek --ocr-server：常驻识别进程，按行收发 JSON。
    ///
    /// 由 `OCRBridge` 从 GUI 主进程里拉起来。为什么不在主进程里直接识别：
    /// macOS 27 + 16 GB 机器上，**冷编译**会让执行它的进程进入不可恢复的坏状态
    /// （三个设备全报 `CRImageReaderError 1`），而冷编译之后新起的进程一切正常。
    /// 所以这个进程不做预热 —— 它启动时模型通常已经被 `--ocr-warmup` 编译好了；
    /// 万一没有，第一枪由这次真实请求去踩，代价是一次十几秒的编译。
    static func runOCRServer() -> Never {
        Log.info("OCR 独立进程: 启动 pid=\(getpid())")

        // 必须用 POSIX read：FileHandle.read(upToCount:) 会一直阻塞到读满 64 KB 或 EOF，
        // 常驻模式下对端不会关管道，就永远等不到第一行。
        var chunk = [UInt8](repeating: 0, count: 65536)
        var pending = Data()
        while true {
            let got = Darwin.read(STDIN_FILENO, &chunk, chunk.count)
            if got < 0 {
                if errno == EINTR { continue }
                Log.info("OCR 独立进程: 读 stdin 失败 errno=\(errno)")
                break
            }
            if got == 0 { break }          // 父进程关闭了管道
            pending.append(contentsOf: chunk[0..<got])
            while let index = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex..<index])
                pending = Data(pending[(index + 1)...])
                reply(with: line)
            }
        }
        exit(0)
    }

    private static func reply(with line: Data) {
        var out: [String: Any]
        do {
            guard let obj = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let path = obj["path"] as? String,
                  let image = NSImage(contentsOfFile: path)?
                    .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw OCR.OCRError.imageUnreadable
            }
            let name = obj["enhance"] as? String ?? "auto"
            let enhance: OCR.Enhance = name == "off" ? .off : (name == "force" ? .force : .auto)
            let result = try OCR.recognize(image, enhance: enhance)
            out = ["ok": true,
                   "lines": result.lines,
                   "paragraph": result.paragraph,
                   "confidence": Double(result.confidence),
                   "elapsed": result.elapsed,
                   "variant": result.variant]
        } catch {
            out = ["ok": false, "error": error.localizedDescription]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: out),
              let text = String(data: data, encoding: .utf8) else { return }
        print(text)
        fflush(stdout)
    }

    /// Peek --verify-capture
    static func runCaptureCheck() -> Never {
        print("截图自检")
        let granted = ScreenCapture.hasPermission
        print("  屏幕录制权限: \(granted ? "已授予" : "未授予")")

        for screen in NSScreen.screens {
            print("  屏幕: \(NSStringFromRect(screen.frame)) scale=\(screen.backingScaleFactor)")
        }

        if granted, let screen = NSScreen.main, let image = ScreenCapture.freeze(screen) {
            print("  抓屏成功: \(image.width)×\(image.height)px")
            let probe = CGRect(x: 0, y: 0, width: 120, height: 40)
            if let cropped = ScreenCapture.crop(image, to: probe) {
                print("  裁剪成功: \(cropped.width)×\(cropped.height)px")
            } else {
                print("  FAIL  裁剪失败")
                exit(1)
            }
        } else if granted {
            print("  FAIL  有权限但抓屏失败")
            exit(1)
        } else {
            print("  说明: 没有权限时只能靠 GUI 进程验证；已授权的进程需重启后才生效")
        }
        exit(0)
    }
}
