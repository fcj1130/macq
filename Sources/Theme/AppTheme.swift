import SwiftUI
import AppKit

/// UI 主题：跟随系统（默认）/ 深色 / 浅色
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    static let storageKey = "appTheme"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统"
        case .dark: "深色"
        case .light: "浅色"
        }
    }

    /// nil 表示跟随系统
    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }

    /// 已保存的主题（首次启动为跟随系统）
    static var stored: AppTheme {
        AppTheme(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    private static var applied: AppTheme?

    /// 应用到整个 app：内容、标题栏、侧栏材质、菜单与面板都会跟随。
    /// 窗口也逐个设置，否则已存在的窗口（Liquid Glass 材质）可能不重绘。
    static func apply(_ theme: AppTheme) {
        guard applied != theme else { return }
        applied = theme
        NSApplication.shared.appearance = theme.appearance
        for window in NSApplication.shared.windows {
            window.appearance = theme.appearance
        }
    }
}
