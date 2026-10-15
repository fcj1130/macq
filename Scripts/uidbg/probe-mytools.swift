// macq 离屏探针：我的工具页
// 覆盖：添加顺序与持久化 / 卡片总开关 / 编辑模式（开关让位给删除按钮）/ 拖动排序 / 移除的二次确认
// 用法：./Scripts/uidbg/probe.sh probe-mytools.swift
import AppKit
import SwiftUI

var passed = 0
var failed = 0

@MainActor
func expect(_ ok: Bool, _ what: String) {
    if ok {
        print("✓ \(what)")
        passed += 1
    } else {
        print("✗ \(what)")
        failed += 1
    }
}

/// 卡片上的开关（SwiftUI 的 Toggle(.switch) 命中测试回 PlatformSwitch）
@MainActor
func findSwitch(_ v: NSView) -> NSView? {
    let cls = String(describing: type(of: v))
    if cls.contains("Switch"), !cls.contains("Host") { return v }
    for sub in v.subviews {
        if let found = findSwitch(sub) { return found }
    }
    return nil
}

/// 点 OCR 到的文字（坐标从位图换算回视图坐标）
@MainActor
@discardableResult
func clickText(_ needle: String, copy: NSBitmapImageRep, in view: NSView, window: NSWindow, eventNumber: Int) -> Bool {
    guard let box = ocrBoxes(copy).first(where: { $0.text.contains(needle) }) else { return false }
    let scale = CGFloat(copy.pixelsWide) / max(view.bounds.width, 1)
    click(NSPoint(x: box.rect.midX / scale, y: box.rect.midY / scale), in: window, eventNumber: eventNumber)
    return true
}

