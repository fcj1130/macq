import AppKit
import Carbon.HIToolbox
import Observation
import OSLog

/// 开发者工具箱：全局快捷键唤起浮层面板，内置常用转换工具。
///
/// 体验对齐魔法剪贴板：NSPanel + .nonactivatingPanel（不激活 MacQ、与主窗口互不影响），
/// 失焦自动收起。组合键不需要权限；双击修饰键需要辅助功能 + 输入监控（权限 UI 与魔法剪贴板共用）。
@MainActor
@Observable
final class DevToolbox: ToggleableTool, PermissionReporting {
    /// 进程级系统钩子（全局快捷键），必须全局唯一
    static let shared = DevToolbox()

    var enabled: Bool {
        didSet {
            settings.set(enabled, "enabled")
            sync()
        }
    }

    var trigger: HotKeyTrigger {
        didSet {
            saveTrigger()
            registerHotKey()
        }
    }

    /// 唤起方式注册失败的原因，nil 表示正常
    private(set) var triggerFailure: String?
    private(set) var trusted = SystemPermissions.trusted
    private(set) var listenAccess = SystemPermissions.listenAccess

    /// 面板导航顺序（可拖拽调整）
    var order: [DevTool] {
        didSet { settings.set(order.map(\.rawValue), "order") }
    }

    let recorder = HotKeyRecorder()

    private static let schema = 1
    private static let migrations: [Int: (ToolSettings) -> Void] = [:]
    private let settings: ToolSettings
    private let hotKey = GlobalHotKey()
    private let doubleTap = ModifierDoubleTapMonitor()
    private let logger = Logger(subsystem: "com.mymy.macq", category: "devtoolbox")
    private(set) var panel: DevToolboxWindow?

    init(settings: ToolSettings? = nil) {
        let settings = settings ?? ToolSettings(tool: "devToolbox", schema: Self.schema)
        settings.migrate(Self.migrations)
        enabled = settings.bool("enabled", false)
        trigger = Self.loadTrigger(settings.data("trigger")) ?? Self.defaultTrigger
        if let data = settings.data("password"), let c = try? JSONDecoder().decode(DevToolboxCore.PasswordConfig.self, from: data) {
            password = c
        } else {
            password = DevToolboxCore.PasswordConfig()
        }
        let saved = settings.stringArray("order") ?? []
        // 存的 id 里有已下架工具时静默丢弃；新工具排在已有顺序后面
        let known = Set(DevTool.defaultOrder.map(\.rawValue))
        // 注意：初始化完成前不能在闭包/方法里碰成员（等于提前用 self），全部本地拼完再赋一次值
        var restored = saved.filter { known.contains($0) }.compactMap(DevTool.init(rawValue:))
        let placed = Set(restored)
        restored.append(contentsOf: DevTool.defaultOrder.filter { !placed.contains($0) })
        order = restored
        self.settings = settings

        hotKey.onFire = { [weak self] in self?.fire() }
        doubleTap.onFire = { [weak self] in self?.fire() }
        sync()
    }

    /// 密码生成器配置：面板读写，持久化在工具命名空间
    var password: DevToolboxCore.PasswordConfig {
        didSet {
            if let data = try? JSONEncoder().encode(password) { settings.set(data, "password") }
        }
    }

    // MARK: - 开关与快捷键

    private func sync() {
        if enabled {
            registerHotKey()
        } else {
            hotKey.unregister()
            doubleTap.stop()
            hidePanel()
        }
        logger.info("同步开关 已启用=\(self.enabled, privacy: .public) 快捷键=\(self.trigger.display, privacy: .public)")
    }

    private func registerHotKey() {
        refreshPermission()
        guard enabled else { return }
        hotKey.unregister()
        doubleTap.stop()

        switch trigger {
        case .combo(let combo):
            if hotKey.register(combo) {
                triggerFailure = nil
            } else {
                triggerFailure = AppLanguage.localized("这个组合被其它 app 占用了，换一个")
                logger.error("全局快捷键注册失败：\(combo.display, privacy: .public)")
            }
        case .doubleTap(let modifier):
            if doubleTap.start(modifier) {
                triggerFailure = nil
            } else {
                triggerFailure = SystemPermissions.failureHint
                logger.error("双击修饰键监听失败：\(self.trigger.display, privacy: .public)")
            }
        }
    }

    private func fire() {
        guard enabled else {
            logger.error("唤起被拦截：已关闭但监听仍在触发（\(self.trigger.display, privacy: .public)）")
            return
        }
        guard !recorder.isRecording else { return }
        // 开关语义：活动窗口 → 收起；被其它窗口盖住 → 拉到最前；没开 → 弹出。
        // 不能只用 isVisible：面板被盖住时它仍为 true，会出现「按一下藏、再按一下才弹」。
        if let panel, panel.isVisible, panel.isKey {
            hidePanel()
        } else {
            showPanel()
        }
    }

    // MARK: - 权限（只有双击修饰键需要）

    func refreshPermission() {
        trusted = SystemPermissions.trusted
        listenAccess = SystemPermissions.listenAccess
    }

    func requestPermission() {
        SystemPermissions.request()
        refreshPermission()
        registerHotKey()
    }

    func openAccessibilitySettings() { SystemPermissions.openAccessibilitySettings() }
    func openInputMonitoringSettings() { SystemPermissions.openInputMonitoringSettings() }
    func relaunch() { SystemPermissions.relaunch() }

    var permissionHint: String {
        if !trusted {
            return AppLanguage.localized("MacQ 需要「辅助功能」权限才能双击修饰键唤起开发者工具箱：点「请求授权」→ 系统弹窗里打开设置 → 勾选 MacQ。")
        }
        if !listenAccess {
            return AppLanguage.localized("「辅助功能」已授权，但监听修饰键双击还需要「输入监控」权限（系统设置 › 隐私与安全性 › 输入监控）。")
        }
        return AppLanguage.localized("权限看起来都给了，但唤起方式仍注册失败——把下面这行体检结果发给我。")
    }

    var permissionDiagnostic: String {
        String(format: AppLanguage.localized("辅助功能=%@ · 输入监控=%@"), trusted ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"), listenAccess ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"))
    }

    // MARK: - 面板

    func showPanel() {
        logger.info("唤起开发者工具箱（\(self.trigger.display, privacy: .public)）")
        if panel == nil {
            panel = DevToolboxWindow(tool: self)
        }
        panel?.show()
    }

    func hidePanel() {
        panel?.hide()
    }

    var isPanelVisible: Bool { panel?.isVisible ?? false }

    /// 拖拽排序：把 from 移到 to 的位置
    func move(_ from: DevTool, to: DevTool) {
        guard from != to,
              let fromIndex = order.firstIndex(of: from),
              let toIndex = order.firstIndex(of: to) else { return }
        order.remove(at: fromIndex)
        order.insert(from, at: toIndex)
    }

    // MARK: - 持久化

    private func saveTrigger() {
        guard let data = try? JSONEncoder().encode(trigger) else { return }
        settings.set(data, "trigger")
    }

    private static func loadTrigger(_ data: Data?) -> HotKeyTrigger? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(HotKeyTrigger.self, from: data)
    }

    func resetTrigger() {
        trigger = Self.defaultTrigger
    }

    /// 默认 ⌥⌘D（不与魔法剪贴板默认的双击 ⌥ 冲突；组合键不需要任何权限）
    static let defaultTrigger = HotKeyTrigger.combo(
        KeyCombo(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(optionKey | cmdKey), display: "⌥⌘D"))
}
