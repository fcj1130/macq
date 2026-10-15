import AppKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "com.mymy.macq", category: "devtoolbox")

/// 开发者工具箱浮层窗口：与剪贴板历史窗口同一套浮层语义。
///
/// NSPanel + .nonactivatingPanel：能拿键盘焦点但不激活 MacQ，与主窗口互不影响；
/// 失焦自动收起；esc 收起。↑↓ 在左侧工具导航间切换。
@MainActor
final class DevToolboxWindow: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let tool: DevToolbox
    let state: DevToolboxPanelState

    private var keyMonitor: Any?
    private(set) var previousAppPID: pid_t?

    /// 常驻模式：失焦不收起（用户要求）。关闭途径：esc / 再按一次快捷键 / 窗口关闭按钮

    init(tool: DevToolbox) {
        self.tool = tool
        // 默认选中用户排序的第一个工具，而不是写死 JSON
        let first = tool.order.first ?? DevTool.allCases.first!
        state = DevToolboxPanelState(selected: first)
        let hosting = NSHostingController(rootView: DevToolboxPanelView(tool: tool, state: state)
                    .environment(\.locale, Locale(identifier: AppLanguage.stored.localeIdentifier)))
        hosting.sizingOptions = []   // 由窗口决定尺寸，别让 SwiftUI 反向拟合
        let panel = NSPanel(contentViewController: hosting)
        panel.title = AppLanguage.localized("开发者工具箱")
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .normal          // 普通层级：不压在其它窗口上面，点别的窗口会被盖住
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false   // 切到别的 app 也留着，跟主窗口无关
        // .moveToActiveSpace 与 .canJoinAllSpaces 互斥（同时给会抛异常）；
        // moveToActiveSpace：快捷键唤起时会出现在当前空间，平时不跟随切换
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.setContentSize(NSSize(width: 720, height: 480))
        panel.minSize = NSSize(width: 560, height: 360)
        panel.setFrameAutosaveName("DevToolboxWindow")
        self.window = panel
        super.init()
        panel.delegate = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            // 本地监视器固定在主线程回调；NSEvent 非 Sendable，判定结果先落地再返回
            let consumed: Bool = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    // MARK: - 显示 / 隐藏

    var isVisible: Bool { window.isVisible }

    /// 是否是当前活动窗口：可见但被其它窗口盖住时为 false。
        /// 快捷键的开关判定用它：被盖住时再按快捷键应该是「拉到最前」而不是「先藏再弹」。
    var isKey: Bool { window.isKeyWindow }

    /// 供探针构造 NSEvent 用
    var windowNumber: Int { window.windowNumber }

    func show() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousAppPID = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : frontmost?.processIdentifier

        // 刻意不调 NSApp.activate：非激活面板自己能拿键盘焦点，激活会把主窗口拽到前台
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        restoreFocusToPreviousApp()
    }

    /// 收起时该把焦点交还给谁：只有「我们自己变成了最前台」才需要还（语义与剪贴板窗口一致）
    private func restoreFocusToPreviousApp() {
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let target = ClipboardPickerWindow.restorationTarget(
            previous: previousAppPID, current: current,
            own: ProcessInfo.processInfo.processIdentifier),
            let app = NSRunningApplication(processIdentifier: target)
        else { return }
        logger.info("收起开发者工具箱：焦点交还给 pid \(target, privacy: .public)")
        app.activate()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 刻意留空：本面板失焦不消失（与剪贴板历史窗口的浮层语义不同）。
        // 不删方法是为了把意图写在这里，避免以后看着 delegate 缺口误补回自动收起。
    }

    // MARK: - 键盘

    /// 返回 true 表示按键已消费。esc 收起、↑↓ 切工具、⌘⇧] / ⌘⇧[ 前后切换
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, window.isVisible else { return false }

        // 输入框编辑中的按键交给输入框（esc 除外）
        let editing = window.firstResponder is NSTextView

        switch event.keyCode {
        case 53: hide(); return true                                     // esc
        case 126: if !editing { move(-1); return true }                  // ↑
        case 125: if !editing { move(1); return true }                   // ↓
        default: break
        }
        return false
    }

    /// ↑↓ 在当前导航顺序（含拖拽后的新顺序）里前后移动
    private func move(_ delta: Int) {
        let order = tool.order
        guard let index = order.firstIndex(of: state.selected) else { return }
        let next = min(max(0, index + delta), order.count - 1)
        guard order.indices.contains(next) else { return }
        state.selected = order[next]
    }
}

/// 面板状态：当前选中工具。窗口持有，键盘导航直接改它。
@MainActor
@Observable
final class DevToolboxPanelState {
    var selected: DevTool

    init(selected: DevTool = .json) {
        self.selected = selected
    }
}
