import AppKit

// 菜单栏图标 + 主窗口显隐（AppShell / AppDelegate）的探针。
// 只验证逻辑与窗口状态，不点真实菜单栏：窗口都用离屏坐标。
// 注意 install() 会真的建一个菜单栏图标（进程退出即消失），这样才能验「不会重复建」。

_ = NSApplication.shared

MainActor.assumeIsolated {
    let shell = AppShell.shared

    print("── 菜单栏菜单 ──")
    let menu = shell.makeMenu()
    check(menu.items.count == 3, "菜单共 3 项：显示主界面 + 分隔线 + 退出（实际 \(menu.items.count)）")
    check(menu.items.first?.title == "显示主界面", "第一项是「显示主界面」")
    check(menu.items.count == 3 && menu.items[1].isSeparatorItem, "中间是分隔线")
    check(menu.items.last?.title == "退出 MacQ", "最后一项是「退出 MacQ」")
    check(menu.items.last?.keyEquivalent == "q", "退出项带 ⌘Q 快捷键")
    check(menu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.target != nil }, "菜单项都设了 target（否则点了没反应）")

    print("\n── 菜单栏图标 ──")
    // probe.sh 会把 Resources/*.png 拷到探针二进制旁边，Bundle.main 因此能查到——走的就是线上同一条路
    let (icon, source) = shell.makeStatusIcon()
    check(icon != nil, "菜单栏图标能取到（来源：\(source)）")
    check(icon?.isTemplate == true, "图标是模板图（跟随菜单栏深浅色）")
    check(source == AppShell.statusIconResourceName, "用的是自定义资源而不是回退（实际 \(source)）")
    check(NSImage(systemSymbolName: AppShell.fallbackStatusIconName, accessibilityDescription: nil) != nil,
          "回退图标名是合法 SF Symbol（\(AppShell.fallbackStatusIconName)）")
    shell.install()
    check(shell.statusItem != nil, "install() 之后菜单栏图标已就位")
    check(shell.statusItem?.button?.image?.isTemplate == true, "图标是模板图（跟随菜单栏深浅色）")
    check(shell.statusItem?.button?.image?.size == NSSize(width: 18, height: 18), "图标按 18pt 绘制（菜单栏标准尺寸）")
    check(shell.statusItem?.menu != nil, "图标挂了菜单")
    let firstItem = shell.statusItem
    shell.install()
    check(shell.statusItem === firstItem, "重复 install() 不会多出一个菜单栏图标")

    print("\n── 点 × 只隐藏、不销毁 ──")
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 900, height: 600),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.orderFront(nil)
    check(window.isVisible, "（前置）窗口已显示")
    shell.attach(window)
    check(shell.mainWindow === window, "主窗口被认领")
    check(window.delegate === shell, "主窗口代理已挂上（关窗会经过我们）")
    check(shell.windowShouldClose(window) == false, "关窗被拦下：返回 false，不走销毁")
    check(window.isVisible == false, "关窗后窗口不可见（= 隐藏）")
    check(shell.mainWindow === window, "窗口对象还在（菜单栏能原样叫回来）")

    print("\n── 显示主界面 ──")
    shell.showMainWindow()
    check(window.isVisible, "窗口重新可见")

    print("\n── 启动时没认领成功也要能自愈 ──")
    shell.forgetMainWindowForProbe()
    check(shell.mainWindow == nil, "（前置）已忘掉主窗口")
    window.makeKeyAndOrderFront(nil)
    window.makeMain()
    shell.showMainWindow()
    check(shell.mainWindow === window, "showMainWindow 自己把主窗口找回来了")
    check(window.isVisible, "并且显示出来了")
    check(window.delegate === shell, "代理重新挂上（× 仍是隐藏）")

    print("\n── 剪贴板浮层不该被当成主窗口 ──")
    let panel = NSPanel(contentRect: NSRect(x: -5000, y: -5000, width: 400, height: 300),
                        styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    shell.attach(panel)
    check(shell.mainWindow === window, "NSPanel 不会被认领为主窗口")
    check(panel.delegate == nil, "NSPanel 的代理没被改过")

    print("\n── 点 Dock 图标（applicationShouldHandleReopen）──")
    let delegate = AppDelegate()
    window.orderOut(nil)
    check(window.isVisible == false, "（前置）窗口已隐藏")
    let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
    check(handled == false, "返回 false：不让系统再走默认处理（走默认会让 SwiftUI 多开一个主窗口）")
    check(window.isVisible, "窗口被叫回来")
    check(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false,
          "关掉最后一个窗口不退出程序（不实现这个，点 × 会把整个 MacQ 关掉——实测 voluntary exit）")

    print("\n── 收起主界面 = 从 Dock / ⌘Tab 撤掉 ──")
    shell.hideMainWindow()
    check(window.isVisible == false, "隐藏后窗口不可见")
    check(NSApp.activationPolicy() == .accessory, "应用转为 accessory（不在 Dock、不在 ⌘Tab）")
    check(shell.statusItem != nil, "菜单栏图标仍在（否则就彻底找不回界面了）")
    shell.hideMainWindow()
    check(NSApp.activationPolicy() == .accessory, "重复隐藏不会来回切策略")
    // 模拟系统把策略重置回 regular（实测投递 macq:// URL 时就会这样），纠正函数要能改回来
    _ = NSApp.setActivationPolicy(.regular)
    shell.syncDockVisibility()
    check(NSApp.activationPolicy() == .accessory, "窗口收起时 syncDockVisibility 纠正回 accessory（弹 Dock 图标）")
    shell.showMainWindow()
    check(window.isVisible, "显示后窗口可见")
    check(NSApp.activationPolicy() == .regular, "策略回到 regular（Dock 图标回来）")

    print("\n── accessory 模式下剪贴板浮层仍能拿键盘焦点 ──")
    _ = NSApp.setActivationPolicy(.accessory)
    panel.makeKeyAndOrderFront(nil)
    check(panel.isKeyWindow, "accessory 模式下非激活浮层仍是 key window（搜索框能打字）")
    panel.orderOut(nil)
    _ = NSApp.setActivationPolicy(.regular)
}