@MainActor
func runProbe() {
    print("── 我的工具：顺序与持久化 ──")
    let defaults = UserDefaults.standard
    // 探针的 UserDefaults 是独立域（进程名 probe），不会碰到 app 的真实数据
    for key in ["addedToolOrder", "addedToolIDs"] { defaults.removeObject(forKey: key) }

    let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("macq-probe-mytools-\(getpid())", isDirectory: true)
    func freshModel() -> AppModel {
        AppModel(magicClipboard: MagicClipboard(store: ClipboardStore(root: tempRoot)))
    }

    let m1 = freshModel()
    expect(m1.addedTools.isEmpty, "初始状态：我的工具是空的")

    m1.add(ToolDefinition.magicMouseID)
    m1.add(ToolDefinition.magicClipboardID)
    m1.add("magic-right-click")
    expect(m1.addedToolOrder == [ToolDefinition.magicMouseID, ToolDefinition.magicClipboardID, "magic-right-click"],
           "按添加顺序排列：\(m1.addedToolOrder.joined(separator: " → "))")

    m1.add(ToolDefinition.magicMouseID)
    expect(m1.addedToolOrder.count == 3, "重复添加同一个工具不产生副本")

    m1.move("magic-right-click", to: ToolDefinition.magicMouseID)
    expect(m1.addedToolOrder == ["magic-right-click", ToolDefinition.magicMouseID, ToolDefinition.magicClipboardID],
           "拖动排序：把最后一张挪到最前")

    m1.move(ToolDefinition.magicMouseID, to: ToolDefinition.magicMouseID)
    expect(m1.addedToolOrder == ["magic-right-click", ToolDefinition.magicMouseID, ToolDefinition.magicClipboardID],
           "拖动排序：拖到自己身上不变")

    m1.remove(ToolDefinition.magicMouseID)
    expect(m1.addedToolOrder == ["magic-right-click", ToolDefinition.magicClipboardID],
           "移除中间一个，剩下的顺序不变")

    expect(freshModel().addedToolOrder == ["magic-right-click", ToolDefinition.magicClipboardID],
           "重启后顺序与内容一致（持久化）")

    defaults.removeObject(forKey: "addedToolOrder")
    defaults.set([ToolDefinition.magicMouseID, ToolDefinition.magicClipboardID], forKey: "addedToolIDs")
    expect(freshModel().addedToolOrder == [ToolDefinition.magicMouseID, ToolDefinition.magicClipboardID],
           "旧版本（无序集合）数据能迁移过来")

    print("── 卡片总开关 ──")
    let clipboard = MagicClipboard(store: ClipboardStore(root: tempRoot.appendingPathComponent("clip")))
    let m2 = AppModel(magicClipboard: clipboard)
    m2.add(ToolDefinition.magicClipboardID)
    m2.add("magic-right-click")

    expect(m2.powerBinding(for: ToolDefinition.magicClipboardID) != nil, "已实现的工具有总开关")
    let placeholder = ToolDefinition.catalog.first { !$0.implemented }!
    m2.add(placeholder.id)
    expect(m2.powerBinding(for: placeholder.id) == nil,
           "还没实现的工具没有总开关（卡片上不显示）：\(placeholder.name)")
    m2.remove(placeholder.id)

    if let power = m2.powerBinding(for: ToolDefinition.magicClipboardID) {
        power.wrappedValue = true
        expect(clipboard.enabled, "卡片上的开关能直接打开工具")
        power.wrappedValue = false
        expect(!clipboard.enabled, "卡片上的开关能直接关掉工具")
        power.wrappedValue = true
    }
    m2.remove(ToolDefinition.magicClipboardID)
    expect(!clipboard.enabled, "从我的工具移除会顺手停掉引擎")
    m2.add(ToolDefinition.magicClipboardID)

    print("── 卡片：普通模式 ──")
    let mouse = ToolDefinition.catalog.first { $0.id == ToolDefinition.magicMouseID }!
    var switchFlips = 0
    var removals = 0
    var opens = 0
    let binding = Binding(get: { true }, set: { _ in switchFlips += 1 })
    // 开关/删除按钮在卡片右上角这块区域里找
    let topRight = CGRect(x: 190, y: 110, width: 70, height: 70)

    let normal = host(
        ToolCard(tool: mouse, power: binding, onOpen: { opens += 1 }, onRemove: { removals += 1 }),
        width: 260, height: 200
    )
    expect(findSwitch(normal) != nil, "普通模式：卡片右上角有总开关")
    let normalTexts = ocr(render(normal)!, "普通模式卡片")
    expect(!normalTexts.contains { $0.contains("打开") }, "普通模式：没有「打开」按钮")
    expect(!normalTexts.contains { $0.contains("拖动排序") }, "普通模式：没有「拖动排序」")

    let switchPoint = controlCenter(normal, classContains: "Switch", in: topRight)
    expect(switchPoint != nil, "定位到开关（命中测试）")
    if let switchPoint, let normalWindow = normal.window {
        click(switchPoint, in: normalWindow, eventNumber: 200)
        expect(switchFlips == 1, "点开关真的拨动了它")
        expect(removals == 0, "普通模式：右上角点了不会触发删除")
        expect(opens == 0, "点开关不会打开详情")
    }

    print("── 卡片：编辑模式 ──")
    let editing = host(
        ToolCard(tool: mouse, isEditing: true, power: binding, onOpen: {}, onRemove: { removals += 1 }),
        width: 260, height: 200
    )
    expect(findSwitch(editing) == nil, "编辑模式：开关让位给删除按钮")
    let editTexts = ocr(render(editing)!, "编辑模式卡片")
    expect(editTexts.contains { $0.contains("拖动排序") }, "编辑模式：显示「拖动排序」提示")
    expect(!editTexts.contains { $0.contains("打开") }, "编辑模式：没有「打开」按钮")

    let removalsBefore = removals
    if let switchPoint, let editingWindow = editing.window {
        // 删除按钮命中测试回的是 hosting view（拿不到类名），只能在开关那一点附近试出来
        let hit = clickUntil(editing, window: editingWindow, around: switchPoint, radius: 14, step: 7) {
            removals > removalsBefore
        }
        expect(hit != nil, "编辑模式：右上角点下去会请求移除")
        expect(m2.isAdded(ToolDefinition.magicClipboardID), "卡片只会发出移除请求，自己不动数据")
    }


    print("── 我的工具页：编辑模式与二次确认 ──")
    let page = host(MyToolsView().environment(m2), width: 760, height: 520)
    guard let pageWindow = page.window, let pageCopy = render(page) else {
        expect(false, "我的工具页渲染失败")
        return
    }
    let cardRegion = CGRect(x: 20, y: 100, width: 740, height: 380)
    let pageTexts = ocr(pageCopy, "我的工具页")
    expect(pageTexts.contains { $0.contains("个工具") }, "页头显示工具数量")
    expect(pageTexts.contains { $0.contains("编辑") }, "右上角有编辑按钮")
    expect(pageTexts.contains { $0.contains("魔法剪贴板") }, "卡片显示工具名")

    // 编辑模式下删除按钮的位置＝普通模式下开关的位置，所以先把它定位下来
    let cardSwitch = controlCenter(page, classContains: "Switch", in: cardRegion)
    expect(cardSwitch != nil, "普通模式：卡片上的总开关可点")

    expect(clickText("编辑", copy: pageCopy, in: page, window: pageWindow, eventNumber: 300),
           "点到了编辑按钮")
    if let editCopy = render(page) {
        let editPageTexts = ocr(editCopy, "我的工具页（编辑中）")
        expect(editPageTexts.contains { $0.contains("完成") }, "进入编辑模式：按钮变成「完成」")
        expect(editPageTexts.contains { $0.contains("拖动排序") }, "进入编辑模式：卡片出现拖动提示")
        expect(controlCenter(page, classContains: "Switch", in: cardRegion) == nil,
               "进入编辑模式：卡片上的总开关不再可点（让位给删除按钮）")
    }

    if let cardSwitch {
        let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        // 确认框可能是一个新窗口，也可能就渲染在页面窗口里：两种都认
        func dialogCopy() -> NSBitmapImageRep? {
            if let copy = render(page), ocrBoxes(copy).contains(where: { $0.text.contains("移除") }) {
                return copy
            }
            if let fresh = NSApp.windows.first(where: { !windowsBefore.contains(ObjectIdentifier($0)) }),
               let content = fresh.contentView {
                return render(content)
            }
            return nil
        }

        let hit = clickUntil(page, window: pageWindow, around: cardSwitch, radius: 18, step: 9) {
            dialogCopy() != nil
        }
        expect(hit != nil, "点删除按钮弹出了二次确认")

        if let copy = dialogCopy() {
            let texts = ocr(copy, "确认框")
            expect(texts.contains { $0.contains("移除") }, "确认框标题带「移除」")
            expect(texts.contains { $0.contains("移除「") }, "确认框有确认移除按钮")
            expect(texts.contains { $0.contains("取消") }, "确认框有取消按钮")
            expect(m2.isAdded(ToolDefinition.magicMouseID), "弹框期间工具还在（没直接删掉）")

            // 收尾：确认框是模态的 NSAlertPanel，离屏合成点击驱动不了它的按钮，用 abortModal 关掉别挡后面的测试
            if let panel = NSApp.windows.first(where: { !windowsBefore.contains(ObjectIdentifier($0)) && $0.isVisible }) {
                NSApp.abortModal()
                panel.orderOut(nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.4))
                expect(m2.isAdded(ToolDefinition.magicMouseID), "关掉弹框后工具仍在（没有误删）")
            }
            print("  ℹ︎ 确认框是模态面板，离屏合成点击驱动不了它的按钮（AppKit 限制，不是 app 的问题）——")
            print("     按钮文案已验，按钮接的动作就是 model.remove，这里用模型层把它验掉：")
            m2.remove(ToolDefinition.magicMouseID)
            expect(!m2.isAdded(ToolDefinition.magicMouseID), "确认移除的动作（model.remove）真的把工具拿掉")
        }
    } else {
        print("  ℹ︎ 定位不到卡片开关，跳过删除按钮的确认流程")
    }

    print("  ℹ︎ 真机请点一次确认框的「移除」和「取消」：模态面板的按钮没法在探针里点。")

    // ── 工具中心：目录内容（新增/下架的工具在这里就能看见）
    print("── 工具中心目录")
    let center = ToolCenterView().environment(AppModel())
    let centerHost = host(center, width: 760, height: 640)
    RunLoop.current.run(until: Date().addingTimeInterval(0.8))
    let centerText = render(centerHost).map { ocr($0, "工具中心") } ?? []
    // 名称或它的说明行任一命中即可：OCR 有时把「鼠」认成「嵐」（实测），拿说明行兜底
    let expectedTools: [(name: String, marker: String)] = [
        ("魔法鼠标", "滚轮平滑"), ("魔法剪贴板", "剪贴板历史"),
        ("魔法右键", "复制路径"),
    ]
    for tool in expectedTools {
        expect(centerText.contains { $0.contains(tool.name) || $0.contains(tool.marker) },
               "工具中心列出「\(tool.name)」")
    }
    expect(!centerText.contains { $0.contains("鼠标控制器") }, "工具中心不再有「鼠标控制器」")
    let placeholders = ToolDefinition.catalog.filter { !$0.implemented }
    expect(!centerText.contains { $0.contains("魔法Bar") }, "工具中心不再有「魔法Bar」（macOS 27 系统自带溢出折叠，无公开 API 可实现）")
    expect(!placeholders.contains { $0.name == "魔法右键" }, "魔法右键 已实现，不再是占位")
    expect(!centerText.isEmpty, "工具中心渲染出内容")

    // 展示顺序：已实现的在前、开发中的沉底，组内保持声明顺序
    let ordered = ToolDefinition.catalogByAvailability
    expect(ordered.count == ToolDefinition.catalog.count, "排序不丢工具、不产生副本")
    let lastImplemented = ordered.lastIndex { $0.implemented }
    let firstPlaceholder = ordered.firstIndex { !$0.implemented }
    expect(lastImplemented == nil || firstPlaceholder == nil || lastImplemented! < firstPlaceholder!,
           "开发中的工具排在已实现工具的下面")
    let implemented = ordered.filter(\.implemented).map(\.id)
    expect(implemented == ToolDefinition.catalog.filter(\.implemented).map(\.id),
           "已实现工具之间保持声明顺序")

    try? FileManager.default.removeItem(at: tempRoot)
}

MainActor.assumeIsolated { runProbe() }
print(failed == 0 ? "全部通过：\(passed) 项" : "失败 \(failed) 项 / 通过 \(passed) 项")
exit(failed == 0 ? 0 : 1)
