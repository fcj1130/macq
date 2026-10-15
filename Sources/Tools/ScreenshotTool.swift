import AppKit
import Carbon.HIToolbox
import Observation
import OSLog

/// 截图工具：全局快捷键进入选区，截完进编辑窗。
@MainActor
@Observable
final class ScreenshotTool: ToggleableTool {
    static let shared = ScreenshotTool()

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

    private(set) var triggerFailure: String?
    private(set) var trusted = SystemPermissions.trusted
    private(set) var listenAccess = SystemPermissions.listenAccess
    private(set) var screenAccess = CGPreflightScreenCaptureAccess()

    let recorder = HotKeyRecorder()

    var ink: ScreenshotCore.MarkInk {
        didSet {
            settings.set(ink.color.rawValue, "color")
            settings.set(Double(ink.stroke), "stroke")
            settings.set(Double(ink.fontSize), "fontSize")
        }
    }

    private static let schema = 1
    private static let migrations: [Int: (ToolSettings) -> Void] = [:]
    private let settings: ToolSettings
    private let hotKey = GlobalHotKey()
    private let doubleTap = ModifierDoubleTapMonitor()
    private let picker = ScreenshotPicker()
    private let logger = Logger(subsystem: "com.mymy.macq", category: "screenshot")

    init(settings: ToolSettings? = nil) {
        let settings = settings ?? ToolSettings(tool: "screenshot", schema: Self.schema)
        settings.migrate(Self.migrations)
        enabled = settings.bool("enabled", false)
        trigger = Self.loadTrigger(settings.data("trigger")) ?? Self.defaultTrigger
        let color = settings.raw("color", ScreenshotCore.MarkColor.red)
        let stroke = CGFloat(settings.double("stroke", 4))
        let fontSize = CGFloat(settings.double("fontSize", 18))
        ink = ScreenshotCore.MarkInk(color: color, stroke: stroke, fontSize: fontSize)
        self.settings = settings
        hotKey.onFire = { [weak self] in self?.fire() }
        doubleTap.onFire = { [weak self] in self?.fire() }
        picker.onCancel = { }
        sync()
    }

    private func sync() {
        if enabled { registerHotKey() }
        else {
            hotKey.unregister()
            doubleTap.stop()
            if picker.isActive { picker.cancel() }
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
                triggerFailure = "这个组合被其它 app 占用了，换一个"
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
            logger.error("唤起被拦截：已关闭但监听仍在触发")
            return
        }
        guard !recorder.isRecording else { return }
        if picker.isActive { picker.cancel() }
        else { capture() }
    }

    func capture() {
        refreshPermission()
        logger.info("开始截图（\(self.trigger.display, privacy: .public)）")
        picker.start()
    }

    func refreshPermission() {
        trusted = SystemPermissions.trusted
        listenAccess = SystemPermissions.listenAccess
        screenAccess = CGPreflightScreenCaptureAccess()
    }

    func requestScreenAccess() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermission()
    }

    func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func requestPermission() {
        SystemPermissions.request()
        refreshPermission()
        registerHotKey()
    }

    func openAccessibilitySettings() { SystemPermissions.openAccessibilitySettings() }
    func openInputMonitoringSettings() { SystemPermissions.openInputMonitoringSettings() }
    func relaunch() { SystemPermissions.relaunch() }

    private func saveTrigger() {
        guard let data = try? JSONEncoder().encode(trigger) else { return }
        settings.set(data, "trigger")
    }

    private static func loadTrigger(_ data: Data?) -> HotKeyTrigger? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(HotKeyTrigger.self, from: data)
    }

    func resetTrigger() { trigger = Self.defaultTrigger }

    /// 默认 ⇧⌘S（系统截图是 ⇧⌘3/4/5，不冲突）
    static let defaultTrigger = HotKeyTrigger.combo(
        KeyCombo(keyCode: UInt32(kVK_ANSI_S), carbonModifiers: UInt32(shiftKey | cmdKey), display: "⇧⌘S"))
}
