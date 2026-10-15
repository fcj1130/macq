import Foundation

/// MacQ 支持的界面语言。系统语言仅在首次启动时参与默认选择。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    static let storageKey = "appLanguage"
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "跟随系统 / System"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        }
    }

    var localeIdentifier: String {
        switch self {
        case .system: Self.systemLanguage == .simplifiedChinese ? "zh-Hans" : "en"
        case .simplifiedChinese: "zh-Hans"
        case .english: "en"
        }
    }

    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    static func localized(_ key: String, languageRaw: String? = nil) -> String {
        let selected = AppLanguage(rawValue: languageRaw ?? stored.rawValue) ?? systemLanguage
        let language = selected == .simplifiedChinese ? "zh-Hans" : "en"
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return key }
        let value = bundle.localizedString(forKey: key, value: key, table: "Localizable")
        if value != key { return value }
        // 核心导航/设置文案兜底：避免旧系统或资源缓存导致 key 未命中。
        let fallback: [String: String] = [
            "我的工具": "My Tools", "工具中心": "Tool Center", "设置": "Settings",
            "语言": "Language", "界面语言": "Interface Language", "外观": "Appearance",
            "主题": "Theme", "启动": "Startup", "开机时启动 MacQ": "Launch MacQ at login",
            "跟随系统": "Follow System", "深色": "Dark", "浅色": "Light",
            "添加": "Add", "已添加": "Added", "开发中": "In Development",
            "魔法鼠标": "Magic Mouse", "魔法右键": "Magic Right Click",
            "魔法剪贴板": "Magic Clipboard", "开发者工具箱": "Developer Toolbox",
            "截图工具": "Screenshot Tool", "随机密码": "Random Password",
            "JSON 美化": "JSON Formatter", "URL 编码": "URL Encoding",
            "时间戳": "Timestamp", "取色器": "Color Picker"
        ]
        return fallback[key] ?? key
    }

    static var systemLanguage: AppLanguage {
        let language = Locale.preferredLanguages.first?.lowercased() ?? ""
        // 繁体中文、日文、韩文及其它语言均按英文处理。
        return language.hasPrefix("zh-hans") || language.hasPrefix("zh-cn") || language.hasPrefix("zh-sg")
            ? .simplifiedChinese : .english
    }
}
