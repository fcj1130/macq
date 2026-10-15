import AppKit
import os

/// 菜单栏图标 + 主窗口显隐。
///
/// - 菜单栏常驻图标，点开是「显示主界面 / 退出 MacQ」
/// - 点窗口左上角 × 收起主界面，并从 Dock / ⌘Tab 里撤掉（之后只存在于菜单栏）
/// - 窗口对象留着不销毁，所以「显示主界面」是原样叫回来，不是重建
/// - 真正退出走菜单里的「退出 MacQ」（或 ⌘Q）
///
/// 只在主线程用（状态栏和窗口都是主线程对象）。
final class AppShell: NSObject, NSWindowDelegate {
    static let shared = AppShell()

    private let log = Logger(subsystem: "com.mymy.macq", category: "appshell")

    /// 菜单栏图标资源。使用 template image，自动适配浅色/深色菜单栏。
    static let statusIconResourceName = "menuicon"
    static let fallbackStatusIconName = "wrench.and.screwdriver"

    /// 主窗口：关掉只是隐藏，所以这里一直留着引用（weak —— 真被销毁时自动变 nil）
    private(set) weak var mainWindow: NSWindow?
    private(set) var statusItem: NSStatusItem?

    /// 启动时调用一次（重复调用不会多出一个菜单栏图标）
    func install() {
        guard statusItem == nil else { return }
        installStatusItem()
        // 图标来源由 installStatusItem() 打印（自定义资源 / SF Symbol 回退）
        // 主窗口由 SwiftUI 建，建好之前拿不到引用；听「窗口成为 key」的通知最省事
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleWindowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        // 窗口可能已经建好但一直没成为 key（后台启动），主动找一次
        DispatchQueue.main.async { self.claimMainWindow() }
    }

    // MARK: - 主窗口

    /// 认领主窗口。剪贴板浮层是 NSPanel、状态栏没有标题栏，都跳过。
    ///
    /// 这里会把 SwiftUI 自己装的窗口代理顶掉——换来的是 × 和 ⌘W 都能统一走「隐藏」。
    /// 如果以后发现 SwiftUI 的窗口行为异常（比如焦点/工具栏），改成只重定向关闭按钮
    /// （`standardWindowButton(.closeButton)?.action`）并把「关闭」菜单命令一起换掉。
    func attach(_ window: NSWindow) {
        guard mainWindow !== window, Self.isMainWindowCandidate(window) else { return }
        mainWindow = window
        window.delegate = self
        log.notice("已认领主窗口，关闭将改为隐藏")
    }

    /// 从当前窗口列表里找主窗口（启动时没认领成功、或弱引用断了都能自愈）
    @discardableResult
    func claimMainWindow() -> NSWindow? {
        if let window = mainWindow { return window }
        let candidates = [NSApp.mainWindow, NSApp.keyWindow] + NSApp.windows
        if let window = candidates.compactMap({ $0 }).first(where: Self.isMainWindowCandidate) {
            attach(window)
        }
        return mainWindow
    }

    static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        !(window is NSPanel) && window.styleMask.contains(.titled) && window.canBecomeMain
    }

    /// 菜单栏「显示主界面」和点 Dock 图标都走这里
    func showMainWindow() {
        setDockVisible(true)                    // 从菜单栏模式回到 Dock / ⌘Tab
        NSApp.unhide(nil)                       // ⌘H 隐藏过也要能叫回来
        NSApp.activate(ignoringOtherApps: true)
        claimMainWindow()?.makeKeyAndOrderFront(nil)
    }

    /// 收起主界面：窗口藏起来，同时从 Dock / ⌘Tab 里撤掉。
    /// 工具引擎不受影响——它们跟窗口无关，照旧在跑。
    func hideMainWindow() {
        log.notice("收起主界面（当前策略 \(NSApp.activationPolicy() == .regular ? "regular" : "accessory", privacy: .public)）")
        mainWindow?.orderOut(nil)
        setDockVisible(false)
    }

    /// 按「主窗口当前是否可见」纠正 Dock 可见性。
    /// 系统把「打开 app」（例如访达扩展投递 macq:// URL）当成一次启动，会把激活策略重置回
    /// Info.plist 的默认值 regular——实测收起状态下投递 URL，策略从 accessory 变回 regular，
    /// Dock 图标就冒出来了，而这段时间我们的代码根本没碰过策略。处理完这类事件后调一次这里纠正。
    func syncDockVisibility() {
        setDockVisible(mainWindow?.isVisible == true)
    }

    /// NSSavePanel 等系统面板会激活 MacQ，关掉后 AppKit 会把主窗口抬到前面。
    /// 在 `begin` 之前记下主窗口是否可见；完成后调这里。
    /// `overlayStillUp`：取消保存时截图遮罩还在，只把主窗口藏到后面，不切 accessory。
    func afterSystemPanel(mainWasVisible: Bool, overlayStillUp: Bool = false) {
        let apply = { [weak self] in
            guard let self else { return }
            if overlayStillUp {
                self.mainWindow?.orderOut(nil)
                if !mainWasVisible { self.setDockVisible(false) }
            } else if !mainWasVisible {
                self.hideMainWindow()
            } else {
                self.syncDockVisibility()
            }
        }
        // ponytail: AppKit 常在 completion 返回后再 orderFront 主窗口，下一拍 + 50ms 再按一次
        DispatchQueue.main.async(execute: apply)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: apply)
    }

    /// `.accessory` = 不进 Dock、不进 ⌘Tab（也没有 app 菜单栏）；`.regular` = 正常应用
    private func setDockVisible(_ visible: Bool) {
        let wanted: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != wanted else { return }
        log.notice("Dock 可见性 -> \(visible ? "显示" : "隐藏", privacy: .public)")
        _ = NSApp.setActivationPolicy(wanted)
    }

    /// 只给探针用：模拟「启动时没能认领主窗口」
    func forgetMainWindowForProbe() {
        mainWindow?.delegate = nil
        mainWindow = nil
    }

    /// 点 × ：收起主界面（不销毁窗口，也不退出程序）
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hideMainWindow()
        return false
    }

    @objc private func handleWindowDidBecomeKey(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        attach(window)
    }

    // MARK: - 菜单栏

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let (icon, source) = makeStatusIcon()
        item.button?.image = icon
        item.button?.imageScaling = .scaleProportionallyUpOrDown
        item.button?.toolTip = "MacQ"
        item.menu = makeMenu()
        statusItem = item
        log.notice("菜单栏图标已就位（来源：\(source, privacy: .public)）")
    }

    /// 非 private：探针要分别验「自定义图标」和「回退」两条路
    func makeStatusIcon() -> (image: NSImage?, source: String) {
        if let url = Bundle.main.url(forResource: Self.statusIconResourceName, withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return (image, Self.statusIconResourceName)
        }

        let image = NSImage(systemSymbolName: Self.fallbackStatusIconName, accessibilityDescription: "MacQ")
        image?.isTemplate = true
        return (image, "SF Symbol fallback: \(Self.fallbackStatusIconName)")
    }

    /// 菜单内容（拆出来是为了不碰真实菜单栏也能验）
    func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let show = NSMenuItem(title: AppLanguage.localized("显示主界面"), action: #selector(showMainWindowAction), keyEquivalent: "")
        show.target = self
        menu.addItem(show)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: AppLanguage.localized("退出 MacQ"), action: #selector(quitAction), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    @objc private func showMainWindowAction() { showMainWindow() }
    @objc private func quitAction() { NSApp.terminate(nil) }
}
