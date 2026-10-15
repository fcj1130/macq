import Foundation
import Observation
import SwiftUI

/// 全局应用状态：当前导航页 + 我的工具列表（UserDefaults 持久化，**顺序即展示顺序**）
@MainActor
@Observable
final class AppModel {
    var selectedTab: SideTab = .myTools

    /// 已实现的工具实例（后续每个工具一个）
    let magicMouse: MagicMouse
    let magicClipboard: MagicClipboard
    let magicRightClick: MagicRightClick
    let devToolbox: DevToolbox
    let screenshot: ScreenshotTool

    /// 我的工具：按用户排好的顺序存 id
    private(set) var addedToolOrder: [String]

    private static let storageKey = "addedToolOrder"
    /// 旧版本存的是无序集合（写出去时排过序），升级时按它迁移一次
    private static let legacyStorageKey = "addedToolIDs"

    /// 可注入实例：探针需要把工具指向临时存储，避免读写真实数据
    init(magicMouse: MagicMouse? = nil, magicClipboard: MagicClipboard? = nil, magicRightClick: MagicRightClick? = nil, devToolbox: DevToolbox? = nil, screenshot: ScreenshotTool? = nil) {
        self.magicMouse = magicMouse ?? .shared
        self.magicClipboard = magicClipboard ?? .shared
        self.magicRightClick = magicRightClick ?? .shared
        self.devToolbox = devToolbox ?? .shared
        self.screenshot = screenshot ?? .shared
        let defaults = UserDefaults.standard
        addedToolOrder = defaults.stringArray(forKey: Self.storageKey)
            ?? defaults.stringArray(forKey: Self.legacyStorageKey)
            ?? []
    }

    /// 已实现工具的实例表：id → 实例。新增工具登记在 ToolRegistry 里
    private var toolInstances: [String: any ToggleableTool] { ToolRegistry.instances(in: self) }

    /// 卡片右上角总开关的绑定；没有总开关（或还没实现）的工具返回 nil，卡片上就不显示开关
    func powerBinding(for id: String) -> Binding<Bool>? {
        guard let tool = toolInstances[id] else { return nil }
        return Binding(
            get: { MainActor.assumeIsolated { tool.enabled } },
            set: { newValue in MainActor.assumeIsolated { tool.enabled = newValue } }
        )
    }

    var addedTools: [ToolDefinition] {
        addedToolOrder.compactMap { id in
            ToolDefinition.catalog.first { $0.id == id }
        }
    }

    func isAdded(_ id: String) -> Bool {
        addedToolOrder.contains(id)
    }

    func add(_ id: String) {
        guard !addedToolOrder.contains(id) else { return }
        addedToolOrder.append(id)
        persist()
    }

    func remove(_ id: String) {
        addedToolOrder.removeAll { $0 == id }
        persist()
        // 移出「我的工具」就停掉它的引擎，避免还在后台拦截事件
        toolInstances[id]?.enabled = false
    }

    /// 拖动排序：把 `id` 挪到 `targetID` 所在的位置
    func move(_ id: String, to targetID: String) {
        guard id != targetID,
              let from = addedToolOrder.firstIndex(of: id),
              let to = addedToolOrder.firstIndex(of: targetID)
        else { return }
        addedToolOrder.remove(at: from)
        addedToolOrder.insert(id, at: to)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(addedToolOrder, forKey: Self.storageKey)
    }
}
