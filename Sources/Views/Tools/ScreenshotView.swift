import SwiftUI

struct ScreenshotView: View {
    let tool: ScreenshotTool
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }

    var body: some View {
        @Bindable var tool = tool
        Form {
            Section {
                Toggle(tr("启用截图工具"), isOn: $tool.enabled)
            } footer: {
                Text(String(format: tr("全局快捷键 %@ 进入选区：单击窗口或拖出选区即钉框（此时尚未截屏，可拖动平移、手柄缩放）。工具条默认不选工具；选工具后才截屏标注。双击或复制即出图。"), tool.trigger.display))
            }

            Section {
                HStack {
                    Text(tr("唤起截图"))
                    Spacer()
                    Text(tool.recorder.isRecording ? tr("按下组合键或双击修饰键…") : tool.trigger.display)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(tool.recorder.isRecording ? .secondary : .primary)
                    Button(tool.recorder.isRecording ? tr("取消") : tr("录制")) {
                        if tool.recorder.isRecording { tool.recorder.stop() }
                        else { tool.recorder.start { trigger in tool.trigger = trigger } }
                    }
                    Button(tr("重置")) { tool.resetTrigger() }
                }
                if let failure = tool.triggerFailure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(tr("快捷键"))
            } footer: {
                Text(tr("组合键（至少一个 ⌘ / ⌃ / ⌥）不需要辅助功能权限；双击单个修饰键才需要。截图本身需要屏幕录制权限。"))
            }

            Section {
                if tool.screenAccess {
                    Label(tr("屏幕录制已授权"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label(tr("截图需要「屏幕录制」权限：点「请求授权」→ 系统弹窗里打开设置 → 勾选 MacQ。"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(tr("请求授权")) { tool.requestScreenAccess() }
                        Button(tr("重新检测")) { tool.refreshPermission() }
                        Button(tr("打开「屏幕录制」设置")) { tool.openScreenRecordingSettings() }
                    }
                }
            } header: {
                Text(tr("屏幕录制"))
            }

            if tool.trigger.needsEventTap && tool.triggerFailure != nil {
                permissionSection(ScreenshotPermissionBox(tool: tool))
            }

            Section {
                Button(tr("开始截图")) { tool.capture() }
                    .disabled(!tool.enabled)
            }
        }
        .formStyle(.grouped)
        .onAppear { tool.refreshPermission() }
    }
}

/// 把截图工具的辅助功能状态接到共用权限区（只有双击修饰键才会用到）。
@MainActor
private final class ScreenshotPermissionBox: PermissionReporting {
    let tool: ScreenshotTool
    init(tool: ScreenshotTool) { self.tool = tool }
    var trusted: Bool { tool.trusted }
    var listenAccess: Bool { tool.listenAccess }
    var permissionHint: String {
        if !tool.trusted {
            return AppLanguage.localized("MacQ 需要「辅助功能」权限才能双击修饰键唤起截图：点「请求授权」→ 系统弹窗里打开设置 → 勾选 MacQ。")
        }
        if !tool.listenAccess {
            return AppLanguage.localized("「辅助功能」已授权，但监听修饰键双击还需要「输入监控」权限。")
        }
        return AppLanguage.localized("权限看起来都给了，但唤起方式仍注册失败——把下面这行体检结果发给我。")
    }
    var permissionDiagnostic: String {
        String(format: AppLanguage.localized("辅助功能=%@ · 输入监控=%@"),
               tool.trusted ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"),
               tool.listenAccess ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"))
    }
    func requestPermission() { tool.requestPermission() }
    func refreshPermission() { tool.refreshPermission() }
    func relaunch() { tool.relaunch() }
    func openAccessibilitySettings() { tool.openAccessibilitySettings() }
    func openInputMonitoringSettings() { tool.openInputMonitoringSettings() }
}

#Preview {
    ScreenshotView(tool: .shared)
        .frame(width: 520, height: 520)
}
