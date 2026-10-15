import AppKit
import CoreGraphics

// 从进程外数 MacQ 的普通窗口（layer 0），并报告它当前的激活策略。
//
// 用法：xcrun swift Scripts/uidbg/wincount.swift [pid]
//   不传 pid：用 NSWorkspace 列表找（app 处于 accessory 时列表里可能查不到，所以删窗口类测试要传 pid）
//   传了 pid：直接按 pid 查 NSRunningApplication（accessory 也能查到）
//
// 用途：验证「点 Dock 图标不会多开窗口」「点 × 之后从 Dock / ⌘Tab 里撤掉」这类从外部才看得见的行为。

let onScreen = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let mine = onScreen.filter {
    ($0[kCGWindowOwnerName as String] as? String) == "MacQ" && ($0[kCGWindowLayer as String] as? Int) == 0
}

let app: NSRunningApplication?
if CommandLine.arguments.count > 1, let pid = pid_t(CommandLine.arguments[1]) {
    app = NSRunningApplication(processIdentifier: pid)
} else {
    app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == "com.mymy.macq" }
}

let policy: String
if let app {
    policy = switch app.activationPolicy {
    case .regular: "regular（Dock 可见）"
    case .accessory: "accessory（不在 Dock）"
    case .prohibited: "prohibited"
    default: "未知(\(app.activationPolicy.rawValue))"
    }
} else {
    policy = "查不到（pid 不对或进程已退出）"
}

let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
print("MacQ 普通窗口数=\(mine.count)  激活策略=\(policy)  前台=\(front)")
