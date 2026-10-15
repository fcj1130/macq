import AppKit
import Observation
import OSLog

/// 魔法剪贴板：剪贴板历史 + 全局快捷键调用窗口。
///
/// 读剪贴板用 NSPasteboard、组合键用 Carbon，这两项不需要权限；
/// 但**双击修饰键**需要辅助功能 + 输入监控，**贴图（合成 ⌘V）**需要辅助功能。
@MainActor
@Observable
final class MagicClipboard: ToggleableTool, PermissionReporting {
    /// 工具是进程级的系统钩子（全局快捷键 / 事件 tap / 剪贴板轮询），必须全局唯一：
    /// 每个窗口各持一份会各自注册一次监听，双击一次弹出两个窗口，关掉其中一个另一个照弹。
    static let shared = MagicClipboard()

    static let defaultMaxBytes = 1024 * 1024 * 1024   // 1 GB

    /// 占用上限可选项
    static let sizePresets: [(title: String, bytes: Int)] = [
        ("256 MB", 256 * 1024 * 1024),
        ("512 MB", 512 * 1024 * 1024),
        ("1 GB", 1024 * 1024 * 1024),
        ("2 GB", 2 * 1024 * 1024 * 1024),
        ("5 GB", 5 * 1024 * 1024 * 1024),
        ("10 GB", 10 * 1024 * 1024 * 1024),
    ]

    var enabled: Bool {
        didSet {
            settings.set(enabled, "enabled")
            sync()
        }
    }

    var maxBytes: Int {
        didSet {
            settings.set(maxBytes, "maxBytes")
            store.enforce(maxBytes: maxBytes, retention: retention)
        }
    }

    var retention: ClipRetention {
        didSet {
            settings.set(retention.rawValue, "retention")
            store.enforce(maxBytes: maxBytes, retention: retention)
        }
    }

    var trigger: HotKeyTrigger {
        didSet {
            saveTrigger()
            registerHotKey()
        }
    }

    /// 唤起方式注册失败的原因（组合键被占用 / 双击修饰键缺权限），nil 表示正常
    private(set) var triggerFailure: String?
    /// 辅助功能 / 输入监控权限（双击修饰键才需要）
    private(set) var trusted = SystemPermissions.trusted
    private(set) var listenAccess = SystemPermissions.listenAccess

    let store: ClipboardStore
    let recorder = HotKeyRecorder()

    /// 配置命名空间与版本：改动配置结构时 schema +1，并在 migrations 里补一步
    private static let schema = 1
    /// 配置迁移表（当前无）：例 `[2: { $0.set($0.int("maxMB", 1024) * 1024 * 1024, "maxBytes") }]`
    private static let migrations: [Int: (ToolSettings) -> Void] = [:]
    private let settings: ToolSettings
    private let monitor: ClipboardMonitor
    private let hotKey: GlobalHotKey
    private let doubleTap = ModifierDoubleTapMonitor()
    private let logger = Logger(subsystem: "com.mymy.macq", category: "clipboard")
    private(set) var picker: ClipboardPickerWindow?
    private var sweepTimer: Timer?
    private var terminateObserver: NSObjectProtocol?

