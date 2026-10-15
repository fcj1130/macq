import SwiftUI
import AppKit
import Vision

// 探针共用工具：离屏渲染 + OCR + 视图查找 + 断言打印。
// 所有 probe-*.swift 都由 probe.sh 与 Sources 一起编译，故共用这些声明。

/// 离屏窗口必须留引用，否则窗口释放后 SwiftUI 视图不再布局
var PROBE_WINDOWS: [NSWindow] = []

@MainActor
func render(_ v: NSView) -> NSBitmapImageRep? {
    guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
    v.cacheDisplay(in: v.bounds, to: rep)
    return rep
}

/// OCR 出一张位图里的文字（打印并返回）
@MainActor
@discardableResult
func ocr(_ rep: NSBitmapImageRep, _ tag: String) -> [String] {
    guard let cg = rep.cgImage else { return [] }
    let req = VNRecognizeTextRequest()
    req.recognitionLanguages = ["zh-Hans", "en-US"]
    req.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    let texts = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    print("[\(tag)] \(texts.joined(separator: " | "))")
    return texts
}

@MainActor
func find(_ v: NSView, classContains key: String, minWidth: CGFloat = 100) -> NSView? {
    if String(describing: type(of: v)).contains(key), v.frame.width >= minWidth { return v }
    for s in v.subviews { if let r = find(s, classContains: key, minWidth: minWidth) { return r } }
    return nil
}

/// 把视图放进离屏窗口布局好，返回 hosting view。
/// 注意：直接 win.contentView = NSHostingView 时，窗口会按 SwiftUI 的拟合尺寸缩窄
/// （NavigationStack 拟合成 40pt 宽），所以中间垫一个普通 NSView 容器并用约束钉死四边。
@MainActor
func host<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.translatesAutoresizingMaskIntoConstraints = false
    hosting.sizingOptions = []   // 不让 SwiftUI 把拟合尺寸推给窗口
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
    container.addSubview(hosting)
    NSLayoutConstraint.activate([
        hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        hosting.topAnchor.constraint(equalTo: container.topAnchor),
        hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    let win = NSWindow(
        contentRect: NSRect(x: -5000, y: -5000, width: width, height: height),
        styleMask: [.titled, .resizable, .closable, .fullSizeContentView],
        backing: .buffered, defer: false
    )
    win.contentView = container
    win.setContentSize(NSSize(width: width, height: height))
    // 尺寸也要锁死：NavigationStack 之类会把窗口按拟合尺寸缩成窄条
    win.contentMinSize = NSSize(width: width, height: height)
    win.contentMaxSize = NSSize(width: width, height: height)
    win.orderFront(nil)
    PROBE_WINDOWS.append(win)
    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
    win.setContentSize(NSSize(width: width, height: height))
    hosting.layoutSubtreeIfNeeded()
    if hosting.frame.width < width - 1 || hosting.frame.height < height - 1 {
        print(String(format: "  ⚠︎ 离屏视图尺寸被改成 %.0fx%.0f（请求 %.0fx%.0f）",
                     hosting.frame.width, hosting.frame.height, width, height))
    }
    return hosting
}

func check(_ ok: Bool, _ label: String) { print((ok ? "✓ " : "✗ ") + label) }

// ── 以下从 probe-clipboard-ui.swift 搬来：多个探针共用的 UI 工具 ──

/// 带坐标的 OCR（Vision 的 boundingBox 是左下原点归一化坐标，换算到位图坐标）
@MainActor
func ocrBoxes(_ rep: NSBitmapImageRep) -> [(text: String, rect: CGRect)] {
    guard let cg = rep.cgImage else { return [] }
    let request = VNRecognizeTextRequest()
    request.recognitionLanguages = ["zh-Hans", "en-US"]
    request.recognitionLevel = .accurate
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    let width = CGFloat(rep.pixelsWide)
    let height = CGFloat(rep.pixelsHigh)
    return (request.results ?? []).compactMap { observation in
        guard let text = observation.topCandidates(1).first?.string else { return nil }
        let box = observation.boundingBox
        return (text, CGRect(x: box.minX * width, y: box.minY * height, width: box.width * width, height: box.height * height))
    }
}

/// 某个窗口的可见内容（已渲染 + OCR，坐标已换算到窗口坐标系）
struct WindowOCR {
    let view: NSView
    let scale: CGFloat
    let text: String
    let boxes: [(text: String, rect: CGRect)]
}

@MainActor
func ocrWindow(_ window: NSWindow) -> WindowOCR? {
    guard let view = window.contentView, let rep = render(view) else { return nil }
    let boxes = ocrBoxes(rep)
    return WindowOCR(view: view, scale: CGFloat(rep.pixelsWide) / max(view.bounds.width, 1),
                     text: boxes.map(\.text).joined(separator: " "), boxes: boxes)
}

/// 点击某个窗口内容坐标里的一点（合成 mouseDown + mouseUp）
/// 注意：得先把窗口变 key——“双击前弹框”那类操作在非 key 窗口上不会弹出
@MainActor
func click(_ point: NSPoint, in window: NSWindow, eventNumber: Int = 1, settle: TimeInterval = 0.5) {
    window.makeKeyAndOrderFront(nil)
    for type in [NSEvent.EventType.leftMouseDown, NSEvent.EventType.leftMouseUp] {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            eventNumber: eventNumber, clickCount: 1, pressure: 1) else { continue }
        window.sendEvent(event)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(settle))
}

