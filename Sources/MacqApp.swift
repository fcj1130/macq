import AppKit
import SwiftUI

@main
struct MacqApp: App {
    /// 应用级状态：放在 App 上，所有窗口共用一份
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        AppTheme.apply(.stored)
        // 任何来源的主题变更（设置页、外部 defaults 写入）都立即生效
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            AppTheme.apply(.stored)
        }
    }

    var body: some Scene {
        // 用 Window 而不是 WindowGroup：MacQ 是单窗口应用。
        // WindowGroup 在「点 Dock 图标 / 重新打开 app」时会自己再开一个新窗口
        // （实测窗口序 `MacQ > MacQ`，而 applicationShouldHandleReopen 返回 false 也拦不住），
        // Window 只有一个实例，重复打开只会把它拿到前面。
        Window("MacQ", id: "main") {
            MainView()
                .environment(model)
                .frame(minWidth: 880, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        // 空的匹配集合 = 不因为「外部事件（URL）」新建窗口。
        // 否则每收到一次 macq://… （访达扩展的右键请求）就会多开一个主窗口（实测 1→2→3→4）。
        // URL 本身仍由 AppDelegate 的 application(_:open:) 收到并处理。
        .handlesExternalEvents(matching: [])
    }
}
