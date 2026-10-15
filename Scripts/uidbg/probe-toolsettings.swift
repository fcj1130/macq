import Foundation

// 工具配置域探针：命名空间隔离、缺键兜底、版本迁移、卸载清理。
// 全程用一个独立的 UserDefaults suite，不碰真实配置。

let suite = "com.mymy.macq.probe.settings.\(getpid())"
let defaults = UserDefaults(suiteName: suite)!
defaults.removePersistentDomain(forName: suite)

MainActor.assumeIsolated {
    // 1) 缺键一律读成兜底值（不是 false / 0 / nil）
    let mouse = ToolSettings(tool: "magicMouse", schema: 1, defaults: defaults)
    check(mouse.bool("smooth", true), "缺键 → 布尔读成兜底 true")
    check(mouse.double("speed", 1.0) == 1.0, "缺键 → 浮点读成兜底 1.0")
    check(mouse.int("maxBytes", 1024) == 1024, "缺键 → 整数读成兜底 1024")
    check(mouse.raw("retention", ClipRetention.forever) == .forever, "缺键 → 枚举读成兜底 .forever")

    // 2) 写读往返 + 键名确实带命名空间前缀
    mouse.set(false, "smooth")
    mouse.set(2.5, "speed")
    mouse.set(ClipRetention.month.rawValue, "retention")
    check(mouse.bool("smooth", true) == false, "写读往返：布尔")
    check(mouse.double("speed", 1.0) == 2.5, "写读往返：浮点")
    check(mouse.raw("retention", ClipRetention.forever) == .month, "写读往返：枚举以 rawValue 存")
    check(defaults.object(forKey: "magicMouse.speed") != nil, "键名格式 magicMouse.speed（命名空间前缀）")

    // 3) 工具之间互不干扰：同名键在另一个工具下读不到
    let clipboard = ToolSettings(tool: "magicClipboard", schema: 1, defaults: defaults)
    check(clipboard.bool("smooth", true), "同名键在别的工具命名空间下互不影响")

    // 4) 迁移：按版本逐级跑，且只跑一次
    var ran: [Int] = []
    let steps: [Int: (ToolSettings) -> Void] = [2: { _ in ran.append(2) }, 3: { _ in ran.append(3) }]
    let upgraded = ToolSettings(tool: "magicMouse", schema: 3, defaults: defaults)
    upgraded.migrate(steps)
    check(ran == [2, 3], "首次启动：逐级跑 v2、v3（实际 \(ran)）")
    upgraded.migrate(steps)
    check(ran == [2, 3], "已是最新版本：不重复迁移")
    check(defaults.integer(forKey: "magicMouse.schema") == 3, "迁移后盖上当前版本号")
    check(mouse.double("speed", 1.0) == 2.5, "迁移不影响已有配置值")

    // 5) 真实升级路径：存量 v2 → 只跑第 3 步
    defaults.set(2, forKey: "magicClipboard.schema")
    var clipRan: [Int] = []
    let clipSteps: [Int: (ToolSettings) -> Void] = [2: { _ in clipRan.append(2) }, 3: { _ in clipRan.append(3) }]
    ToolSettings(tool: "magicClipboard", schema: 3, defaults: defaults).migrate(clipSteps)
    check(clipRan == [3], "存量 v2 → v3：只跑第 3 步（实际 \(clipRan)）")

    // 6) 降级场景：存量版本比当前高就什么都不做
    defaults.set(9, forKey: "magicMouse.schema")
    var downgradeRan: [Int] = []
    ToolSettings(tool: "magicMouse", schema: 3, defaults: defaults).migrate([2: { _ in downgradeRan.append(2) }])
    check(downgradeRan.isEmpty, "存量版本高于当前（用户降级过 app）：不跑迁移")
    check(defaults.integer(forKey: "magicMouse.schema") == 9, "降级时不覆盖版本号")

    // 7) 卸载清理：只清自己的命名空间
    defaults.set("leave me", forKey: "appTheme")
    ToolSettings(tool: "magicMouse", schema: 3, defaults: defaults).removeAll()
    check(defaults.object(forKey: "magicMouse.speed") == nil, "卸载后 magicMouse.* 已清掉")
    check(defaults.object(forKey: "magicMouse.schema") == nil, "卸载后版本键也清掉")
    check(defaults.integer(forKey: "magicClipboard.schema") == 3, "其他工具的配置不受影响")
    check(defaults.string(forKey: "appTheme") == "leave me", "无关键不受影响")

    defaults.removePersistentDomain(forName: suite)
}
