import CoreGraphics
import Foundation

// 把一次按键（含修饰键）直接投递给指定进程，用来验证 app 自己的键盘/菜单行为。
// 依赖终端的辅助功能授权。
// 用法：xcrun swift Scripts/uidbg/sendkey.swift <pid> <keycode> [cmd|ctrl|opt|shift ...]
// 例：⌘W = xcrun swift Scripts/uidbg/sendkey.swift 12345 13 cmd

let args = CommandLine.arguments
guard args.count >= 3, let pid = pid_t(args[1]), let keyCode = UInt16(args[2]) else {
    FileHandle.standardError.write(Data("用法: sendkey.swift <pid> <keycode> [cmd|ctrl|opt|shift ...]\n".utf8))
    exit(2)
}

var flags: CGEventFlags = []
for modifier in args.dropFirst(3) {
    switch modifier {
    case "cmd": flags.insert(.maskCommand)
    case "ctrl": flags.insert(.maskControl)
    case "opt": flags.insert(.maskAlternate)
    case "shift": flags.insert(.maskShift)
    default:
        FileHandle.standardError.write(Data("未知修饰键: \(modifier)\n".utf8))
        exit(2)
    }
}

let source = CGEventSource(stateID: .hidSystemState)
for keyDown in [true, false] {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else { continue }
    event.flags = flags
    event.postToPid(pid)
    usleep(30_000)
}
print("已投递 keyCode=\(keyCode) 修饰键=\(flags.rawValue) -> pid \(pid)")
