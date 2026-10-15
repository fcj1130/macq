import AppKit

/// 系统权限（辅助功能 / 输入监控）查询与引导。
///
/// 两者都授予后 `CGEvent.tapCreate` 才能建立：辅助功能（发事件/控制电脑）是硬门槛，
/// 纯监听（`.listenOnly`）另需输入监控。
enum SystemPermissions {
    /// 辅助功能
    static var trusted: Bool { AXIsProcessTrusted() }
    /// 输入监控
    static var listenAccess: Bool { CGPreflightListenEventAccess() }

    /// 弹系统授权对话框；授权后一般需要重启 app 才生效
    static func request() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        _ = CGRequestListenEventAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openInputMonitoringSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    }

    /// 重启 app（授权后需要）
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    /// 权限就绪但 tap 仍建不起来时的兜底说明
    static var failureHint: String {
        if !trusted { return AppLanguage.localized("缺少辅助功能权限") }
        if !listenAccess { return AppLanguage.localized("缺少输入监控权限") }
        return AppLanguage.localized("权限已就绪，但 CGEvent.tapCreate 仍然失败")
    }

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
