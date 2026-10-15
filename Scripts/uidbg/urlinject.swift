// 模拟访达扩展给主程序投递 macq:// URL（与扩展同款：activates = false），
// 用来验证「系统把 URL 投递当成一次 app-open」带来的副作用（例如激活策略被重置回 regular）。
// 用法：xcrun swift Scripts/uidbg/urlinject.swift "macq://terminal?path=/tmp"
import AppKit

let url = URL(string: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "macq://terminal?path=/tmp")!
let config = NSWorkspace.OpenConfiguration()
config.activates = false
NSWorkspace.shared.open(url, configuration: config) { app, error in
    print("投递 \(url.absoluteString) → app=\(app?.bundleIdentifier ?? "nil") 错误=\(error?.localizedDescription ?? "无")")
    exit(0)
}
RunLoop.main.run()
