import AppKit
import CoreML
import Vision

/// 文字识别：Vision 的 VNRecognizeTextRequest。
///
/// 几个实践要点：
/// - `.accurate` 比 `.fast` 慢 2~3 倍，但小字、中文、混排的准确率差距很大，翻译场景必须用 accurate。
/// - 语言顺序有讲究：`["zh-Hans", "en-US"]` 表示优先按简体中文识别，
///   纯英文区域仍会正确识别成英文（Vision 会自动判语种），但中英混排时不会把汉字认成乱码。
/// - Vision 返回的 boundingBox 是左下原点归一化坐标，需要转成"从上到下、从左到右"的阅读顺序。
/// - Vision 对**输入像素尺寸**很敏感：一行十几 px 高的字（终端、小字号 UI）识别率断崖式下跌。
///   放大 + 灰度化 + 反色（深色主题）+ 对比度拉伸能显著救回来，见 `prepared(_:)`。
enum OCR {

    struct Result {
        let lines: [String]
        /// 保留换行，用于 OCR 模式展示
        let text: String
        /// 拼成段落，用于翻译
        let paragraph: String
        let confidence: Float
        let elapsed: Int
        /// 实际走的路径，用于自检对照（"原图" / "增强"）
        let variant: String
    }

    enum OCRError: LocalizedError {
        case imageUnreadable
        case noText
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .imageUnreadable: return "图片读不出来。"
            case .noText: return "这块区域里没有识别到文字。"
            case .failed(let msg): return "文字识别失败：\(msg)"
            }
        }
    }

    enum Enhance {
        /// 小图直接增强；大图先认原图，置信度不理想再增强重认并取优
        case auto
        /// 一律只用原图
        case off
        /// 一律强制增强
        case force
    }

    /// 所有识别串行化。
    ///
    /// 队列 QoS 必须是 userInteractive：首次冷加载（实测 13~48 秒）期间，
    /// 低优先级会让 e5rt 的初始化线程被降频/推迟，加载"看起来成功了"但进程
    /// 之后所有识别都报 `CRImageReaderError 1`（2026-11-14 定位）。
    private static let queue = DispatchQueue(label: "com.peek.ocr", qos: .userInteractive)

    // MARK: - 计算设备

    /// 按名字取设备。macOS 14 之前没有这套 API，只能走默认。
    @available(macOS 14.0, *)
    static func device(named name: String) -> MLComputeDevice? {
        let all = MLComputeDevice.allComputeDevices
        switch name {
        case "cpu":
            return all.first { if case .cpu = $0 { return true }; return false }
        case "gpu":
            return all.first { if case .gpu = $0 { return true }; return false }
        case "ane":
            return all.first { if case .neuralEngine = $0 { return true }; return false }
        default:
            return nil          // "default"：交给系统挑，通常是 ANE
        }
    }

    /// 首选设备。**默认 CPU**，用 `PEEK_OCR_DEVICE=cpu|gpu|ane|default` 可以改。
    ///
    /// 为什么默认不用 ANE（2026-11-14 实测，macOS 27）：
    /// - 速度更快：同一张 900×220，默认（ANE）174ms / 167ms，CPU 83ms / 63ms；
    /// - 更抗睡眠：进程夜里闲置 10 小时后，ANE 上下文已随睡眠掉电失效，
    ///   第二天第一次调用就 `CRImageReaderError 1`，而且**整个进程之后所有识别全废**，
    ///   直到重启。同一时刻一个新进程却能正常冷加载成功（14.2s），说明系统没坏，
    ///   是旧进程里那份失效的 ANE 句柄无法重建。
    ///
    /// 注意：CPU 只是绕开 ANE，不能保证免于「模型页被回收」这个更底层的问题，
    /// 所以下面还有阶梯重试和保活（`startKeepAlive`）。
    /// 不能是 private：run() 的默认参数要用它，默认参数在调用点求值，要求可达
    static var preferredDeviceName: String {
        ProcessInfo.processInfo.environment["PEEK_OCR_DEVICE"] ?? "cpu"
    }
    /// 失败后依次尝试的设备链路。
    /// 每次尝试都会新建 request 和 handler —— 换设备等于换一条 e5rt 流，
    /// 这是进程内唯一还可能自救的手段。
    private static var deviceLadder: [String] {
        let first = preferredDeviceName
        let rest = ["cpu", "default", "gpu"].filter { $0 != first }
        return [first] + rest
    }

    /// 启动日志用：说清楚这次到底走哪条路
    static var debugDeviceSummary: String {
        let name = preferredDeviceName
        guard #available(macOS 14.0, *) else { return "\(name)（系统低于 14，无法指定）" }
        let count = MLComputeDevice.allComputeDevices.count
        return device(named: name) == nil
            ? "\(name)（找不到，退回系统默认；可选 \(count) 个）"
            : "\(name)（可用，共 \(count) 个设备）"
    }

    /// 把任意 CGImage 规范成统一位图格式：8-bit / 32bpp / BGRA 预乘 / DeviceRGB。
    ///
    /// 这是 `CRImageReaderError 1` 的真正病根（macOS 26/27 实测）：
    /// 进程首次冷加载模型后，Vision 只认「和第一次调用完全相同的像素格式」。
    /// 之后只要输入换一种格式（截图的 noneSkipFirst、增强图的灰度 8bpp、
    /// PNG 解码出来的 16bpc premultipliedLast…），建流就失败，整个进程的识别
    /// 全废直到重启。把所有输入先压成同一种格式，这条路径就只剩一种 shape。
    static func normalize(_ image: CGImage) -> CGImage {
        if image.bitsPerComponent == 8, image.bitsPerPixel == 32,
           image.alphaInfo == .premultipliedFirst,
           image.colorSpace?.model == .rgb {
            return image
        }
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    /// 同步识别。调用方负责放到后台队列（大图耗时几十到几百毫秒）。
    ///
    /// 失败不是重试同一个设备，而是**换设备重来**：同一设备上失败后状态已经脏了
    /// （旧进程那种「一次失败、此后全废」就是这么来的），换设备会新建 request、
    /// 新建 handler、走另一条执行流，这是进程内唯一还可能自救的手段。
    static func recognize(_ image: CGImage,
                         languages: [String] = ["zh-Hans", "en-US"],
                         enhance: Enhance = .auto) throws -> Result {
        try queue.sync {
            var lastError: Error?
            let ladder = deviceLadder
            for (index, deviceName) in ladder.enumerated() {
                if index > 0 {
                    Log.info("OCR: 换设备重试 #\(index)（\(deviceName)）")
                    Thread.sleep(forTimeInterval: 0.3)
                }
                do {
                    let result = try recognizeOnce(image, languages: languages,
                                                   enhance: enhance, deviceName: deviceName)
                    if index > 0 {
                        Log.info("OCR: 换设备后成功（\(deviceName)），首选设备 \(ladder[0]) 已失效")
                    }
                    return result
                } catch OCRError.noText {
                    // 图里就是没字，这是正常结果，换设备也没用
                    throw OCRError.noText
                } catch {
                    lastError = error
                    Log.info("OCR: 设备 \(deviceName) 失败（\(error.localizedDescription)）")
                }
            }
            throw lastError ?? OCRError.failed("所有计算设备都失败了")
        }
    }

    /// 识别入口。**默认全部交给独立进程**，GUI 进程自己一次 Vision 都不碰。
    ///
    /// 为什么不是「先在本进程试，失败再兜底」：冷编译那一次调用会污染执行它的进程，
    /// 而 GUI 进程是常驻的 —— 一旦被污染就再也恢复不了，每次识别都得先花 0.7 秒
    /// 试三个注定失败的设备再兜底。反过来，「冷编译 + 识别」都放在用完就退的独立进程里，
    /// 主进程永远干净。
    ///
    /// 排障时可以 `PEEK_OCR_INPROC=1` 强制走进程内路径。
    static func recognizeRobust(_ image: CGImage,
                                enhance: Enhance = .auto) throws -> Result {
        if ProcessInfo.processInfo.environment["PEEK_OCR_INPROC"] != nil {
            return try recognize(image, enhance: enhance)
        }
        return try OCRBridge.shared.recognize(image: image, enhance: enhance)
    }

    private static func recognizeOnce(_ image: CGImage,
                                      languages: [String],
                                      enhance: Enhance,
                                      deviceName: String) throws -> Result {
        let start = Date()
        let plainVariant = "原图"
        let boostedVariant = "增强"

        switch enhance {
        case .off:
            return try run(image, languages: languages, origin: start,
                           variant: plainVariant, deviceName: deviceName)

        case .force:
            if let boosted = prepared(image),
               let result = try? run(boosted, languages: languages, origin: start,
                                     variant: boostedVariant, deviceName: deviceName) {
                return result
            }
            return try run(image, languages: languages, origin: start,
                           variant: plainVariant, deviceName: deviceName)

        case .auto:
            // 两路都跑，按"行数"选优。
            //
            // 为什么不用 Vision 的置信度做裁判：实测不可靠。等宽终端字那一组，
            // 增强版置信度 0.50 高于原图 0.43，但内容把 `load` 认成 `1oad`、`0.93` 认成 `8.93`。
            // 而小字号中文那一组正相反：原图整行漏掉（2 行），增强版 3 行全出。
            //
            // 取舍：漏一整行比个别字母错（`l`→`1`）严重得多 —— 漏行会让译文丢信息，
            // 错字母多数能被翻译模型纠正。所以行数多的赢，行数打平则用原图（少一层插值噪声）。
            var plain: Result?
            var plainError: Error?
            do {
                plain = try run(image, languages: languages, origin: start,
                                variant: plainVariant, deviceName: deviceName)
            } catch {
                plainError = error
            }

            // 整屏大图且原图已经认得不错：不做增强，省一次几百毫秒
            if let plain, max(image.width, image.height) >= 1600, plain.confidence >= 0.7 {
                return plain
            }

            guard let boosted = prepared(image),
                  let alternative = try? run(boosted, languages: languages, origin: start,
                                             variant: boostedVariant, deviceName: deviceName) else {
                if let plain { return plain }
                throw plainError ?? OCRError.noText
            }

            guard let plain else {
                Log.info("OCR: 原图无结果，采用增强结果")
                return alternative
            }

            if alternative.lines.count > plain.lines.count {
                Log.info("OCR: 增强多认出 \(alternative.lines.count - plain.lines.count) 行，采用增强结果")
                return alternative
            }
            return plain
        }
    }

    /// 预热交给**一次性进程**做，不要在 GUI 进程里跑。
    ///
    /// 2026-11-14 实测（macOS 27 / 16 GB）：冷编译那一次调用本身会「污染」执行它的进程 ——
    /// 第一次调用返回结果（或空结果），紧接着同一个进程里的第二次调用必报
    /// `CRImageReaderError 1`，换设备、换格式、换尺寸都救不回来。
    /// 而冷编译完成后**新起的进程**（编译结果已在系统里）连续识别一切正常。
    ///
    /// 所以：冷编译放在 `--ocr-warmup` 那个用完就退的进程里，真正的识别交给
    /// 冷编译之后才启动的 `--ocr-server`。GUI 进程自己一次 Vision 都不碰。
    static func prewarm() {
        OCRBridge.shared.warmupInBackground()
        startKeepAlive()
    }

    /// 睡眠唤醒后调用：模型页可能已被回收，不管「本次开机已编译」标记，强制重来一次。
    static func rewarm() {
        OCRBridge.shared.rewarm()
        startKeepAlive()
    }

    // MARK: - 保活

    private static let keepAliveLock = NSLock()
    private static var keepAliveTimer: DispatchSourceTimer?
    private static let keepAliveInterval: TimeInterval = 20 * 60

    /// 每 20 分钟轻点一次模型，让它别被系统当成冷页回收。
    ///
    /// 为什么需要：Peek 是常驻应用，用户可能一整天不截图。2026-11-14 那次故障
    /// 就是「夜里闲置 10 小时后，早上第一次识别必失败」—— 模型页已被系统回收，
    /// 而进程里那份 Vision 全局状态重建不出来（新进程却能正常冷加载成功）。
    /// 一次空识别约 60ms CPU，20 分钟一次，一天合计 4 秒左右。
    static func startKeepAlive() {
        keepAliveLock.lock()
        defer { keepAliveLock.unlock() }
        guard keepAliveTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + keepAliveInterval,
                       repeating: keepAliveInterval,
                       leeway: .seconds(60))
        timer.setEventHandler { keepAliveTick() }
        timer.resume()
        keepAliveTimer = timer
        Log.info("OCR: 保活已启动（每 \(Int(keepAliveInterval / 60)) 分钟轻点一次模型）")
    }

    static func stopKeepAlive() {
        keepAliveLock.lock()
        defer { keepAliveLock.unlock() }
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
    }

    static var isKeepingAlive: Bool {
        keepAliveLock.lock()
        defer { keepAliveLock.unlock() }
        return keepAliveTimer != nil
    }

    private static func keepAliveTick() {
        guard let image = warmupImage() else { return }
        do {
            _ = try OCRBridge.shared.recognize(image: image, enhance: .off)
            Log.info("OCR: 保活通过")
        } catch OCRError.noText {
            // 空图认不出字也说明链路通、模型在
            Log.info("OCR: 保活通过（空图无文字）")
        } catch {
            Log.info("OCR: 保活失败（\(error.localizedDescription)）")
        }
    }

    /// 预热用的合成图：白底黑字，900×220。
    /// 走 CoreText 而不是 NSImage.lockFocus —— 后者要求主线程，预热跑在后台队列。
    /// 独立识别进程（--ocr-server）也要用它先热模型，所以不能是 private。
    static func warmupImage() -> CGImage? {
        let width = 900, height = 220
        // 格式必须和 normalize() 的目标格式一致，否则预热那一枪和后续识别的 shape 不同
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else {
            return nil
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(NSColor.black.cgColor)
        let font = CTFontCreateWithName("Helvetica" as CFString, 56, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Peek warmup 预热 文字识别",
                               attributes: [.font: font, .foregroundColor: NSColor.black]))
        context.textPosition = CGPoint(x: 30, y: 90)
        CTLineDraw(line, context)
        return context.makeImage()
    }

    // MARK: - 预处理

    /// 把图变成更适合 Vision 的样子：
    /// 1. 转灰度（彩色底纹 / 抗锯齿彩边会干扰识别）；
    /// 2. 深底浅字自动反色 —— 深色主题截图里 Vision 经常整段漏掉；
    /// 3. 动态范围不足时做百分位拉伸（2%~98%），把灰底灰字拉开；
    /// 4. 小图放大（短边 < 240 用 3×、< 640 用 2×，其余 1.5×），上限 1600 万像素。
    ///
    /// 注意**不做硬二值化**：二值化会把抗锯齿边缘吃成锯齿，中文笔画粘连，
    /// Vision 的识别率反而下降。拉伸已经能拿到同等收益。
    ///
    /// - Parameter upscale: 传 nil 用自动策略；传具体倍数供自检做对照实验。
    static func prepared(_ image: CGImage, upscale: CGFloat? = nil) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width >= 8, height >= 8 else { return nil }
        let count = width * height

        guard let gray = CGContext(data: nil, width: width, height: height,
                                   bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(),
                                   bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        gray.interpolationQuality = .high
        gray.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let raw = gray.data else { return nil }
        let bytes = raw.bindMemory(to: UInt8.self, capacity: count)

        var histogram = [Int](repeating: 0, count: 256)
        var sum = 0
        for index in 0..<count {
            let value = Int(bytes[index])
            histogram[value] += 1
            sum += value
        }
        let mean = Double(sum) / Double(count)

        func percentile(_ ratio: Double) -> Int {
            let target = Int(Double(count) * ratio)
            var accumulated = 0
            for value in 0..<256 {
                accumulated += histogram[value]
                if accumulated >= target { return value }
            }
            return 255
        }

        let low = percentile(0.02)
        let high = percentile(0.98)
        let span = high - low
        let invert = mean < 100                 // 深底浅字
        // 动态范围已经很满（照片、彩色 UI）就别拉伸了，只会把噪点放大
        let stretch = span >= 24 && span < 200

        if invert || stretch {
            for index in 0..<count {
                var value = Int(bytes[index])
                if stretch {
                    value = (value - low) * 255 / span
                    value = min(255, max(0, value))
                }
                if invert { value = 255 - value }
                bytes[index] = UInt8(value)
            }
        }

        let shortSide = min(width, height)
        // 实测：1× 不放大时深色小图只认出 1 行（340×96 的深底样本），2× 起才正常，
        // 说明小图的瓶颈是像素密度而不是对比度。倍数按短边分档。
        var scale: CGFloat = upscale ?? (shortSide < 200 ? 3 : (shortSide < 700 ? 2 : 1.5))
        while CGFloat(width) * scale * CGFloat(height) * scale > 16_000_000, scale > 1 {
            scale *= 0.8
        }

        guard let processed = gray.makeImage() else { return nil }
        guard scale > 1.01 else { return processed }

        let outWidth = Int((CGFloat(width) * scale).rounded())
        let outHeight = Int((CGFloat(height) * scale).rounded())
        guard let up = CGContext(data: nil, width: outWidth, height: outHeight,
                                 bitsPerComponent: 8, bytesPerRow: outWidth,
                                 space: CGColorSpaceCreateDeviceGray(),
                                 bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return processed }
        up.interpolationQuality = .high
        up.draw(processed, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))

        Log.info("OCR: 预处理 \(width)×\(height) → \(outWidth)×\(outHeight) 反色=\(invert) 拉伸=\(stretch ? "\(low)~\(high)" : "否")")
        return up.makeImage() ?? processed
    }

    // MARK: - 识别

    static func run(_ image: CGImage,
                    languages: [String] = ["zh-Hans", "en-US"],
                    origin: Date = Date(),
                    variant: String,
                    deviceName: String = OCR.preferredDeviceName) throws -> Result {
        // 统一像素格式：Vision 冷加载后只认「和首次调用同格式」的输入，格式一变就建流失败
        let original = image
        let image = normalize(original)
        Log.info("OCR[\(variant)] 输入 \(original.width)×\(original.height) bpc=\(original.bitsPerComponent) bpp=\(original.bitsPerPixel) a=\(original.alphaInfo.rawValue) cs=\(original.colorSpace?.name as String? ?? "nil") → a=\(image.alphaInfo.rawValue) bpp=\(image.bitsPerPixel) 设备=\(deviceName)")

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        // 关闭自动语种检测：开了以后会忽略我们指定的顺序，中文小字容易掉
        request.automaticallyDetectsLanguage = false
        // 指定计算设备：默认 CPU，见 preferredDeviceName 的说明。
        // macOS 14 之前没有这个 API，只能交给系统。
        if #available(macOS 14.0, *), let picked = device(named: deviceName) {
            request.setComputeDevice(picked, for: .main)
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw OCRError.failed(error.localizedDescription)
        }

        let observations = (request.results ?? []).compactMap { $0 as? VNRecognizedTextObservation }
        guard !observations.isEmpty else { throw OCRError.noText }

        // 按视觉行聚类。
        // 早先按 maxY 取整分桶，结果同一行被拆成两半（"UNet子" / "图"）——
        // 两段文字的 maxY 只要差一点点就会落到不同桶里。改成纵向重叠判定：
        // 与当前行的纵向区间重叠超过半行高，就算同一行。
        struct Line {
            var band: (minY: CGFloat, maxY: CGFloat)
            var items: [(minX: CGFloat, text: String, confidence: Float)]
        }

        var lines: [Line] = []
        for obs in observations {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let box = obs.boundingBox        // 左下原点归一化
            let minY = box.minY
            let maxY = box.maxY
            let height = maxY - minY

            if let index = lines.firstIndex(where: { line in
                let overlap = min(line.band.maxY, maxY) - max(line.band.minY, minY)
                let smaller = min(line.band.maxY - line.band.minY, height)
                // 中文单字（"图"）高度极小，用 40% 阈值太严，取两者较小高度的一半
                return smaller > 0 && overlap > smaller * 0.5
            }) {
                lines[index].items.append((box.minX, candidate.string, candidate.confidence))
                lines[index].band.minY = min(lines[index].band.minY, minY)
                lines[index].band.maxY = max(lines[index].band.maxY, maxY)
            } else {
                lines.append(Line(band: (minY, maxY),
                                  items: [(box.minX, candidate.string, candidate.confidence)]))
            }
        }

        // 行从上到下（maxY 大在上），行内从左到右
        lines.sort { $0.band.maxY > $1.band.maxY }

        var texts: [String] = []
        var confidences: [Float] = []
        for line in lines {
            let ordered = line.items.sorted { $0.minX < $1.minX }
            let joined = joinInline(ordered.map { ($0.minX, $0.text) })
            guard !joined.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            texts.append(joined)
            confidences.append(contentsOf: ordered.map(\.confidence))
        }
        guard !texts.isEmpty else { throw OCRError.noText }

        let average = confidences.isEmpty ? 0 : confidences.reduce(0, +) / Float(confidences.count)

        let result = Result(
            lines: texts,
            text: texts.joined(separator: "\n"),
            paragraph: joinAsParagraph(texts),
            confidence: average,
            elapsed: Int(-origin.timeIntervalSinceNow * 1000),
            variant: variant
        )
        Log.info("OCR[\(variant)]: \(texts.count) 行 / 置信度 \(String(format: "%.2f", average)) / \(result.elapsed)ms → \(result.text.prefix(40).replacingOccurrences(of: "\n", with: " / "))")
        return result
    }

    /// 同一行内的碎片拼接。中文之间不加空格，拉丁文之间补一个。
    private static func joinInline(_ fragments: [(x: CGFloat, text: String)]) -> String {
        var out = ""
        for fragment in fragments {
            let piece = fragment.text
            guard !piece.isEmpty else { continue }
            if out.isEmpty {
                out = piece
                continue
            }
            let lastCJK = out.unicodeScalars.last.map(isCJK) ?? false
            let firstCJK = piece.unicodeScalars.first.map(isCJK) ?? false
            out += (lastCJK || firstCJK) ? piece : " " + piece
        }
        return out
    }

    /// 把逐行结果拼回段落：
    /// 中文行之间不加空格（加了反而别扭），英文行之间补一个空格。
    private static func joinAsParagraph(_ lines: [String]) -> String {
        var out = ""
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if out.isEmpty {
                out = trimmed
                continue
            }
            let lastChar = out.unicodeScalars.last
            let firstChar = trimmed.unicodeScalars.first
            let lastIsCJK = lastChar.map(isCJK) ?? false
            let firstIsCJK = firstChar.map(isCJK) ?? false
            // 行尾连字符表示这个词被拆开了，接上不要留空格
            if lastChar == "-" {
                out.removeLast()
                out += trimmed
            } else if lastIsCJK || firstIsCJK {
                out += trimmed
            } else {
                out += " " + trimmed
            }
        }
        return out
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF,      // 汉字
             0x3000...0x303F,                        // 中文标点
             0xFF00...0xFFEF,                        // 全角
             0x3040...0x30FF,                        // 假名
             0xAC00...0xD7AF:                        // 谚文
            return true
        default:
            return false
        }
    }
}