/// 点击后新冒出来的窗口（SwiftUI 的 confirmationDialog 会开新窗口）
@MainActor
func newWindows(since ids: Set<ObjectIdentifier>, attachedTo window: NSWindow) -> [NSWindow] {
    var result = NSApp.windows.filter { !ids.contains(ObjectIdentifier($0)) && $0.contentView != nil }
    if let sheet = window.attachedSheet { result.append(sheet) }
    return result
}


/// 找出命中测试返回指定类名的控件的**中心**：扫出命中点，取**第一簇**（最靠上的那个控件）的几何中心。
/// 不能直接取所有命中点的中心——一页上有多个同类控件时，那会落到两个控件之间的空白处（点空）。
/// 也不能用 frame 换算——SwiftUI 控件的 frame 是退化的（PlatformSwitch 是 0,0,36,16），
/// 位置还在翻转的坐标空间里，convert 出来的点是错的（会点空）；hitTest 命中的点本身才是对的。
@MainActor
func controlCenter(_ root: NSView, classContains key: String, in rect: CGRect, step: CGFloat = 3) -> NSPoint? {
    var hits: [NSPoint] = []
    for y in stride(from: rect.maxY, through: rect.minY, by: -step) {
        for x in stride(from: rect.minX, through: rect.maxX, by: step) {
            guard let hit = root.hitTest(NSPoint(x: x, y: y)),
                  String(describing: type(of: hit)).contains(key) else { continue }
            hits.append(NSPoint(x: x, y: y))
        }
    }
    guard let first = hits.first else { return nil }
    let cluster = hits.filter { abs($0.x - first.x) <= 24 && abs($0.y - first.y) <= 24 }
    return NSPoint(x: cluster.map(\.x).reduce(0, +) / CGFloat(cluster.count),
                   y: cluster.map(\.y).reduce(0, +) / CGFloat(cluster.count))
}

/// 在某个点周围逐点试探，返回第一个让 `test` 变真的点（点了有反应才算数）
@MainActor
func clickUntil(_ root: NSView, window: NSWindow, around: NSPoint, radius: CGFloat = 6,
                step: CGFloat = 6, settle: TimeInterval = 0.2, _ test: () -> Bool) -> NSPoint? {
    click(around, in: window, settle: settle)
    if test() { return around }
    for dy in stride(from: -radius, through: radius, by: step) {
        for dx in stride(from: -radius, through: radius, by: step) {
            let point = NSPoint(x: around.x + dx, y: around.y + dy)
            click(point, in: window, settle: settle)
            if test() { return point }
        }
    }
    return nil
}
