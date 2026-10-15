import AppKit
import Foundation
import os

/// 「魔法右键」的一个菜单项。每项都能独立开关，扩展按开关决定菜单里出现哪些项。
enum RightClickItem: String, CaseIterable, Identifiable, Sendable {
    case copyPath
    case openTerminal
    case newFile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .copyPath: return "复制路径"
        case .openTerminal: return "进入终端"
        case .newFile: return "新建文件"
        }
    }

    /// 只出现在目录空白处（container 菜单）：右键文件/文件夹时没有「当前目录」语义
    var containerMenuOnly: Bool { self == .newFile }

    var summary: String {
        switch self {
        case .copyPath: return "复制所选文件或文件夹的绝对路径"
        case .openTerminal: return "在所选文件夹打开终端；选中的是文件则进它所在文件夹"
        case .newFile: return "在文件夹空白处新建空文件，重名自动加序号"
        }
    }

    var icon: String {
        switch self {
        case .copyPath: return "doc.on.doc"
        case .openTerminal: return "terminal"
        case .newFile: return "doc.badge.plus"
        }
    }

    /// 这一项是否必须由主程序执行。
    ///
    /// 「复制路径」在扩展里就能做完；「进入终端」必须转交主程序（沙箱不让扩展
    /// 把文件夹交给终端，实测）。所以主程序没在运行时它不出现——否则点一下会把
    /// 整个 MacQ 拉起来，而用户要的只是打开终端。
    var requiresHost: Bool {
        switch self {
        case .copyPath: return false
        case .openTerminal: return true
        // 扩展先试着自己建（FinderSync 对监听目录有写权限）；万一被沙箱拒绝，
        // 动作里会在主程序已运行时转交主程序。主程序没在运行也照常显示。
        case .newFile: return false
        }
    }
}

/// 主程序（MacQ 本体）的运行状态。
enum HostApp {
    static let bundleID = "com.mymy.macq"
    /// 探针用：覆盖真实检测结果
    static var runningOverride: Bool?

