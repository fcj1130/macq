import SwiftUI

/// 魔法鼠标设置页
struct MagicMouseView: View {
    let tool: MagicMouse
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }

    var body: some View {
        @Bindable var tool = tool
        Form {
            Section {
                Toggle(tr("开启魔法鼠标"), isOn: $tool.enabled)
            } footer: {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(tool.running ? Color.secondary : Color.orange)
            }

            if tool.enabled && !tool.running {
                permissionSection(tool)
            }

            Section {
                Toggle(tr("平滑滚轮"), isOn: $tool.smooth)
                LabeledContent(tr("滚轮速度")) {
                    HStack(spacing: 10) {
                        Slider(value: $tool.speed, in: 0.2...5, step: 0.1)
                        Text(String(format: "%.1fx", tool.speed))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                Toggle(tr("垂直翻转"), isOn: $tool.invertVertical)
                Toggle(tr("水平翻转"), isOn: $tool.invertHorizontal)
            } header: {
                Text(tr("滚轮"))
            } footer: {
                Text(tr("平滑与翻转只作用于物理滚轮的多档滚动；触摸板 / Magic Mouse 表面滑动手势不受影响。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(tr("魔法鼠标"))
        .onAppear { tool.refreshPermission() }
        .onChange(of: tool.enabled) { _, isOn in
            if isOn && !tool.trusted {
                tool.requestPermission()
            }
        }
    }

    private var statusText: String {
        if !tool.enabled { return AppLanguage.localized("已关闭，滚轮使用系统默认行为") }
        if tool.running { return AppLanguage.localized("正在拦截并改写滚轮事件") }
        return AppLanguage.localized("已开启但未生效：") + (tool.tapFailure ?? AppLanguage.localized("事件引擎未启动"))
    }
}

#Preview("魔法鼠标") {
    MagicMouseView(tool: .shared)
        .frame(width: 520, height: 460)
}
