import AppKit
import Foundation
import Observation
import os

/// 魔法右键：往访达右键菜单里加项（复制路径 / 进入终端）。
///
/// 菜单由 **Finder 扩展**（独立沙箱进程）画。扩展读不到主程序的 UserDefaults，
/// 所以配置由主程序写成 JSON（见 `RightClickSharedConfig`），扩展直接读文件——
/// 好处是 MacQ 退出后最后一次配置照样生效。
@MainActor
@Observable
final class MagicRightClick: ToggleableTool {
    static let shared = MagicRightClick()

    /// Finder 扩展在系统里的注册状态
    enum ExtensionStatus: Equatable {
        case unknown(String)
        case notEmbedded
        case notRegistered
        case disabled
        case enabled

        var title: String {
            switch self {
            case .unknown(let detail): return detail
            case .notEmbedded: return "构建产物里没有扩展"
            case .notRegistered: return "未注册"
            case .disabled: return "已注册，未启用"
            case .enabled: return "已启用"
            }
        }

        var isUsable: Bool { self == .enabled }
    }

    var enabled: Bool { didSet { persist() } }
    var copyPath: Bool { didSet { persist() } }
    var openTerminal: Bool { didSet { persist() } }
    var newFile: Bool { didSet { persist() } }
    var terminalBundleID: String { didSet { persist() } }

    private(set) var installedTerminals: [TerminalApp.Installed] = []
    private(set) var extensionStatus: ExtensionStatus = .unknown("尚未检测")
    private(set) var syncedPaths: [String] = []

    private let settings: ToolSettings
    private let logger = Logger(subsystem: "com.mymy.macq", category: "rightclick")

    init() {
        let settings = ToolSettings(tool: "magicRightClick")
        enabled = settings.bool("enabled", false)
        copyPath = settings.bool("copyPath", true)
        openTerminal = settings.bool("openTerminal", true)
        newFile = settings.bool("newFile", true)
        terminalBundleID = settings.string("terminal", TerminalApp.systemBundleID)
        self.settings = settings
        installedTerminals = TerminalApp.installed()
        sync()
        logger.notice("启动 已启用=\(self.enabled, privacy: .public) 复制路径=\(self.copyPath, privacy: .public) 进入终端=\(self.openTerminal, privacy: .public) 终端=\(self.terminalBundleID, privacy: .public)")

        // 重新编译后系统会丢掉扩展的启用状态：用户实测「重启 MacQ 后右键菜单不出现，进去点一次
        // 『注册并启用』才出现」。实测 `pluginkit -m` 此时仍显示 `+`（已启用），所以这个标志不可信；
        // 实测只跑 `pluginkit -a`（登记）不够，要 `-e use`（启用）才会让系统重新加载扩展。
        // 所以启用状态下每次启动都自动登记启用一次，省得每次都要手点按钮。
        // 注：右键菜单本身只能真机验收——合成鼠标右键不会触发访达的菜单（实测弹不出任何菜单）。
        if enabled {
            logger.notice("启动时自动重新登记扩展")
            Task { self.registerExtension() }
        }
    }

    // MARK: - 设置页数据

    /// 终端下拉项：已安装的 + 当前选中项（可能已卸载，用占位行显示）
    var terminalOptions: [TerminalApp.Installed] {
        var options = installedTerminals
        if !options.contains(where: { $0.id == terminalBundleID }) {
            options.append(TerminalApp.Installed(id: terminalBundleID, name: "\(terminalBundleID)（已卸载）", url: nil))
        }
        return options
    }

    /// 设置页底部那行体检结果
    var diagnostic: String {
        let items = RightClickItem.allCases.filter(isOn).map(\.title)
        let terminal = installedTerminals.first { $0.id == terminalBundleID }?.name ?? "终端（回退）"
        return "菜单项：\(items.isEmpty ? "无" : items.joined(separator: " / ")) · 终端：\(terminal) · 配置已写入 \(syncedPaths.count) 处"
    }

    private func isOn(_ item: RightClickItem) -> Bool {
        switch item {
        case .copyPath: return copyPath
        case .openTerminal: return openTerminal
        case .newFile: return newFile
        }
    }

    // MARK: - 操作

    /// 重新探测终端列表与扩展状态
    func refresh() {
        installedTerminals = TerminalApp.installed()
        extensionStatus = Self.queryExtensionStatus()
        logger.notice("扩展状态=\(self.extensionStatus.title, privacy: .public) 路径=\(Self.bundledExtension?.path ?? "无", privacy: .public)")
    }

    /// 把扩展注册进系统并启用（等价于 `pluginkit -a` + `pluginkit -e use`）
    func registerExtension() {
        guard let appex = Self.bundledExtension, FileManager.default.fileExists(atPath: appex.path) else {
            extensionStatus = .notEmbedded
            logger.error("注册失败：构建产物里没有 \(RightClickSharedConfig.extensionName, privacy: .public)")
            return
        }
        _ = runPluginkit(["-a", appex.path])
        _ = runPluginkit(["-e", "use", "-i", RightClickSharedConfig.extensionBundleID])
        logger.notice("已注册并启用扩展 \(appex.path, privacy: .public)")
        refresh()
    }

    func openExtensionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    /// 把当前开关同步给 Finder 扩展
    func sync() {
        let config = RightClickSharedConfig(
            enabled: enabled,
            items: [
                RightClickItem.copyPath.rawValue: copyPath,
                RightClickItem.openTerminal.rawValue: openTerminal,
                RightClickItem.newFile.rawValue: newFile,
            ],
            newFileBaseName: AppLanguage.localized("未命名")
        )
        syncedPaths = config.write().map { [$0.path] } ?? []
        logger.notice("同步配置 已启用=\(config.enabled, privacy: .public) 写到=\(self.syncedPaths.joined(separator: " | "), privacy: .public)")
    }

    private func persist() {
        settings.set(enabled, "enabled")
        settings.set(copyPath, "copyPath")
        settings.set(openTerminal, "openTerminal")
        settings.set(newFile, "newFile")
        settings.set(terminalBundleID, "terminal")
        sync()
    }

    // MARK: - Finder 扩展

    /// 构建产物里的扩展（MacQ.app/Contents/PlugIns/…appex）
    static var bundledExtension: URL? {
        Bundle.main.builtInPlugInsURL?.appending(path: RightClickSharedConfig.extensionName)
    }

    /// 查 `pluginkit`：输出行首 `+` 表示已启用，`-` 表示已注册但关闭。
    /// `appexPath` 仅用于探针（`Bundle.main` 在探针进程里不是 app 包）。
    static func queryExtensionStatus(appexPath: URL? = nil) -> ExtensionStatus {
        guard let appex = appexPath ?? bundledExtension,
              FileManager.default.fileExists(atPath: appex.path)
        else { return .notEmbedded }
        guard let output = runPluginkit(["-m", "-p", "com.apple.FinderSync", "-i", RightClickSharedConfig.extensionBundleID])
        else { return .unknown("无法查询扩展状态") }
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return .notRegistered }
        return text.hasPrefix("+") ? .enabled : .disabled
    }
}

/// 跑 `pluginkit`（短命令、同步）：只读取状态或注册扩展，失败返回 nil
@discardableResult
private func runPluginkit(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do {
        try process.run()
    } catch {
        return nil
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
