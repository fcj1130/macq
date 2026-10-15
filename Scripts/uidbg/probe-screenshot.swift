// 截图工具探针：坐标换算、窗口命中、手柄缩放、默认快捷键、设置页 OCR
// 用法：./Scripts/uidbg/probe.sh Scripts/uidbg/probe-screenshot.swift
import AppKit
import SwiftUI
import Carbon.HIToolbox

var failures = 0

@MainActor
func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✓ \(label)\(detail.isEmpty ? "" : "：\(detail)")") }
    else { failures += 1; print("  ✗ \(label)\(detail.isEmpty ? "" : "：\(detail)")") }
}

@MainActor
func runProbe() {
    let h: CGFloat = 1000
    let cg = CGRect(x: 100, y: 200, width: 300, height: 150)
    let cocoa = ScreenshotCore.cocoaRect(fromCG: cg, mainHeight: h)
    expect(cocoa.origin.x == 100 && cocoa.origin.y == 650 && cocoa.width == 300 && cocoa.height == 150,
           "CG → Cocoa：Y 轴翻转", "y=\(cocoa.origin.y)")
    let back = ScreenshotCore.cgRect(fromCocoa: cocoa, mainHeight: h)
    expect(back == cg, "Cocoa → CG 往返")

    // 列表前→后 = 屏幕 z 序。小窗在前时重叠点打小窗；大窗在前（全屏 Chrome）时后窗再小也不命中。
    let frontSmall = [
        ScreenshotCore.Win(id: 2, rect: CGRect(x: 100, y: 100, width: 200, height: 120)),
        ScreenshotCore.Win(id: 1, rect: CGRect(x: 0, y: 0, width: 800, height: 600)),
        ScreenshotCore.Win(id: 3, rect: CGRect(x: 900, y: 0, width: 400, height: 400)),
    ]
    expect(ScreenshotCore.window(at: CGPoint(x: 150, y: 150), in: frontSmall)?.id == 2, "重叠取最前的小窗")
    expect(ScreenshotCore.window(at: CGPoint(x: 10, y: 10), in: frontSmall)?.id == 1, "只命中大窗")
    expect(ScreenshotCore.window(at: CGPoint(x: 2000, y: 10), in: frontSmall) == nil, "空白处无窗口")
    let frontChrome = [
        ScreenshotCore.Win(id: 1, rect: CGRect(x: 0, y: 0, width: 800, height: 600)),
        ScreenshotCore.Win(id: 2, rect: CGRect(x: 100, y: 100, width: 200, height: 120)),
    ]
    expect(ScreenshotCore.window(at: CGPoint(x: 150, y: 150), in: frontChrome)?.id == 1, "被挡住的后窗不命中")

    let raw: [[String: Any]] = [
        [kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1,
         kCGWindowNumber as String: 11, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 100, "Height": 80]],
        [kCGWindowLayer as String: 25, kCGWindowAlpha as String: 1,
         kCGWindowNumber as String: 12, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 800, "Height": 24]],
        [kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1,
         kCGWindowNumber as String: 13, kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 10, "Height": 10]],
        [kCGWindowLayer as String: 0, kCGWindowAlpha as String: 1,
         kCGWindowNumber as String: 14, kCGWindowBounds as String: ["X": 10, "Y": 10, "Width": 50, "Height": 50]],
    ]
    let parsed = ScreenshotCore.windows(from: raw, mainHeight: 100, skipIDs: [14], minSide: 40)
    expect(parsed.map(\.id) == [11], "过滤：layer≠0、太小、skipIDs 都丢掉")

    let sel = CGRect(x: 100, y: 100, width: 200, height: 80)
    expect(ScreenshotCore.hitHandle(CGPoint(x: 100, y: 180), in: sel) == .nw, "命中左上角手柄")
    expect(ScreenshotCore.hitHandle(CGPoint(x: 300, y: 100), in: sel) == .se, "命中右下角手柄")
    expect(ScreenshotCore.hitHandle(CGPoint(x: 200, y: 140), in: sel) == nil, "选区内部不是手柄")
    let east = ScreenshotCore.resize(sel, .e, to: CGPoint(x: 360, y: 140))
    expect(east.width == 260 && east.minX == 100, "东手柄拉宽", "w=\(east.width)")
    let west = ScreenshotCore.resize(sel, .w, to: CGPoint(x: 40, y: 140))
    expect(west.minX == 40 && west.maxX == 300, "西手柄改原点、右缘不动")
    let tiny = ScreenshotCore.resize(sel, .e, to: CGPoint(x: 102, y: 140))
    expect(tiny.width >= 8, "缩到最小宽度 8")
    let drag = ScreenshotCore.rect(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 4, y: 20))
    expect(drag == CGRect(x: 4, y: 20, width: 6, height: 30), "拖拽框选归一化")
    let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let moved = ScreenshotCore.move(sel, by: CGPoint(x: 30, y: -10), in: bounds)
    expect(moved.origin.x == 130 && moved.origin.y == 90 && moved.size == sel.size, "平移保持尺寸")
    let clamped = ScreenshotCore.move(sel, by: CGPoint(x: -1000, y: 0), in: bounds)
    expect(clamped.origin.x == 0 && clamped.width == sel.width, "平移不越出屏幕")

    let btn = ScreenshotCore.confirmRect(CGRect(x: 0, y: 0, width: 800, height: 600),
                                         in: CGRect(x: 100, y: 100, width: 200, height: 80))
    expect(btn.height == 26 && btn.maxX <= 800, "完成按钮贴在选区附近且不越界")
    let barBelow = ScreenshotCore.toolbarFrame(
        selection: CGRect(x: 200, y: 200, width: 300, height: 180),
        size: CGSize(width: 420, height: 44),
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
    expect(barBelow.maxY <= 200 && barBelow.minY >= 0, "工具条默认贴选区下方")
    let barAbove = ScreenshotCore.toolbarFrame(
        selection: CGRect(x: 200, y: 10, width: 300, height: 80),
        size: CGSize(width: 420, height: 44),
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
    expect(barAbove.minY >= 90, "下方不够时工具条放到选区上方")

    expect(ScreenshotCore.MarkColor.allCases.map(\.rawValue) == ["red", "green", "blue", "yellow", "black", "white", "gray"], "七色固定盘")
    expect(ScreenshotCore.barSize(tool: nil).height == 44, "未选工具：单行工具条")
    expect(ScreenshotCore.barSize(tool: nil).width == 512, "工具条含滚动截图按钮宽度")
    expect(ScreenshotCore.barSize(tool: nil, scrollMode: true).height == 44, "滚动模式单行工具条")
    expect(ScreenshotCore.barSize(tool: .rect).height == 80, "矩形：展开颜色+粗细")
    expect(ScreenshotCore.barSize(tool: .text).height == 80, "文字：展开颜色+字号")
    expect(ScreenshotCore.barSize(tool: .mosaic).height == 44, "马赛克：无样式行")
    expect(ScreenshotCore.ocrPanelSize(lineCount: 0, empty: true) == CGSize(width: 300, height: 52), "空识别结果面板高度")
    let ocrRight = ScreenshotCore.ocrPanelFrame(
        bar: CGRect(x: 100, y: 200, width: 480, height: 44),
        size: CGSize(width: 300, height: 120),
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
    expect(ocrRight.minX >= 580 && ocrRight.minY == 200, "识别面板优先贴工具条右侧")
    let ocrBelow = ScreenshotCore.ocrPanelFrame(
        bar: CGRect(x: 1100, y: 200, width: 480, height: 44),
        size: CGSize(width: 300, height: 120),
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
    expect(ocrBelow.maxY <= 200, "右侧不够时识别面板放到工具条下方")

    func bitmap(_ s: String, size: NSSize = NSSize(width: 420, height: 72)) -> NSImage {
        let scale: CGFloat = 2
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (s as NSString).draw(at: NSPoint(x: 20, y: 22), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }
    let blank = bitmap("")
    expect(ScreenshotCore.recognizeText(in: blank).isEmpty, "空白图识别为空")
    let hello = ScreenshotCore.recognizeText(in: bitmap("HELLO"))
    expect(hello.joined().replacingOccurrences(of: " ", with: "").contains("HELLO"),
           "离线 OCR 能认出 HELLO", hello.joined(separator: " | "))
    let udName = "macq-probe-shot-ink-\(getpid())"
    let ud = UserDefaults(suiteName: udName)!
    ud.removePersistentDomain(forName: udName)
    let ts = ToolSettings(tool: "screenshot", schema: 1, defaults: ud)
    ts.set("blue", "color")
    ts.set(8.0, "stroke")
    ts.set(24.0, "fontSize")
    let inkTool = ScreenshotTool(settings: ts)
    expect(inkTool.ink.color == .blue && inkTool.ink.stroke == 8 && inkTool.ink.fontSize == 24, "样式从配置读回")
    inkTool.ink.color = .green
    expect(ud.string(forKey: "screenshot.color") == "green", "改颜色落盘")

    switch ScreenshotTool.defaultTrigger {
    case .combo(let c):
        expect(c.keyCode == UInt32(kVK_ANSI_S), "默认快捷键键码是 S")
        expect(c.carbonModifiers == UInt32(shiftKey | cmdKey), "默认修饰键是 ⇧⌘")
        expect(c.display == "⇧⌘S", "默认展示 ⇧⌘S", c.display)
    default:
        expect(false, "默认唤起方式应是组合键")
    }

    let def = ToolDefinition.catalog.first { $0.id == ToolDefinition.screenshotID }
    expect(def?.implemented == true, "目录里截图工具已上架")
    expect(def?.icon == "camera.viewfinder", "图标名")
    expect(NSImage(systemSymbolName: def?.icon ?? "", accessibilityDescription: nil) != nil, "SF Symbol 合法")
    for s in ["rectangle", "arrow.up.right", "pencil", "textformat", "square.grid.3x3", "arrow.up.and.down", "arrow.uturn.backward", "xmark"] {
        expect(NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil, "编辑工具栏图标 \(s)")
    }

    func rampImage(width: Int, height: Int, offset: Int) -> NSImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            let v = CGFloat((offset + (height - 1 - y)) % 256) / 255
            ctx.setFillColor(red: v, green: 0.2, blue: 1 - v, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
    let a = rampImage(width: 40, height: 60, offset: 0)
    let b = rampImage(width: 40, height: 60, offset: 30)
    let stitched = ScreenshotCore.stitchVertical(base: a, next: b, expectedAdded: 30)
    expect(abs(stitched.overlap - 30) <= 2, "渐变拼接重叠约 30", "overlap=\(stitched.overlap)")
    expect(abs(Int(stitched.image.size.height) - 90) <= 2, "拼接高度约 90", "h=\(Int(stitched.image.size.height))")
    expect(!stitched.identical, "不同帧不算滚到底")
    expect(!ScreenshotCore.scrollHitBottom(streak: 1), "一帧相同不停")
    expect(!ScreenshotCore.scrollHitBottom(streak: 2), "两帧相同不停（新门槛 3 票）")
    expect(ScreenshotCore.scrollHitBottom(streak: 3), "强证据三票才到底")
    expect(ScreenshotCore.scrollHitBottom(streak: 3.5), "弱证据半票累积到 3 也到底")
    let sameFrame = ScreenshotCore.stitchVertical(base: a, next: a, expectedAdded: 30)
    expect(sameFrame.identical && sameFrame.stable, "全帧纹丝不动是强证据")
    let sameFrame2 = ScreenshotCore.stitchVertical(base: a, next: a, expectedAdded: 30)
    expect(ScreenshotCore.framesQuiet(a: a, b: sameFrame2.image) || ScreenshotCore.framesQuiet(a: a, b: a), "同一帧停稳")
    expect(ScreenshotCore.framesQuiet(a: a, b: b) == false, "还在动的帧不算停稳")
    expect(ScreenshotCore.framesQuiet(a: a, b: nil) == false, "缺帧不算停稳")
    // 重复列表（周期 40 行，每 200 行一个标记）：窗口内多个周期都能配上，必须选中正确那个。
    func listImage(width: Int, height: Int, offset: Int) -> NSImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            // CG 填充坐标从下往上；按图像行（顶为 0）算页号，内容才往上滚。
            let page = offset + (height - 1 - y)
            let base = Double(page % 40) / 40
            let drift = Double(page % 600) / 600
            ctx.setFillColor(red: base, green: 0, blue: drift, alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: width, height: height))
    }
    let la = listImage(width: 60, height: 300, offset: 0)
    let lb = listImage(width: 60, height: 300, offset: 80)
    let listStitch = ScreenshotCore.stitchVertical(base: la, next: lb, expectedAdded: 80)
    expect(abs(listStitch.overlap - 220) <= 2, "重复列表不配错行", "overlap=\(listStitch.overlap)")
    expect(abs(Int(listStitch.image.size.height) - 380) <= 2, "重复列表拼出正确高度", "h=\(Int(listStitch.image.size.height))")
    // 乱帧（噪声）：配不上不硬拼，当本帧没滚。
    func noiseImage(width: Int, height: Int) -> NSImage {
        let space = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            ctx.setFillColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1)
            ctx.fill(CGRect(x: 0, y: y, width: width, height: 1))
        }
        return NSImage(cgImage: ctx.makeImage()!, size: NSSize(width: width, height: height))
    }
    let noise = ScreenshotCore.stitchVertical(base: la, next: noiseImage(width: 60, height: 300), expectedAdded: 80)
    expect(noise.identical, "乱帧不硬拼", "overlap=\(noise.overlap)")
    expect(!noise.stable, "乱帧对不上只算弱证据，不当强到底")
    let same = ScreenshotCore.stitchVertical(base: a, next: a, expectedAdded: 30)
    expect(same.identical, "相同两帧判定滚到底")
    expect(Int(same.image.size.height) == 60, "滚到底不拉长")
    let prev = ScreenshotCore.scrollPreviewSize(image: NSSize(width: 100, height: 800))
    expect(prev.height == 420 && prev.width <= 220, "预览高度封顶 420")
    let prevFrame = ScreenshotCore.scrollPreviewFrame(
        selection: CGRect(x: 100, y: 100, width: 200, height: 300),
        size: CGSize(width: 120, height: 200),
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
    expect(prevFrame.minX >= 300, "预览默认贴选区右侧")
    expect(prevFrame.intersection(CGRect(x: 100, y: 100, width: 200, height: 300)).isEmpty, "预览不叠进选区")
    let tight = ScreenshotCore.scrollPreviewFrame(
        selection: CGRect(x: 20, y: 20, width: 1400, height: 860),
        size: CGSize(width: 120, height: 200),
        screen: CGRect(x: 0, y: 0, width: 1440, height: 900))
    expect(tight.intersection(CGRect(x: 20, y: 20, width: 1400, height: 860)).width
            * tight.intersection(CGRect(x: 20, y: 20, width: 1400, height: 860)).height
            < 120 * 200, "大选区时预览尽量少叠选区")
    let tall = rampImage(width: 40, height: 90, offset: 0)
    let more = rampImage(width: 40, height: 60, offset: 60)
    let tallStitch = ScreenshotCore.stitchVertical(base: tall, next: more, expectedAdded: 30)
    expect(abs(Int(tallStitch.image.size.height) - 120) <= 4, "长图只拼新增高度", "h=\(Int(tallStitch.image.size.height))")
    expect(ScreenshotCore.scrollStep(selectionHeight: 1000) == 120, "大选区步长封顶 120")
    expect(ScreenshotCore.scrollStep(selectionHeight: 200) == 64, "小选区步长下限 64")
    let thumb = ScreenshotCore.scrollPreviewThumb(tall)
    expect(thumb.size.height <= 420 && thumb.size.width <= 220, "预览缩略图不超过封顶")
    expect(ScreenshotCore.cursorInSelection(CGPoint(x: 150, y: 200), CGRect(x: 100, y: 100, width: 200, height: 300)), "指针在选区内")
    expect(!ScreenshotCore.cursorInSelection(CGPoint(x: 10, y: 10), CGRect(x: 100, y: 100, width: 200, height: 300)), "指针在选区外")
    let pidHit = ScreenshotCore.ownerPID(
        from: [
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 99,
             kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 100, "Height": 100]],
            [kCGWindowLayer as String: 0, kCGWindowOwnerPID as String: 7,
             kCGWindowBounds as String: ["X": 0, "Y": 0, "Width": 100, "Height": 100]],
        ],
        atCG: CGPoint(x: 10, y: 10),
        skipPID: 99
    )
    expect(pidHit == 7, "命中跳过本进程后的窗口 pid")

    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("macq-probe-screenshot-\(getpid())", isDirectory: true)
    try? FileManager.default.removeItem(at: tmp)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    // 不碰真实配置：ToolSettings 仍写 UserDefaults 域，探针只验默认快捷键与 UI，不 new ScreenshotTool()

    let model = AppModel()
    expect(model.screenshot === ScreenshotTool.shared, "AppModel 拿到的是单例")
    expect(ToolRegistry.instances(in: model)[ToolDefinition.screenshotID] != nil, "注册表有截图工具实例")

    let hosting = host(ScreenshotView(tool: ScreenshotTool.shared), width: 560, height: 640)
    RunLoop.current.run(until: Date().addingTimeInterval(0.4))
    let texts = ocr(render(hosting)!, "screenshot-settings")
    let blob = texts.joined()
    expect(blob.contains("启用截图") || blob.contains("截图工具"), "设置页有总开关")
    expect(blob.contains("快捷键") || blob.contains("唤起"), "设置页有快捷键区")
    expect(blob.contains("屏幕录制") || blob.contains("开始截图"), "设置页有屏幕录制 / 开始截图")
    expect(blob.contains("⇧⌘S") || blob.contains("⌘S") || blob.contains("S"), "设置页展示默认快捷键")

    print(failures == 0 ? "\n全绿 \( /* count via stdout */ "")" : "")
    print(failures == 0 ? "OK" : "FAILURES=\(failures)")
}

MainActor.assumeIsolated { runProbe() }
exit(failures == 0 ? 0 : 1)
