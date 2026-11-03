import AppKit
import CoreGraphics

/// 屏幕截图（冻结画面用）+ 屏幕录制权限。
///
/// 权限说明：macOS 14 起 `CGPreflightScreenCaptureAccess()` 是唯一可靠的预检方式；
/// 授权后系统**要求进程重启**才真正生效（TCC 在进程启动时注入），
/// 所以调用方要在授权后提示重启，不能指望当场可用。
enum ScreenCapture {

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 弹系统授权引导。返回当前是否已授权（注意：刚授权时通常仍返回 false，需重启）。
    @discardableResult
    static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
        Log.info("截图: 已打开系统设置的屏幕录制面板")
    }

    /// 抓取指定屏幕的当前画面。返回的是物理像素尺寸（Retina 上是点数的 2 倍）。
    static func freeze(_ screen: NSScreen) -> CGImage? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            Log.info("截图: 拿不到 NSScreenNumber")
            return nil
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        guard let image = CGDisplayCreateImage(displayID) else {
            Log.info("截图: CGDisplayCreateImage 返回 nil（多半是没给屏幕录制权限）")
            return nil
        }
        return image
    }

    /// 用 CGImage 按像素裁剪。rect 是像素坐标，原点左上。
    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.intersection(bounds).integral
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        return image.cropping(to: clipped)
    }
}
