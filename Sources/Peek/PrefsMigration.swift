import Foundation

/// 从旧 bundle id 迁移偏好设置。
///
/// 项目改名时 bundle id 从 `com.bobkit.translator` 换成 `com.peek.translator`，
/// 对 macOS 来说这是两个不同的 App —— UserDefaults 是新的空域，
/// 已经填好的 Base URL / Key / 模型 / 引擎选择会全部"消失"。
/// 这里在首次启动时把旧域里的配置搬过来，只跑一次。
///
/// 注意搬不过来的东西：TCC 授权（辅助功能 / 屏幕录制）绑在 bundle id 上，
/// 换 id 后必须重新勾一次，这个没法用代码绕过。
enum PrefsMigration {

    private static let legacyDomain = "com.bobkit.translator"
    private static let marker = "migratedFromBobKit"

    private static let keys = [
        PrefKey.engineId,
        PrefKey.baseURL,
        PrefKey.apiKey,
        PrefKey.model,
        PrefKey.systemPrompt,
        PrefKey.autoCopy
    ]

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)

        guard let legacy = defaults.persistentDomain(forName: legacyDomain) else {
            Log.info("迁移: 没有旧配置域（\(legacyDomain)），跳过")
            return
        }

        var moved: [String] = []
        for key in keys {
            // 新域已经有值就不覆盖，避免把手工改过的设置冲掉
            guard defaults.object(forKey: key) == nil, let value = legacy[key] else { continue }
            defaults.set(value, forKey: key)
            moved.append(key)
        }

        if moved.isEmpty {
            Log.info("迁移: 旧域存在但没有可搬的键")
        } else {
            Log.info("迁移: 从 \(legacyDomain) 搬了 \(moved.count) 项 → \(moved.joined(separator: ", "))")
        }
        defaults.synchronize()
    }
}
