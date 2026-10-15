import SwiftUI
import AppKit

// 魔法鼠标 UI 探针：设置页控件是否齐全、开关是否真的驱动引擎、
// 工具中心与我的工具的入口是否正常。

MainActor.assumeIsolated {
    let model = AppModel()

    // 1) 设置页控件
    let settingsPage = host(MagicMouseView(tool: model.magicMouse), width: 640, height: 560)
    var text = ocr(render(settingsPage)!, "魔法鼠标设置页").joined(separator: " ")
    for label in ["开启魔法鼠标", "平滑滚轮", "滚轮速度", "垂直翻转", "水平翻转"] {
        check(text.contains(label), "设置页出现「\(label)」")
    }
    check(text.contains("已关闭"), "关闭状态有说明文案")

    // 2) 开关 → 引擎（真实启停事件 tap）
    model.magicMouse.enabled = true
    check(model.magicMouse.running, "打开开关后引擎启动（权限=\(model.magicMouse.trusted)）")
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    text = ocr(render(settingsPage)!, "开关打开后").joined(separator: " ")
    check(text.contains("正在拦截") || !model.magicMouse.trusted,
          "打开后状态文案变为「正在拦截」（OCR 命中=\(text.contains("正在拦截"))）")
    check(UserDefaults.standard.bool(forKey: "magicMouse.enabled"), "开关状态写入了 UserDefaults")

    model.magicMouse.enabled = false
    check(!model.magicMouse.running, "关闭开关后引擎停止，滚轮归还系统")

    // 3) 工具中心入口
    let center = host(ToolCenterView().environment(model), width: 640, height: 560)
    let centerText = ocr(render(center)!, "工具中心").joined(separator: " ")
    check(centerText.contains("魔法") && centerText.contains("滚轮平滑"), "工具中心列出魔法鼠标（含简介）")
    check(centerText.contains("添加"), "上架工具带「添加」按钮")
    check(centerText.contains("开发中"), "未实现工具带「开发中」角标")

    // 4) 我的工具入口
    model.add(ToolDefinition.magicMouseID)
    let mine = host(MyToolsView().environment(model), width: 640, height: 560)
    let mineText = ocr(render(mine)!, "我的工具").joined(separator: " ")
    check(mineText.contains("魔法") && mineText.contains("滚轮平滑"), "我的工具里出现魔法鼠标卡片（含简介）")
    check(mineText.contains("打开"), "已实现工具带「打开」按钮（进入设置页）")
}
