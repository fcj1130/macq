import SwiftUI

/// 需要系统权限的工具（魔法鼠标、魔法剪贴板…）在设置页里要展示的那套体检信息。
/// 两个工具原来各写一份按钮与文案，现在统一走这一份。
@MainActor
protocol PermissionReporting: AnyObject {
    /// 辅助功能权限
    var trusted: Bool { get }
    /// 输入监控权限
    var listenAccess: Bool { get }
    /// 缺什么权限、下一步做什么
    var permissionHint: String { get }
    /// 可复制的一行体检结果
    var permissionDiagnostic: String { get }

    func requestPermission()
    func refreshPermission()
    func relaunch()
    func openAccessibilitySettings()
    func openInputMonitoringSettings()
}

extension View {
    /// 权限体检区：提示 + 五个操作按钮 + 体检结果
    func permissionSection(_ tool: any PermissionReporting) -> some View {
        Section(AppLanguage.localized("权限")) {
            Label(tool.permissionHint, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(AppLanguage.localized("请求授权")) { tool.requestPermission() }
                Button(AppLanguage.localized("重新检测")) { tool.refreshPermission() }
                Button(AppLanguage.localized("重启 MacQ")) { tool.relaunch() }
            }
            HStack(spacing: 10) {
                Button(AppLanguage.localized("打开「辅助功能」设置")) { tool.openAccessibilitySettings() }
                Button(AppLanguage.localized("打开「输入监控」设置")) { tool.openInputMonitoringSettings() }
            }
            Text(tool.permissionDiagnostic)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}
