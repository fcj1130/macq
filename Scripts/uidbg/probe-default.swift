import SwiftUI
import AppKit
import Vision

// 默认探针：把 MainView 放进窗口布局，检查结构、侧栏几何与可点击性，并 OCR 出可见文字。
// 之前用它定位到「@ViewBuilder 里两个 onChange 把 NavigationSplitView 复制成两份」的 bug。

// 默认探针：把 MainView 放进窗口布局，检查结构、侧栏几何与可点击性，并 OCR 出可见文字。
// 之前用它定位到「@ViewBuilder 里两个 onChange 把 NavigationSplitView 复制成两份」的 bug。

let W: CGFloat = 1000, H: CGFloat = 640

MainActor.assumeIsolated {
    let root = host(MainView().environment(AppModel()), width: W, height: H)

    // 1) 结构：一个 view 里只应有一个 NavigationSplitView，多了说明被复制（布局会各占半屏）
    let splits = root.subviews
    print(splits.count == 1 ? "✓ 顶层 split 数 = 1"
                            : "✗ 顶层 split 数 = \(splits.count)，高度 \(splits.map { String(format: "%.0f", $0.frame.height) }.joined(separator: " + "))")

    // 2) 侧栏几何
    if let glass = find(root, classContains: "Glass") {
        print(String(format: "侧栏: %.0f x %.0f", glass.frame.width, glass.frame.height))
    }

    // 3) 可点击性：上部「我的工具/工具中心」，底部钉着「设置」
    var topCells = 0
    for y in stride(from: H - 50, through: H - 120, by: -26.0) {
        let hit = root.hitTest(NSPoint(x: 90, y: y))
        let name = hit.map { String(describing: type(of: $0)) } ?? "nil"
        if name.contains("CellHostingView") { topCells += 1 }
        print(String(format: "  上 y=%.0f -> %@", y, name))
    }
    var bottomCells = 0
    for y in stride(from: 50, through: 10, by: -10.0) {
        let hit = root.hitTest(NSPoint(x: 90, y: y))
        let name = hit.map { String(describing: type(of: $0)) } ?? "nil"
        if name.contains("CellHostingView") { bottomCells += 1 }
        print(String(format: "  下 y=%.0f -> %@", y, name))
    }
    print(topCells >= 2 ? "✓ 侧栏上部命中 \(topCells) 个列表行" : "✗ 侧栏上部只命中 \(topCells) 个列表行")
    print(bottomCells >= 1 ? "✓ 设置钉在侧栏底部" : "✗ 侧栏底部没命中设置行")

    // 4) 可见文字（详情页能 OCR 到，材质区域是空白，属正常）
    if let core = find(root, classContains: "CoreHostingView") { ocr(render(core)!, "侧栏文字") }
    ocr(render(root)!, "整窗文字")
}
