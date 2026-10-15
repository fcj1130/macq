import AppKit
import OSLog
import SwiftUI

/// 历史窗口的展示状态。窗口持有它，SwiftUI 视图只负责渲染 + 双向绑定。
///
/// 关键字/类型/选中项都放在这里，是为了让「每次唤起都重置」这件事在 `show()` 里**同步**发生
/// （放在视图的 @State 里做不到：SwiftUI 状态更新滞后一拍，会先闪一下上次的内容）。
@MainActor
@Observable
final class PickerState {
    var query = ""
    var kind: ClipKind?
    var limit = 200
    /// 选中项在**当前可见列表**中的下标：唤起时落在第一条
    var selected = 0
    /// 每次唤起自增：视图据此把搜索框焦点收回来、滚动回顶部
    var presentation = 0

    func resetForPresentation() {
        query = ""
        kind = nil
        limit = 200
        selected = 0
        presentation += 1
    }
}

/// 剪贴板历史窗口：**与主窗口互相独立的浮动面板**。
///
/// 用 `NSPanel` + `.nonactivatingPanel`：能拿到键盘焦点，但**不激活 macq**。
/// 所以唤出/收起都不会把主窗口拽到前台，也不会打断你正在用的 app——两个窗口互不影响。
///
/// 键盘处理也在这里（而不是 SwiftUI 的 onKeyPress）：本地事件监听能稳定拿到本窗口的按键，
/// 不受 SwiftUI 焦点系统影响。↑↓ 切换、⏎ 粘贴、esc 收起、直接打字即搜索。
private let logger = Logger(subsystem: "com.mymy.macq", category: "clipboard-picker")

@MainActor
final class ClipboardPickerWindow: NSObject, NSWindowDelegate {
    private let window: NSPanel
    private let tool: MagicClipboard
    let state = PickerState()

    private var keyMonitor: Any?
    /// 浮层语义：失去键盘焦点就收起（点别处、切 app、点桌面）
    var onFocusLost: (() -> Void)?
    /// 唤起前的最前台 app：用鼠标点窗口会让系统把 macq 激活（主窗口跟到前台、原 app 掉焦点），
    /// 收起时要把焦点还回去，否则合成的 ⌘V 粘不进原来的编辑器
    private(set) var previousAppPID: pid_t?

