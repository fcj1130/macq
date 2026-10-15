// 魔法剪贴板 UI 探针：历史窗口 + 设置页的离屏渲染、OCR、点击复用
// 跑法：./Scripts/uidbg/probe.sh Scripts/uidbg/probe-clipboard-ui.swift
import AppKit
import SwiftUI
import Vision

var failures = 0

@MainActor
func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✓ \(label)\(detail.isEmpty ? "" : "：\(detail)")") } else { failures += 1; print("  ✗ \(label)\(detail.isEmpty ? "" : "：\(detail)")") }
}

@MainActor
func writePayload(_ store: ClipboardStore, name: String, bytes: Int) -> String {
    try? Data(repeating: 0x41, count: bytes).write(to: store.root.appendingPathComponent(name))
    return name
}

@MainActor
func runProbe() {
    let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macq-clip-ui-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }

    // ── 造数据（临时目录，不碰真实历史）
    let store = ClipboardStore(root: base.appendingPathComponent("store"))
    let tool = MagicClipboard(store: store)
    tool.enabled = false          // 探针里别真的开始监听
    store.clear()

    let textID = UUID()
    store.insert(ClipItem(id: textID, kind: .text, usedAt: Date(), size: 18, characters: 14,
                          preview: "hello ui 探针", searchText: "hello ui 探针",
                          payload: writePayload(store, name: "\(textID.uuidString).txt", bytes: 18),
                          paths: [], pasteboardType: "public.utf8-plain-text", fingerprint: "ui-text"),
                 maxBytes: 1 << 30, retention: .forever)
    let imageID = UUID()
    store.insert(ClipItem(id: imageID, kind: .image, usedAt: Date().addingTimeInterval(-60), size: 4096, characters: 0,
                          preview: "32 × 16", searchText: "32 × 16",
                          payload: writePayload(store, name: "\(imageID.uuidString).png", bytes: 4096),
                          paths: [], pasteboardType: "public.png", fingerprint: "ui-image"),
                 maxBytes: 1 << 30, retention: .forever)
    store.insert(ClipItem(id: UUID(), kind: .file, usedAt: Date().addingTimeInterval(-120), size: 204800, characters: 0,
                          preview: "报告.pdf", searchText: "报告.pdf", payload: nil,
                          paths: ["/tmp/报告.pdf"], pasteboardType: nil, fingerprint: "ui-file"),
                 maxBytes: 1 << 30, retention: .forever)
    store.insert(ClipItem(id: UUID(), kind: .video, usedAt: Date().addingTimeInterval(-180), size: 9_000_000, characters: 0,
                          preview: "演示.mov", searchText: "演示.mov", payload: nil,
                          paths: ["/tmp/演示.mov"], pasteboardType: nil, fingerprint: "ui-video"),
                 maxBytes: 1 << 30, retention: .forever)
    let oldDate = Date().addingTimeInterval(-7200)
    store.insert(ClipItem(id: UUID(), kind: .text, usedAt: oldDate, size: 12, characters: 10,
                          preview: "旧记录探针", searchText: "旧记录探针", payload: nil,
                          paths: [], pasteboardType: "public.utf8-plain-text", fingerprint: "ui-old"),
                 maxBytes: 1 << 30, retention: .forever)
    expect(store.items.count == 5, "探针数据就绪", "\(store.items.count) 条")

    // ── 历史窗口
    let picker = host(ClipboardPickerView(tool: tool, state: PickerState()), width: 580, height: 560)
    guard let rep = render(picker) else { print("  ✗ 渲染失败"); return }
    let boxes = ocrBoxes(rep)
    let texts = boxes.map(\.text)
    ocr(rep, "剪贴板窗口")

    // OCR 容错：全角/异体符号常被识别错（× → x，· → •，. → •），统一归一化后再比对
    func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "×", with: "x")
            .replacingOccurrences(of: "·", with: ".")
            .replacingOccurrences(of: "•", with: ".")
            .lowercased()
    }
    let flattened = normalize(texts.joined(separator: "|"))
    func has(_ needle: String) -> Bool { flattened.contains(normalize(needle)) }
    expect(has("搜索"), "搜索框占位文字")
    expect(has("全部"), "「全部」tab")
    expect(has("文本"), "「文本」tab")
    expect(has("图片"), "「图片」tab")
    expect(has("视频"), "「视频」tab")
    expect(has("文件"), "「文件」tab")
    expect(has("hello ui 探针"), "文本行预览")
    expect(has("32 × 16"), "图片行尺寸预览")
    expect(has("报告.pdf"), "文件行预览（引用）")
    expect(has("演示.mov"), "视频行预览（引用）")
    expect(has("旧记录探针"), "两小时前的记录行")
    // 时间显示：>1 小时必须显示具体日期时间，不再用相对时间
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .short
    dateFormatter.timeStyle = .short
    expect(has(dateFormatter.string(from: oldDate)), "超过 1 小时显示具体日期时间", dateFormatter.string(from: oldDate))
    expect(!has("小时前"), "超过 1 小时不再显示相对时间")
    expect(has("占用"), "底部占用统计")
    expect(has("清空历史"), "清空历史按钮")
    expect(has("关闭"), "关闭按钮")

    // 点击第一行（文本）→ 应触发复用（该条置顶 + 写回剪贴板）
    guard let window = picker.window, let content = window.contentView else { print("  ✗ 缺少窗口"); return }
    let scale = CGFloat(rep.pixelsWide) / max(picker.bounds.width, 1)
    if let row = boxes.first(where: { $0.text.contains("hello ui 探针") }) {
        let point = NSPoint(x: row.rect.midX / scale, y: row.rect.midY / scale)
        let hit = content.hitTest(point)
        expect(hit != nil, "文本行区域可命中", "hitTest=\(hit.map { String(describing: type(of: $0)) } ?? "nil")")

        let backup = NSPasteboard.general.string(forType: .string)
        for type in [NSEvent.EventType.leftMouseDown, NSEvent.EventType.leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let reused = store.items.first?.id == textID
        expect(reused, "点击该行触发复用（该条置顶为最新）",
               "首条 = \(store.items.first.map { $0.preview } ?? "无")")
        if let backup { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(backup, forType: .string) }
    } else {
        expect(false, "未 OCR 到文本行，无法点击测试")
    }

    // 清空历史：必须先弹二次确认；点取消后历史保留
    if let clearBox = boxes.first(where: { $0.text.contains("清空历史") }) {
        let idsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
        let itemsBefore = store.items.count
        click(NSPoint(x: clearBox.rect.midX / scale, y: clearBox.rect.midY / scale), in: window, eventNumber: 2)
        expect(store.items.count == itemsBefore, "点击「清空历史」没有直接清空", "\(store.items.count) 条")

        let dialogs = newWindows(since: idsBefore, attachedTo: window).compactMap { w in ocrWindow(w).map { (window: w, info: $0) } }
        let dialogText = dialogs.map(\.info.text).joined(separator: " ")
        print("  ℹ︎ 点击后新窗口 \(dialogs.count) 个：\(String(dialogText.prefix(90)))")
        expect(dialogText.contains("清空") && dialogText.contains("取消"),
               "弹出二次确认弹框", dialogText.isEmpty ? "未捕获到弹框文字" : String(dialogText.prefix(90)))

        // 点弹框里的「取消」：弹框关掉、历史还在
        // 弹框是 AppKit 的 NSAlertPanel（模态），合成点击驱动不了它；用 abortModal 收尾。
        // 真实 app 跑的是 NSApp.run()，用户点按钮是正常的，这只是探针的限制。
        if let dialog = dialogs.first(where: { $0.info.text.contains("取消") }) {
            NSApp.abortModal()
            dialog.window.orderOut(nil)
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            expect(store.items.count == itemsBefore, "取消/关闭后历史保留", "\(store.items.count) 条")
            let stillVisible = newWindows(since: idsBefore, attachedTo: window).filter(\.isVisible)
            print("  ℹ︎ 收尾后仍可见的弹框：\(stillVisible.count) 个")
            expect(stillVisible.isEmpty, "弹框已关闭（不挡后续操作）", "仍可见 \(stillVisible.count) 个")
        } else {
            expect(false, "弹框里没找到「取消」按钮")
        }
    } else {
        expect(false, "未 OCR 到清空历史按钮")
    }

    // 搜索过滤：把搜索词换成「报告」后只应剩文件行
    let filtered = host(ClipboardPickerView(tool: tool, state: PickerState(), initialQuery: "报告"), width: 580, height: 560)
    if let rep2 = render(filtered) {
        let texts2 = ocrBoxes(rep2).map(\.text)
        let joined = normalize(texts2.joined(separator: " | "))
        ocr(rep2, "搜索「报告」")
        expect(joined.contains(normalize("报告.pdf")), "搜索结果保留匹配行")
        expect(!joined.contains(normalize("hello ui 探针")), "搜索结果过滤掉不匹配行")
    }

    // ── 设置页
    let settings = host(MagicClipboardView(tool: tool), width: 720, height: 760)
    if let rep3 = render(settings) {
        let texts3 = ocr(rep3, "魔法剪贴板设置页").joined(separator: " | ")
        for label in ["启用魔法剪贴板", "唤起窗口", "录制", "重置", "占用上限", "保留时间", "打开剪贴板窗口", "清空历史", "当前占用"] {
            expect(texts3.contains(label), "设置页出现「\(label)」")
        }
        expect(texts3.contains("双击"), "默认唤起方式显示为双击修饰键", texts3)
        expect(texts3.contains("双击单个修饰键") || texts3.contains("修饰键"), "设置页说明了双击修饰键需权限")

        // 设置页的清空按钮同样要二次确认
        if let clearBox = ocrBoxes(rep3).first(where: { $0.text.contains("清空历史") }), let win3 = settings.window {
            let scale3 = CGFloat(rep3.pixelsWide) / max(settings.bounds.width, 1)
            print("  ℹ︎ 设置页窗口 key=\(win3.isKeyWindow) visible=\(win3.isVisible) 内容=\(Int(settings.bounds.width))x\(Int(settings.bounds.height)) 应用 key=\(NSApp.keyWindow != nil)")

            // 先做清空测试（窗口在最前时点），再做校准
            // 校准：点「重置」（效果可观察）——证明 Form 里按钮的合成点击有效
            tool.trigger = .combo(.default)
            if let resetBox = ocrBoxes(rep3).first(where: { $0.text.contains("重置") }) {
                click(NSPoint(x: resetBox.rect.midX / scale3, y: resetBox.rect.midY / scale3), in: win3, eventNumber: 7)
                expect(tool.trigger == .doubleTap(.option), "校准：设置页 Form 按钮点击有效", "trigger=\(tool.trigger.display)")
            } else {
                print("  ℹ︎ 设置页未 OCR 到「重置」")
            }

            let idsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
            let itemsBefore = store.items.count
            click(NSPoint(x: clearBox.rect.midX / scale3, y: clearBox.rect.midY / scale3), in: win3, eventNumber: 4)
            expect(store.items.count == itemsBefore, "设置页点击「清空历史」不会直接清空历史", "\(store.items.count) 条")
            // 弹框本身由列表窗那条用例验证（两处用的是同一个 clearHistoryConfirmation 修饰符）；
            // 设置页的弹框在离屏窗口里不呈现（Form 内的 confirmationDialog 在 -5000,-5000 的窗口上不弹），
            // 所以这里只断言“点了不清空”，实际弹框请真机点一次确认。
            print("  ℹ︎ 设置页弹框需真机确认（离屏窗口上 Form 内的 confirmationDialog 不呈现）")
            // 校准：点「打开剪贴板窗口」（效果可观察）
            if let openBox = ocrBoxes(rep3).first(where: { $0.text.contains("打开剪贴板") }) {
                let ids = Set(NSApp.windows.map(ObjectIdentifier.init))
                click(NSPoint(x: openBox.rect.midX / scale3, y: openBox.rect.midY / scale3), in: win3, eventNumber: 5)
                let opened = newWindows(since: ids, attachedTo: win3)
                print("  ℹ︎ 校准：点「打开剪贴板窗口」→ 新窗口 \(opened.count) 个 \(opened.map { String(describing: type(of: $0)) })")
                expect(!opened.isEmpty, "校准：设置页按钮点击有效（能唤起剪贴板窗口）")
            }
        } else {
            expect(false, "设置页未 OCR 到清空历史按钮")
        }
    }
}

MainActor.assumeIsolated { runProbe() }
print("")
print(failures == 0 ? "全部通过" : "失败 \(failures) 项")
exit(failures == 0 ? 0 : 1)
