import Cocoa
import FinderSync
import os

/// Finder 扩展：往访达右键菜单里加「复制路径」「进入终端」。
///
/// 它只做两件事——按开关画菜单、执行动作。显示哪些项由主程序写下的共享配置决定
/// （见 MagicRightClickCore.swift）。「复制路径」在扩展内就能完成，不依赖主程序；
/// 「进入终端」必须转交主程序，所以主程序没在运行时该项不显示（免得点一下把 MacQ 拉起来）。
///
/// 类名由 Info.plist 的 NSExtensionPrincipalClass 指定，必须与 `@objc` 名字一致。
@objc(FinderRightClick)
final class FinderRightClick: FIFinderSync {
    private let log = Logger(subsystem: "com.mymy.macq", category: "rightclick")

    override init() {
        super.init()
        // 观察根目录 → 任何文件夹的右键菜单里访达都会来问我们
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
        // 「读到」是沙箱能不能读到配置的直接证据：若它与配置文件的真实内容不一致，
        // 就是权限例外失效（见 FinderExtension/*.entitlements）
        let config = RightClickSharedConfig.load()
        log.info("""
            扩展已加载 来自=\(Bundle.main.bundlePath, privacy: .public) \
            配置可见性=\(Self.configDiagnostics(), privacy: .public) \
            读到=已启用\(config.enabled, privacy: .public) 项=\(config.visibleItems.count, privacy: .public)
            """)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let config = RightClickSharedConfig.load()
        let (selected, targeted) = currentTargets()
        log.info("""
            菜单请求 种类=\(menuKind.rawValue, privacy: .public) \
            选中=\(selected.count, privacy: .public) 目录=\(targeted?.path ?? "无", privacy: .public) \
            已启用=\(config.enabled, privacy: .public) 项=\(config.visibleItems.count, privacy: .public)
            """)

        guard !config.visibleItems.isEmpty else {
            log.info("无可见菜单项（已启用=\(config.enabled, privacy: .public) MacQ在运行=\(HostApp.isRunning, privacy: .public)）")
            return nil
        }
        // 侧栏项不是文件，没有路径也没有终端可进
        guard menuKind != .contextualMenuForSidebar else { return nil }

        let menu = NSMenu(title: "")
        for item in config.visibleItems(isContainerMenu: menuKind == .contextualMenuForContainer) {
            let menuItem = NSMenuItem(title: item.title, action: Self.action(for: item), keyEquivalent: "")
            menuItem.target = self
            menu.addItem(menuItem)
        }
        return menu
    }

    // MARK: - 动作

    @objc private func copyPathAction(_ sender: AnyObject?) {
        let (selected, targeted) = currentTargets()
        let paths = RightClickPaths.copyTargets(selected: selected, targeted: targeted)
        guard !paths.isEmpty else {
            log.error("复制路径：没有目标 选中=\(selected.count, privacy: .public)")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
        log.info("复制路径 条数=\(paths.count, privacy: .public) 成功=\(ok, privacy: .public) 首条=\(paths[0], privacy: .public)")
    }

    @objc private func openTerminalAction(_ sender: AnyObject?) {
        // 菜单出现时主程序是在运行的；万一这期间退出了就不发请求——
        // 发了会把 MacQ 整个拉起来（这是这个 guard 存在的唯一理由）
        guard HostApp.isRunning else {
            log.error("进入终端：MacQ 未运行，忽略（不启动主程序）")
            return
        }
        let (selected, targeted) = currentTargets()
        guard let folder = RightClickPaths.terminalFolder(selected: selected, targeted: targeted) else {
            log.error("进入终端：推导不出文件夹 选中=\(selected.count, privacy: .public)")
            return
        }
        // 沙箱里 stat 可能被拒，这里把判断依据打出来，出问题能直接定位
        let raw = selected.first?.path ?? targeted?.path ?? "无"
        // 扩展自己不能把文件夹交给终端（沙箱拒绝，实测），转交主程序执行
        let sent = AppURL.send(.openTerminal(folder: folder))
        log.info("进入终端 原始=\(raw, privacy: .public) hasDirectoryPath=\((selected.first ?? targeted)?.hasDirectoryPath.description ?? "无", privacy: .public) 判定目录=\(folder.path, privacy: .public) 已转交主程序=\(sent, privacy: .public)")
    }

    @objc private func newFileAction(_ sender: AnyObject?) {
        let (selected, targeted) = currentTargets()
        // 空白处右键 → targeted 就是当前文件夹；万一从选中项进来，取它所在/自身目录
        let folder = targeted ?? selected.first.flatMap(RightClickPaths.containerFolder(of:))
        guard let folder else {
            log.error("新建文件：推导不出文件夹 选中=\(selected.count, privacy: .public)")
            return
        }
        // 先试着自己建：FinderSync 对监听目录有写权限（App Store 的 New File Menu 类应用即此原理）。
        // 基础名从共享配置读——主程序把当前界面语言的本地化名写在里面。
        let baseName = RightClickSharedConfig.load().newFileBaseName ?? "未命名"
        if let created = RightClickPaths.createNewFile(in: folder, baseName: baseName) {
            log.info("新建文件 成功=\(created.path, privacy: .public)")
            selectForRename(created)
            return
        }
        // 沙箱被拒时转交主程序；只在主程序已运行时转，免得一次右键把 MacQ 拉起来
        guard HostApp.isRunning else {
            log.error("新建文件：扩展无权限且 MacQ 未运行 目录=\(folder.path, privacy: .public)")
            NSSound.beep()  // 不能静默失败——用户点了菜单却什么都没发生
            return
        }
        let sent = AppURL.send(.newFile(folder: folder))
        log.notice("新建文件 扩展写入被拒，已转交主程序=\(sent, privacy: .public) 目录=\(folder.path, privacy: .public)")
    }

    /// 建完文件让 Finder 选中它并按回车 → 进入系统同款重命名态（见 MagicRightClickCore 的脚本）。
    /// 自动化授权没给时脚本报错，静默退回「只建文件」，不打断用户。
    private func selectForRename(_ url: URL) {
        var error: NSDictionary?
        NSAppleScript(source: RightClickPaths.renameAppleScript(for: url.path))?
            .executeAndReturnError(&error)
        if let error {
            log.notice("进入重命名失败（多半是自动化授权没给）错误=\(error.description, privacy: .public)")
        } else {
            log.info("已选中并进入重命名 \(url.path, privacy: .public)")
        }
    }

    // MARK: - 辅助

    /// 当前目标：选中项 + 右键所在目录（空白处右键时选中项为空，用它兜底）
    private func currentTargets() -> (selected: [URL], targeted: URL?) {
        let controller = FIFinderSyncController.default()
        return (controller.selectedItemURLs() ?? [], controller.targetedURL())
    }

    private static func action(for item: RightClickItem) -> Selector {
        switch item {
        case .copyPath: return #selector(copyPathAction(_:))
        case .openTerminal: return #selector(openTerminalAction(_:))
        case .newFile: return #selector(newFileAction(_:))
        }
    }

    private static func configDiagnostics() -> String {
        RightClickSharedConfig.diagnostics()
            .map { "\($0.path)(存在=\($0.exists) 字节=\($0.bytes))" }
            .joined(separator: " | ")
    }
}