    init(tool: MagicClipboard) {
        self.tool = tool
        let hosting = NSHostingController(rootView: ClipboardPickerView(tool: tool, state: state)
                    .environment(\.locale, Locale(identifier: AppLanguage.stored.localeIdentifier)))
        hosting.sizingOptions = []   // 由窗口决定尺寸，别让 SwiftUI 反向拟合
        let panel = NSPanel(contentViewController: hosting)
        panel.title = AppLanguage.localized("剪贴板历史")
        panel.styleMask = [.titled, .closable, .resizable, .nonactivatingPanel]
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false   // 切到别的 app 也留着，跟主窗口无关
        // .moveToActiveSpace 与 .canJoinAllSpaces 互斥（同时给会直接抛异常）
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.setContentSize(NSSize(width: 580, height: 560))
        panel.minSize = NSSize(width: 420, height: 320)
        panel.setFrameAutosaveName("ClipboardPickerWindow")
        self.window = panel
        super.init()
        panel.delegate = self
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event -> NSEvent? in
            // 本地监视器固定在主线程回调；包一层 assumeIsolated 只为标注隔离，不弱化语义。
            // NSEvent 非 Sendable，不能跨隔离传递，所以把判定结果先落地再返回。
            let consumed: Bool = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return consumed ? nil : event
        }
    }

    // MARK: - 显示 / 隐藏

    var isVisible: Bool { window.isVisible }

    /// 供探针构造 NSEvent 用（窗口号必须对，否则 handle 的窗口校验会放行）
    var windowNumber: Int { window.windowNumber }

    func show() {
        // 每次唤起都是一份干净的状态：关键字清空、类型回到「全部」、选中回到第一条
        state.resetForPresentation()

        // 记住唤起前谁在最前台。点窗口内部（而不是按键盘）时，系统会把 macq 激活，
        // 这时原来的 app 就掉了焦点 —— 收起时要还给它，不然粘贴打到我们自己窗口上。
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousAppPID = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? nil : frontmost?.processIdentifier

        // 刻意不调用 NSApp.activate：那会把 macq 整个激活、主窗口跟到前台，就"关联"上了。
        // 非激活面板自己可以拿键盘焦点。
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()

        // 焦点要求是「在第一条记录上」而不是输入框：SwiftUI 会给窗口里第一个输入框自动聚焦，
        // 这里延后一拍把它收回（用户之后主动点输入框不受影响，那时这拍早过了）
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window.isKeyWindow else { return }
            if self.window.firstResponder is NSTextView { self.window.makeFirstResponder(nil) }
        }
    }

    func hide() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        restoreFocusToPreviousApp()
    }

    /// 收起时该把焦点交还给谁：只有在「我们自己变成了最前台」时才需要还回去。
    /// 不加这个限制的话，用户开着浮层又切到别的 app，收起时就会把他从那个 app 里拽走。
    static func restorationTarget(previous: pid_t?, current: pid_t?, own: pid_t) -> pid_t? {
        guard let previous, previous != own, current == own else { return nil }
        return previous
    }

    private func restoreFocusToPreviousApp() {
        let current = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let target = Self.restorationTarget(previous: previousAppPID, current: current,
                                                  own: ProcessInfo.processInfo.processIdentifier),
              let app = NSRunningApplication(processIdentifier: target)
        else { return }
        logger.info("收起剪贴板窗口：焦点交还给 pid \(target, privacy: .public)（当前最前台=我们自己）")
        app.activate()
    }

    func windowDidResignKey(_ notification: Notification) {
        // 延后一拍再收：右键菜单跟踪、拖拽等场景会短暂失焦又不恢复，那时不该收窗口
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.window.isKeyWindow else { return }
            self.hide()
            self.onFocusLost?()
        }
    }

    // MARK: - 键盘

    /// 返回 true 表示这个按键已被消费（不再往下传）
    ///
    /// internal 而非 private：真实按键在 CLI 探针进程里到不了窗口（没有事件循环在拉队列），
    /// 探针只能构造 NSEvent 直接驱动这里。
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard event.window === window, window.isVisible else { return false }

        switch event.keyCode {
        case 126: return move(-1)                       // ↑
        case 125: return move(1)                        // ↓
        case 36, 76: return activateSelection()         // ⏎ / 小键盘 ⏎
        case 53: hide(); onFocusLost?(); return true    // esc
        default: break
        }

        // 输入框正在编辑时，⌫ 和字符交给它自己处理（避免重复插入、也保留正常编辑）
        guard !(window.firstResponder is NSTextView) else { return false }

        switch event.keyCode {
        case 51:                                        // ⌫
            guard !state.query.isEmpty else { return false }
            state.query.removeLast()
        default:
            // 非 ASCII 也要接：中文直接打字同样应当当作搜索词（输入法组合文本走输入框那条路）
            guard let text = event.characters, !text.isEmpty,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
            else { return false }
            state.query += text
        }
        state.selected = 0
        clampSelection()
        return true
    }

    private func move(_ delta: Int) -> Bool {
        let count = visibleItems.count
        guard count > 0 else { return true }
        state.selected = min(max(0, state.selected + delta), count - 1)
        return true
    }

    private func activateSelection() -> Bool {
        let items = visibleItems
        guard items.indices.contains(state.selected) else {
            if let first = items.first { tool.reuse(first) }
            return true
        }
        tool.reuse(items[state.selected])
        return true
    }

    private func clampSelection() {
        state.selected = min(state.selected, max(0, visibleItems.count - 1))
    }

    private var visibleItems: [ClipItem] {
        tool.store.query(kind: state.kind, text: state.query, limit: state.limit)
    }
}