    static var isRunning: Bool {
        if let runningOverride { return runningOverride }
        return NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

/// 主程序与 Finder 扩展共享的配置。
///
/// 扩展是**沙箱化的独立进程**，读不到主程序的 UserDefaults，所以主程序把配置写成
/// JSON 放到 `~/Library/Application Support/macq/`，扩展靠 entitlements 里的
/// `home-relative-path.read-only` 例外读它。
///
/// 实测过的三条通道（脚本 `Scripts/uidbg/check-sandbox-entitlements.sh` 会复验）：
/// - `home-relative-path` 只读例外：可用 ✓（当前方案）
/// - `absolute-path` 只读例外：也可用 ✓（写死用户名，不如上面通用）
/// - App Group 容器：自签名 + 无 provisioning profile 时**授权不生效** ✗，
///   且非沙箱进程也写不进 `~/Library/Group Containers`（TCC 拦截）✗
///
/// 副作用是好的：MacQ 退出后最后一次配置仍然生效，扩展不依赖主程序在运行。
struct RightClickSharedConfig: Codable, Equatable, Sendable {
    /// 总开关；关闭时扩展不往菜单里加任何项
    var enabled: Bool
    /// `RightClickItem.rawValue` → 是否启用
    var items: [String: Bool]
    /// 新建文件的基础名（主程序按界面语言写入：未命名 / Untitled）。
    /// 旧配置没有这个键 → 解码为 nil → 用默认中文，行为与升级前一致。
    var newFileBaseName: String?

    init(enabled: Bool, items: [String: Bool], newFileBaseName: String? = nil) {
        self.enabled = enabled
        self.items = items
        self.newFileBaseName = newFileBaseName
    }

    static let fileName = "rightclick.json"
    static let extensionBundleID = "com.mymy.macq.FinderRightClick"
    static let extensionName = "MagicRightClickFinder.appex"
    /// 共享配置的唯一位置：主程序写、扩展读
    static var configURL: URL {
        realHome.appending(path: "Library/Application Support/macq/\(fileName)")
    }

    /// 沙箱里 `NSHomeDirectory()` 指向容器而不是用户目录，所以走 `getpwuid`
    static var realHome: URL {
        if let passwd = getpwuid(getuid()), let dir = passwd.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// 读不到配置时的默认值：不显示任何菜单项（用户还没开开关）
    static let disabled = RightClickSharedConfig(enabled: false, items: [:])

    /// 缺键按关闭处理（不是「默认开」）：加了新菜单项而配置还是旧的时候
    /// 不该突然冒出来
    func isOn(_ item: RightClickItem) -> Bool { items[item.rawValue] ?? false }

    /// 该显示哪些菜单项（顺序固定，扩展按它画菜单）。
    ///
    /// 总开关关闭时为空；需要主程序的项目（进入终端）在主程序没运行时也不出现，
    /// 免得点一下把 MacQ 整个拉起来。
    var visibleItems: [RightClickItem] {
        visibleItems(isContainerMenu: true)
    }

    func visibleItems(isContainerMenu: Bool) -> [RightClickItem] {
        guard enabled else { return [] }
        return RightClickItem.allCases.filter {
            isOn($0) && (!$0.requiresHost || HostApp.isRunning) && (!$0.containerMenuOnly || isContainerMenu)
        }
    }

    /// 配置文件体检结果
    struct FileProbe: Sendable {
        let path: String
        let exists: Bool
        let bytes: Int
    }

    /// 扩展在沙箱里能不能读到配置，靠这个"看得见"——出问题直接查日志不用猜
    static func diagnostics() -> [FileProbe] {
        [configURL].map { url in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return FileProbe(
                path: url.path,
                exists: attributes != nil,
                bytes: attributes?[.size] as? Int ?? 0
            )
        }
    }

    /// 扩展侧读取入口：读不到就当「全部关闭」，绝不因为配置缺失而误显示菜单项
    static func load() -> RightClickSharedConfig {
        read(from: configURL) ?? .disabled
    }

    static func read(from url: URL) -> RightClickSharedConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RightClickSharedConfig.self, from: data)
    }

    /// 写入共享配置，返回写下的路径（供日志与设置页诊断）。`to` 便于探针写到临时位置。
    @discardableResult
    func write(to url: URL? = nil) -> URL? {
        let url = url ?? Self.configURL
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return (try? data.write(to: url, options: .atomic)) != nil ? url : nil
    }
}

/// 菜单项要用到的路径推导（纯逻辑，可测）
enum RightClickPaths {
    /// 复制路径：选中项各自一条（文件、文件夹都复制自己）；空白处右键 → 当前文件夹
    static func copyTargets(selected: [URL], targeted: URL?) -> [String] {
        if !selected.isEmpty { return selected.map(\.path) }
        guard let targeted else { return [] }
        return [targeted.path]
    }

    /// 进入终端：选中文件 → 它所在文件夹；选中文件夹 → 自身；空白处 → 当前文件夹
    static func terminalFolder(selected: [URL], targeted: URL?) -> URL? {
        guard let first = selected.first else { return targeted }
        return containerFolder(of: first)
    }

    /// 新建文件：当前目录里第一个没被占用的名字（未命名.txt → 未命名 2.txt → …）。
    /// 基础名由调用方传入（主程序按当前界面语言本地化；扩展从共享配置读），
    /// 因为这个文件同时编进扩展 target，引用不了主程序的 AppLanguage。
    static func newFileName(existing: Set<String>, baseName: String = "未命名") -> String {
        let first = "\(baseName).txt"
        if !existing.contains(first) { return first }
        var n = 2
        while existing.contains("\(baseName) \(n).txt") { n += 1 }
        return "\(baseName) \(n).txt"
    }

    /// 生成「选中文件并按回车进入重命名」的 AppleScript（纯逻辑，可测转义）。
    /// key code 36 = Return；发给 Finder 进程而不是 frontmost，避免竞态。
    static func renameAppleScript(for path: String) -> String {
        let escaped = path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return """
        tell application "Finder"
            activate
            reveal (POSIX file "\(escaped)" as alias)
        end tell
        delay 0.35
        tell application "System Events"
            tell process "Finder" to key code 36
        end tell
        """
    }

