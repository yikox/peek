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
