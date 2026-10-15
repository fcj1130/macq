import SwiftUI

/// 设置页：UI 主题（跟随系统/深色/浅色）
struct SettingsView: View {
    @AppStorage(AppTheme.storageKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        default: return "-"
        }
    }

    var body: some View {
        Form {
            Section(AppLanguage.localized("语言", languageRaw: languageRaw)) {
                Picker(AppLanguage.localized("界面语言", languageRaw: languageRaw), selection: $languageRaw) {
                    ForEach(AppLanguage.allCases.filter { $0 != .system }) { language in
                        Text(AppLanguage.localized(language.displayName, languageRaw: languageRaw)).tag(language.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section(AppLanguage.localized("外观", languageRaw: languageRaw)) {
                Picker(AppLanguage.localized("主题", languageRaw: languageRaw), selection: $themeRaw) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(AppLanguage.localized(theme.displayName, languageRaw: languageRaw)).tag(theme.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }
            Section(AppLanguage.localized("启动", languageRaw: languageRaw)) {
                Toggle(AppLanguage.localized("开机时启动 MacQ", languageRaw: languageRaw), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            let actual = try LaunchAtLogin.setEnabled(enabled)
                            if actual != enabled { launchAtLogin = actual }
                            launchAtLoginError = nil
                        } catch {
                            launchAtLogin = LaunchAtLogin.isEnabled
                            launchAtLoginError = String(format: AppLanguage.localized("设置失败：%@"), error.localizedDescription)
                        }
                    }
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { launchAtLogin = LaunchAtLogin.isEnabled }

            Section(AppLanguage.localized("关于", languageRaw: languageRaw)) {
                LabeledContent(AppLanguage.localized("版本"), value: appVersion)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(AppLanguage.localized("设置", languageRaw: languageRaw))
    }
}

#Preview("Settings") {
    SettingsView()
}
