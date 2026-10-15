import Foundation

/// 带**总开关**的工具：卡片右上角可以直接开关，不必进详情页。
///
/// 新工具只要①声明这个协议 ②在 `AppModel.toolInstances` 里登记一次，
/// 卡片上的开关就自动出现，不需要改界面代码。
@MainActor
protocol ToggleableTool: AnyObject {
    var enabled: Bool { get set }
}

/// 一个工具的定义。
struct ToolDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let icon: String // SF Symbol 名称
    let implemented: Bool
}

extension ToolDefinition {
    static let magicMouseID = "magic-mouse"
    static let magicClipboardID = "magic-clipboard"
    static let magicRightClickID = "magic-right-click"
    static let devToolboxID = "dev-toolbox"
    static let screenshotID = "screenshot"

    /// 工具中心的全量目录。后续新工具在此注册。
    static let catalog: [ToolDefinition] = [
        ToolDefinition(
            id: magicMouseID,
            name: "魔法鼠标",
            summary: "滚轮平滑、速度调节与方向翻转",
            icon: "magicmouse",
            implemented: true
        ),
        ToolDefinition(
            id: magicRightClickID,
            name: "魔法右键",
            summary: "访达右键增强：复制路径、进入终端、新建文件",
            icon: "cursorarrow.click.2",
            implemented: true
        ),
        ToolDefinition(
            id: magicClipboardID,
            name: "魔法剪贴板",
            summary: "剪贴板历史、类型分类、搜索与快捷键调用",
            icon: "doc.on.clipboard",
            implemented: true
        ),
        ToolDefinition(
            id: devToolboxID,
            name: "开发者工具箱",
            summary: "快捷键唤起：JSON / Base64 / URL / 时间戳 / UUID / HTML",
            icon: "wrench.and.screwdriver",
            implemented: true
        ),
        ToolDefinition(
            id: "color-picker",
            name: "颜色选择器",
            summary: "屏幕取色，快速复制任意格式颜色值",
            icon: "eyedropper",
            implemented: false
        ),
        ToolDefinition(
            id: screenshotID,
            name: "截图工具",
            summary: "快捷键截图、窗口识别、区域调整与标注",
            icon: "camera.viewfinder",
            implemented: true
        ),
        ToolDefinition(
            id: "window-manager",
            name: "窗口管理",
            summary: "快捷键分屏、窗口布局与快速切换",
            icon: "macwindow",
            implemented: false
        ),
        ToolDefinition(
            id: "system-monitor",
            name: "系统监测",
            summary: "实时查看 CPU、内存与网络状态",
            icon: "gauge",
            implemented: false
        ),
    ]

    /// 工具中心的展示顺序：可用的排前面，开发中的沉到底部，各自保持声明顺序。
    static var catalogByAvailability: [ToolDefinition] {
        catalog.filter(\.implemented) + catalog.filter { !$0.implemented }
    }
}
