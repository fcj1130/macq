import SwiftUI

/// 开发者工具箱设置页
struct DevToolboxView: View {
    let tool: DevToolbox
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }

    var body: some View {
        @Bindable var tool = tool
        Form {
            Section {
                Toggle(tr("启用开发者工具箱"), isOn: $tool.enabled)
            } footer: {
                Text(String(format: tr("全局快捷键唤起面板：%@。面板为独立窗口，切到其他窗口不会消失；esc、关闭按钮或再按一次快捷键可收起。"), tool.trigger.display))
            }

            Section {
                HStack {
                    Text(tr("唤起面板"))
                    Spacer()
                    Text(tool.recorder.isRecording ? tr("按下组合键或双击修饰键…") : tool.trigger.display)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(tool.recorder.isRecording ? .secondary : .primary)
                    Button(tool.recorder.isRecording ? tr("取消") : tr("录制")) {
                        if tool.recorder.isRecording {
                            tool.recorder.stop()
                        } else {
                            tool.recorder.start { trigger in tool.trigger = trigger }
                        }
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
                Text(tr("组合键（至少一个 ⌘ / ⌃ / ⌥）不需要任何系统权限；双击单个修饰键需要辅助功能与输入监控权限。"))
            }

            if tool.trigger.needsEventTap && tool.triggerFailure != nil {
                permissionSection(tool)
            }

            Section {
                Button(tr("打开开发者工具箱")) { tool.showPanel() }
            }
        }
        .formStyle(.grouped)
        .onAppear { tool.refreshPermission() }
    }
}

#Preview {
    DevToolboxView(tool: .shared)
        .frame(width: 520, height: 520)
}
