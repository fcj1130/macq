import SwiftUI

/// 魔法右键设置页。
///
/// 菜单由 Finder 扩展画，所以这里除了开关，还要给出扩展在系统里的状态与注册入口。
struct MagicRightClickView: View {
    let tool: MagicRightClick
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }

    var body: some View {
        @Bindable var tool = tool

        Form {
            Section {
                Toggle(tr("开启魔法右键"), isOn: $tool.enabled)
            } footer: {
                Text(tr("关闭后访达右键菜单里不再出现下面这些项。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(RightClickItem.allCases) { item in
                    Toggle(isOn: binding(for: item)) {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tr(item.title))
                                Text(tr(item.summary))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: item.icon)
                        }
                    }
                }
            } header: {
                Text(tr("菜单项"))
            } footer: {
                Text(tr("在访达里右键文件、文件夹或空白处都能看到已开启的项；「新建文件」只在文件夹空白处出现。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker(tr("打开终端"), selection: $tool.terminalBundleID) {
                    ForEach(tool.terminalOptions) { option in
                        Text(tr(option.name)).tag(option.id)
                    }
                }
            } header: {
                Text(tr("进入终端"))
            } footer: {
                Text(tr("只列出这台机器上装了的终端；选中项被卸载后会自动回退到「终端」。"))
                Text(tr("访达扩展受沙箱限制、不能自己启动终端，菜单项会把请求交给 MacQ 执行；所以「进入终端」需要 MacQ 在运行，没运行时这一项不显示。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent(tr("扩展状态")) {
                    Text(tr(tool.extensionStatus.title))
                        .foregroundStyle(tool.extensionStatus.isUsable ? Color.secondary : Color.orange)
                }
                HStack {
                    Button(tr("注册并启用")) { tool.registerExtension() }
                    Button(tr("重新检测")) { tool.refresh() }
                    Button(tr("系统设置")) { tool.openExtensionSettings() }
                }
                .controlSize(.small)
            } header: {
                Text(tr("访达扩展"))
            } footer: {
                Text(tool.diagnostic)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(tr("魔法右键"))
        .onAppear { tool.refresh() }
    }

    private func binding(for item: RightClickItem) -> Binding<Bool> {
        switch item {
        case .copyPath: return Binding(get: { tool.copyPath }, set: { tool.copyPath = $0 })
        case .openTerminal: return Binding(get: { tool.openTerminal }, set: { tool.openTerminal = $0 })
        case .newFile: return Binding(get: { tool.newFile }, set: { tool.newFile = $0 })
        }
    }
}

#Preview {
    NavigationStack {
        MagicRightClickView(tool: MagicRightClick.shared)
    }
    .frame(width: 520, height: 560)
}