    init(store: ClipboardStore? = nil) {
        let store = store ?? ClipboardStore()
        self.store = store

        let settings = ToolSettings(tool: "magicClipboard", schema: Self.schema)
        settings.migrate(Self.migrations)
        enabled = settings.bool("enabled", false)
        maxBytes = settings.int("maxBytes", Self.defaultMaxBytes)
        retention = settings.raw("retention", .forever)
        trigger = Self.loadTrigger(settings.data("trigger")) ?? .default
        self.settings = settings

        let monitor = ClipboardMonitor(store: store)
        self.monitor = monitor
        hotKey = GlobalHotKey()

        monitor.limits = { [weak self] in
            guard let self else { return (Self.defaultMaxBytes, .forever) }
            return (self.maxBytes, self.retention)
        }
        hotKey.onFire = { [weak self] in self?.fire() }
        doubleTap.onFire = { [weak self] in self?.fire() }
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.flush() }
        }

        sync()
    }

    var isRecording: Bool { monitor.isRunning }

    // MARK: - 开关

    private func sync() {
        if enabled {
            monitor.start()
            registerHotKey()
            startSweep()
        } else {
            monitor.stop()
            hotKey.unregister()
            doubleTap.stop()
            sweepTimer?.invalidate()
            sweepTimer = nil
        }
        logger.info("同步开关 已启用=\(self.enabled, privacy: .public) 监听中=\(self.monitor.isRunning, privacy: .public) 双击监听中=\(self.doubleTap.running, privacy: .public)")
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
                logger.error("全局快捷键注册失败：\(combo.display, privacy: .public)（可能被其它 app 占用）")
            }
        case .doubleTap(let modifier):
            if doubleTap.start(modifier) {
                triggerFailure = nil
            } else {
                triggerFailure = SystemPermissions.failureHint
                logger.error("双击修饰键监听失败：\(self.trigger.display, privacy: .public) 原因=\(self.triggerFailure ?? "", privacy: .public)")
            }
        }
    }

    /// 录制中不要弹窗（用户正在按修饰键）
    private func fire() {
        guard enabled else {
            // 走到这里说明有陈旧的注册没被清掉（关闭开关后仍能唤起），打出来便于定位
            logger.error("唤起被拦截：已关闭但监听仍在触发（\(self.trigger.display, privacy: .public)）")
            return
        }
        guard !recorder.isRecording else { return }
        showPicker()
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

    /// 给用户看的权限提示（缺什么权限、下一步做什么）
    var permissionHint: String {
        if !trusted {
            return AppLanguage.localized("MacQ 需要「辅助功能」权限才能双击修饰键唤起、粘贴后合成 ⌘V：点「请求授权」→ 系统弹窗里打开设置 → 勾选 MacQ。")
        }
        if !listenAccess {
            return AppLanguage.localized("「辅助功能」已授权，但监听修饰键双击还需要「输入监控」权限（系统设置 › 隐私与安全性 › 输入监控）。")
        }
        return AppLanguage.localized("权限看起来都给了，但唤起方式仍注册失败——把下面这行体检结果发给我。")
    }

    /// 可复制的体检结果
    var permissionDiagnostic: String {
        String(format: AppLanguage.localized("辅助功能=%@ · 输入监控=%@"), trusted ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"), listenAccess ? AppLanguage.localized("已授权") : AppLanguage.localized("未授权"))
    }

    /// 保留期到期不一定伴随新复制，定期扫一次
    private func startSweep() {
        sweepTimer?.invalidate()
        sweepTimer = Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [self] _ in
            MainActor.assumeIsolated {
                self.store.enforce(maxBytes: self.maxBytes, retention: self.retention)
            }
        }
    }

    // MARK: - 历史窗口

    func showPicker() {
        // 全局快捷键是否真的送达，只能靠这行日志验证（合成按键在 CLI 进程里不派发 Carbon 事件）
        logger.info("唤起剪贴板窗口（\(self.trigger.display, privacy: .public)）")
        if picker == nil {
            let window = ClipboardPickerWindow(tool: self)
            // 失焦自动收起（浮层语义），所有状态变更都走 hidePicker，日志与状态集中在一处
            window.onFocusLost = { [weak self] in self?.hidePicker() }
            picker = window
        }
        picker?.show()
    }

    func hidePicker() {
        logger.info("隐藏剪贴板窗口")
        picker?.hide()
    }

    var isPickerVisible: Bool { picker?.isVisible ?? false }

    func reuse(_ item: ClipItem) {
        guard monitor.reuse(item) else { return }
        // 收起前取目标：窗口收起时会把焦点还给唤起前的那个 app
        let target = picker?.previousAppPID
        logger.info("复用：唤起前 app=\(target ?? 0, privacy: .public) 当前最前台=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0, privacy: .public) macq 已被激活=\(NSApp.isActive, privacy: .public)")
        hidePicker()
        // 「复用」= 真的粘贴。等焦点回到原来那个 app 再投 ⌘V，
        // 否则按键会打到我们自己的窗口上（用鼠标点窗口时系统会把 macq 激活）
        guard SystemPermissions.trusted else {
            logger.error("复用：缺少辅助功能权限，内容已进剪贴板但无法自动粘贴")
            return
        }
        Self.postPaste(whenFrontmost: target, attempts: 12)
    }

    /// 合成 ⌘V。目标 app 还没拿回焦点就等一拍重试（最多 ~600ms），
    /// 投完就结束，避免按键打到我们自己的窗口上
    private static let pasteLogger = Logger(subsystem: "com.mymy.macq", category: "clipboard")
    private static func postPaste(whenFrontmost target: pid_t?, attempts: Int) {
        let own = ProcessInfo.processInfo.processIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let target, target != own, front != target, attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                postPaste(whenFrontmost: target, attempts: attempts - 1)
            }
            return
        }
        Self.pasteLogger.info("投递 ⌘V：目标 pid \(target ?? own, privacy: .public) 当前最前台 \(front ?? own, privacy: .public)")
        sendPaste()
    }

    /// 合成 ⌘V。事件源显式清零压制间隔，否则投递后 0.25s 内真实输入会被系统压住
    private static func sendPaste() {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func delete(_ item: ClipItem) {
        store.delete([item.id])
    }

    func clear() {
        store.clear()
    }

    // MARK: - 快捷键持久化

    private func saveTrigger() {
        guard let data = try? JSONEncoder().encode(trigger) else { return }
        settings.set(data, "trigger")
    }

    private static func loadTrigger(_ data: Data?) -> HotKeyTrigger? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(HotKeyTrigger.self, from: data)
    }

    func resetTrigger() {
        trigger = .default
    }
}
