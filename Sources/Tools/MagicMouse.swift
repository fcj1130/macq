import AppKit
import Observation
import OSLog

/// 魔法鼠标：滚轮平滑、速度、方向翻转。配置持久化在 UserDefaults 的 magicMouse 命名空间，引擎随开关启停。
@MainActor
@Observable
final class MagicMouse: ToggleableTool, PermissionReporting {
    /// 工具是进程级的系统钩子（事件 tap / 全局监听），必须全局唯一：
    /// 每个窗口各持一份会导致重复拦截、一个开关关不掉另一个窗口的监听。
    static let shared = MagicMouse()

    var enabled: Bool { didSet { persist(); syncEngine() } }
    var smooth: Bool { didSet { persist(); pushConfig() } }
    var speed: Double { didSet { persist(); pushConfig() } }
    var invertVertical: Bool { didSet { persist(); pushConfig() } }
    var invertHorizontal: Bool { didSet { persist(); pushConfig() } }

    /// 引擎是否真的在拦截事件
    private(set) var running = false
    /// 是否已获得辅助功能权限（发事件 / 控制电脑）
    private(set) var trusted = AXIsProcessTrusted()
    /// 是否已获得输入监控权限（事件 tap 监听）
    private(set) var listenAccess = CGPreflightListenEventAccess()
    /// 上一次事件 tap 启动失败的原因
    private(set) var tapFailure: String?

    private let tap = ScrollTap()
    private let logger = Logger(subsystem: "com.mymy.macq", category: "magicmouse")

    /// 配置命名空间与版本：改动配置结构时 schema +1，并在 migrations 里补一步
    private static let schema = 1
    /// 配置迁移表（当前无）：例 `[2: { $0.set($0.double("speed", 1) * 2, "speed") }]`
    private static let migrations: [Int: (ToolSettings) -> Void] = [:]
    private let settings: ToolSettings

    init() {
        let settings = ToolSettings(tool: "magicMouse", schema: Self.schema)
        settings.migrate(Self.migrations)
        enabled = settings.bool("enabled", false)
        smooth = settings.bool("smooth", true)
        speed = settings.double("speed", 1.0)
        invertVertical = settings.bool("invertVertical", false)
        invertHorizontal = settings.bool("invertHorizontal", false)
        self.settings = settings
        syncEngine()
        log("启动 副本=\(Bundle.main.bundlePath)")

        // 授权后系统通常要求重启 app；回到前台时顺手重试一次
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermission() }
        }
    }

    /// 弹出系统授权对话框；授权后一般需要重启 app 才生效
    func requestPermission() {
        SystemPermissions.request()
        trusted = SystemPermissions.trusted
        listenAccess = SystemPermissions.listenAccess
        syncEngine()
    }

    func refreshPermission() {
        trusted = AXIsProcessTrusted()
        listenAccess = CGPreflightListenEventAccess()
        if enabled { syncEngine() }
        log("手动重新检测")
    }

    /// 打开「隐私与安全性 › 辅助功能」设置页
    func openAccessibilitySettings() {
        SystemPermissions.openAccessibilitySettings()
    }

    /// 打开「隐私与安全性 › 输入监控」设置页
    func openInputMonitoringSettings() {
        SystemPermissions.openInputMonitoringSettings()
    }

    /// 重启 app（授权后需要）
    func relaunch() {
        SystemPermissions.relaunch()
    }

    /// 给用户看的权限提示（缺什么权限、下一步做什么）
    var permissionHint: String {
        if !trusted {
            return AppLanguage.localized("MacQ 需要「辅助功能」权限才能改写滚轮事件：点「请求授权」→ 系统弹窗里打开设置 → 勾选 MacQ。")
        }
        if !listenAccess {
            return AppLanguage.localized("「辅助功能」已授权，但拦截滚轮还需要「输入监控」权限（系统设置 › 隐私与安全性 › 输入监控）。")
        }
        return AppLanguage.localized("权限看起来都给了，事件引擎却启动失败——把下面这行体检结果发给我。")
    }

    /// 可复制的体检结果
    var permissionDiagnostic: String {
        String(format: AppLanguage.localized("辅助功能=%@ · 输入监控=%@ · 引擎=%@"), trusted ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"), listenAccess ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"), running ? AppLanguage.localized("运行中") : (tapFailure ?? AppLanguage.localized("未启动")))
    }

    private func syncEngine() {
        if enabled {
            trusted = AXIsProcessTrusted()
            listenAccess = CGPreflightListenEventAccess()
            if tap.start() {
                running = true
                tapFailure = nil
            } else {
                running = false
                tapFailure = SystemPermissions.failureHint
            }
        } else {
            tap.stop()
            running = false
            tapFailure = nil
        }
        pushConfig()
        log("同步引擎")
    }

    private func log(_ what: String) {
        logger.info("\(what, privacy: .public) 已开启=\(self.enabled, privacy: .public) 辅助功能=\(self.trusted, privacy: .public) 输入监控=\(self.listenAccess, privacy: .public) 运行中=\(self.running, privacy: .public) 失败原因=\(self.tapFailure ?? "无", privacy: .public)")
    }

    private func pushConfig() {
        tap.update(ScrollTap.Config(
            smooth: smooth,
            speed: speed,
            invertVertical: invertVertical,
            invertHorizontal: invertHorizontal
        ))
    }

    private func persist() {
        settings.set(enabled, "enabled")
        settings.set(smooth, "smooth")
        settings.set(speed, "speed")
        settings.set(invertVertical, "invertVertical")
        settings.set(invertHorizontal, "invertHorizontal")
    }
}
