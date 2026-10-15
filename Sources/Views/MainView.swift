import SwiftUI

/// 左侧导航页
enum SideTab: String, CaseIterable, Identifiable, Hashable {
    case myTools
    case toolCenter
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .myTools: "我的工具"
        case .toolCenter: "工具中心"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .myTools: "wrench.and.screwdriver"
        case .toolCenter: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }

    /// 侧栏上部的页；设置钉在底部，不进这里
    static var primary: [SideTab] { [.myTools, .toolCenter] }
}

struct MainView: View {
    /// 由 MacqApp 注入：多窗口共用同一份状态（以前 MainView 自己持有，⌘N 开第二个窗口会各持一份）
    @Environment(AppModel.self) private var model
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue
    @State private var appLocale = Locale(identifier: AppLanguage.stored.localeIdentifier)

    var body: some View {
        // 选中页只保留 AppModel.selectedTab 一个真源（空状态页的"去工具中心"按钮直接改它）
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedTab) {
                    ForEach(SideTab.primary) { tab in
                        Label(AppLanguage.localized(tab.title, languageRaw: languageRaw), systemImage: tab.icon)
                            .tag(tab)
                    }
                }
                .listStyle(.sidebar)
                .frame(maxHeight: .infinity)
                Divider()
                    .padding(.horizontal, 12)
                List(selection: $model.selectedTab) {
                    Label(AppLanguage.localized(SideTab.settings.title, languageRaw: languageRaw), systemImage: SideTab.settings.icon)
                        .tag(SideTab.settings)
                }
                .listStyle(.sidebar)
                .scrollDisabled(true)
                .frame(height: 36)
                .padding(.top, 6)
                .padding(.bottom, 6)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                switch model.selectedTab {
                case .myTools: MyToolsView()
                case .toolCenter: ToolCenterView()
                case .settings: SettingsView()
                }
            }
        }
        .environment(model)
        .environment(\.locale, appLocale)
        // 语言变化时重建导航和详情子树，避免已存在的工具页面保留旧文案。
        .id(languageRaw)
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let selected = AppLanguage(rawValue: languageRaw) ?? AppLanguage.systemLanguage
            appLocale = Locale(identifier: selected.localeIdentifier)
        }
    }
}

#Preview("MainView") {
    MainView()
}
