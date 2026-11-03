// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Peek",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Peek",
            path: "Sources/Peek",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("NaturalLanguage"),
                .linkedFramework("SwiftUI"),
                // Translation.framework 是 macOS 15 才有的。
                // 必须弱链接，否则在更早的系统上启动就会因 dyld 找不到而崩。
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "Translation"]),
            ]
        )
    ]
)
