import AppKit
import os

/// 应用代理：菜单栏图标与主窗口显隐的接线、访达扩展转交的请求、关闭系统的窗口状态恢复。
///
/// 单独放一个文件而不是写在 MacqApp.swift 里：探针会剔除带 `@main` 的入口文件，
/// 只有放这里才能被探针编译进来验证（见 Scripts/uidbg/probe-appshell.swift）。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let log = Logger(subsystem: "com.mymy.macq", category: "rightclick")

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppShell.shared.install()
    }

    /// 关掉最后一个窗口不能退出程序。
    ///
    /// 不实现这个的话，点 ×（窗口被收起）会让进程**整个退出**——实测系统日志是
    /// `Process exited: voluntary, code = 0`（不是崩溃，是自己走的），那样剪贴板监听、
    /// 滚轮引擎、菜单栏图标全都会跟着停。常驻后台才是 MacQ 的常态。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// 点 Dock 图标（或在访达里双击 app）。必须返回 false。
    ///
    /// 返回 true 等于「交给系统继续默认处理」，而 SwiftUI 的 WindowGroup 默认处理就是再开一个
    /// 新窗口——实测点一次 Dock 图标会多出一个主窗口（窗口序 `MacQ > MacQ`）。
    /// 窗口我们在下面自己叫回来了。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppShell.shared.showMainWindow()
        return false
    }

    // 关闭系统的「安全状态恢复」。
    // MacQ 只有一个主窗口，不需要恢复上次退出时的窗口；而 SwiftUI 会把每个窗口
    // （包括曾经因为收到 URL 而多开的那些）连同序号一起持久化，于是每次启动都
    // 把 4 个窗口一起恢复回来。实测 -ApplePersistenceIgnoreState YES 时只有 1 个窗口。
    func application(_ app: NSApplication, shouldRestoreSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldSaveSecureApplicationState coder: NSCoder) -> Bool {
        false
    }

    /// 接收访达扩展转交的请求（见 MagicRightClickCore.swift 里的 AppURL）。
    /// 扩展是沙箱进程，自己开不了终端，只能把请求编码成 URL 交给系统，由这里执行。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let request = AppURL.request(from: url) else {
                log.error("收到无法识别的 URL：\(url.absoluteString, privacy: .public)")
                continue
            }
            switch request {
            case .openTerminal(let requested):
                guard let folder = AppURL.existingFolder(at: requested.path) else {
                    log.error("进入终端：路径不存在或不是文件夹 \(requested.path, privacy: .public)")
                    continue
                }
                let terminal = MagicRightClick.shared.terminalBundleID
                let ok = TerminalApp.open(folder: folder, bundleID: terminal)
                log.notice("进入终端（来自访达扩展）目录=\(folder.path, privacy: .public) 终端=\(terminal, privacy: .public) 已发起=\(ok, privacy: .public)")
            case .newFile(let requested):
                guard let folder = AppURL.existingFolder(at: requested.path) else {
                    log.error("新建文件：路径不存在或不是文件夹 \(requested.path, privacy: .public)")
                    continue
                }
                // 文件名跟随当前界面语言（未命名 / Untitled）；en 表里没有时回落中文
                let baseName = AppLanguage.localized("未命名")
                guard let created = RightClickPaths.createNewFile(in: folder, baseName: baseName) else {
                    log.error("新建文件：主程序也写不进去 \(folder.path, privacy: .public)")
                    continue
                }
                log.notice("新建文件（来自访达扩展）目录=\(folder.path, privacy: .public) 结果=\(created.path, privacy: .public)")
                // 沙箱扩展写不了文件（实测被拒），实际建文件的是主程序——
                // 「选中并进重命名」也必须跟着放在主程序这侧做。
                var scriptError: NSDictionary?
                NSAppleScript(source: RightClickPaths.renameAppleScript(for: created.path))?
                    .executeAndReturnError(&scriptError)
                if let scriptError {
                    log.notice("进入重命名失败（多半是自动化授权没给，功能退回只建文件）错误=\(scriptError.description, privacy: .public)")
                } else {
                    log.notice("已选中并发送回车 \(created.path, privacy: .public)")
                }
            }
        }
        // 收到 URL 说明系统刚把 MacQ 当「被打开」处理了一次，激活策略会被重置回 regular，
        // 于是收起的 Dock 图标会冒出来。按主窗口可见性纠正回来。
        AppShell.shared.syncDockVisibility()
    }
}
