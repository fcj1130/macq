import SwiftUI

/// 工具注册表：**新增一个工具只改这一个文件**（实例表 + 详情页路由各加一个 case），
/// 目录条目在 `ToolDefinition.catalog` 里加。
///
/// 之前实例表在 `AppModel`、路由在 `ToolDetailView`，加一个工具要改三处，容易漏。
@MainActor
enum ToolRegistry {
    /// 已实现工具的实例表：id → 实例。
    /// 卡片的：总开关、移除工具时停引擎，都走它；没有登记的工具（如「开发中」占位）返回 nil。
    static func instances(in model: AppModel) -> [String: any ToggleableTool] {
        [
            ToolDefinition.magicMouseID: model.magicMouse,
            ToolDefinition.magicClipboardID: model.magicClipboard,
            ToolDefinition.magicRightClickID: model.magicRightClick,
            ToolDefinition.devToolboxID: model.devToolbox,
            ToolDefinition.screenshotID: model.screenshot,
        ]
    }

    /// 工具详情页路由
    @ViewBuilder
    static func detail(for definition: ToolDefinition, in model: AppModel) -> some View {
        switch definition.id {
        case ToolDefinition.magicMouseID:
            MagicMouseView(tool: model.magicMouse)
        case ToolDefinition.magicClipboardID:
            MagicClipboardView(tool: model.magicClipboard)
        case ToolDefinition.magicRightClickID:
            MagicRightClickView(tool: model.magicRightClick)
        case ToolDefinition.devToolboxID:
            DevToolboxView(tool: model.devToolbox)
        case ToolDefinition.screenshotID:
            ScreenshotView(tool: model.screenshot)
        default:
            ContentUnavailableView(
                AppLanguage.localized("开发中"),
                systemImage: definition.icon,
                description: Text(AppLanguage.localized("这个工具还没实现"))
            )
        }
    }
}