    /// 在 folder 里建一个空文件；返回建出来的 URL（失败返回 nil，沙箱被拒就是这个）
    static func createNewFile(in folder: URL, baseName: String = "未命名") -> URL? {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let url = folder.appending(path: newFileName(existing: names, baseName: baseName))
        let ok = FileManager.default.createFile(atPath: url.path, contents: Data())
        return ok ? url : nil
    }

    /// 目录判定：先用 URL 自带的类型信息，再退回文件系统
    /// （沙箱里的扩展未必有权限 stat 用户文件，`hasDirectoryPath` 是 Finder 给的，
    /// 不依赖文件系统访问）
    static func containerFolder(of url: URL) -> URL? {
        if url.hasDirectoryPath { return url }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }
}

/// 终端应用：探测已安装的、按 bundle id 打开文件夹
enum TerminalApp {
    static let systemBundleID = "com.apple.Terminal"

    struct Installed: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// 已卸载的选项会是 nil（设置页用它显示占位文案）
        let url: URL?
    }

    /// 设置页里认得的终端（只列出真正装了的）
    static let known: [(id: String, name: String)] = [
        (systemBundleID, "终端"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("co.zeit.hyper", "Hyper"),
    ]

    static func installed() -> [Installed] {
        known.compactMap { entry in
            guard let url = url(forBundleID: entry.id) else { return nil }
            return Installed(id: entry.id, name: entry.name, url: url)
        }
    }

    static func url(forBundleID id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    /// 在指定文件夹打开终端；返回是否成功发起（拿不到终端 app 就算失败）
    @discardableResult
    static func open(folder: URL, bundleID: String) -> Bool {
        guard let app = url(forBundleID: bundleID) ?? url(forBundleID: systemBundleID) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration) { _, error in
            if let error {
                Logger(subsystem: "com.mymy.macq", category: "rightclick")
                    .error("打开终端失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        return true
    }
}

/// 主程序与访达扩展之间的 URL 通道。
///
/// 为什么需要它：扩展是沙箱进程，实测**不能**把文件夹 URL 交给终端
/// （`open([folder], withApplicationAt:)` 被系统拒绝：没有权限打开），
/// 只把路径当字符串参数传给终端也不行（终端已在运行时参数会被忽略）。
/// 所以扩展只把请求编码成 URL 交给系统，由非沙箱的主程序执行。
///
/// 注意：这条通道会**启动**主程序（如果没在运行），所以扩展只在
/// 主程序已经运行时才把依赖它的菜单项放出来（见 `RightClickItem.requiresHost`）。
enum AppURL {
    static let scheme = "macq"

    enum Request: Equatable {
        case openTerminal(folder: URL)
        case newFile(folder: URL)
    }

    static func url(for request: Request) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        switch request {
        case .openTerminal(let folder):
            components.host = "terminal"
            components.queryItems = [URLQueryItem(name: "path", value: folder.path)]
        case .newFile(let folder):
            components.host = "newfile"
            components.queryItems = [URLQueryItem(name: "path", value: folder.path)]
        }
        return components.url
    }

    static func request(from url: URL) -> Request? {
        guard url.scheme == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value,
              !path.isEmpty
        else { return nil }
        switch components.host {
        case "terminal": return .openTerminal(folder: URL(fileURLWithPath: path))
        case "newfile": return .newFile(folder: URL(fileURLWithPath: path))
        default: return nil
        }
    }

    /// 扩展侧：交给系统打开（沙箱允许，实测通过）
    ///
    /// `activates = false` 是关键：默认会让系统激活 MacQ，把主窗口顶到最前
    /// （实测窗口顺序从 Finder→MacQ 变成 MacQ→Finder，每次右键都闪一下窗口）。
    @discardableResult
    static func send(_ request: Request) -> Bool {
        guard let url = url(for: request) else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.open(url, configuration: configuration) { _, error in
            guard let error else { return }
            Logger(subsystem: "com.mymy.macq", category: "rightclick")
                .error("转交主程序失败：\(error.localizedDescription, privacy: .public)")
        }
        return true
    }

    /// 主程序侧：只接受真实存在的文件夹（URL 来自扩展，但仍按不可信输入处理）
    static func existingFolder(at path: String) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else { return nil }
        return URL(fileURLWithPath: path)
    }
}
