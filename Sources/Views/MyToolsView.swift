import SwiftUI

/// 我的工具：展示已添加的工具（卡片网格），空状态引导去工具中心
///
/// 右上角「编辑」进入管理模式：卡片上出现删除按钮、整张卡片可拖动排序。
/// 不带总开关的工具（未实现）卡片上就没有开关。
struct MyToolsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }
    @State private var openedTool: ToolDefinition?
    @State private var isEditing = false
    @State private var pendingRemoval: ToolDefinition?

    var body: some View {
        NavigationStack {
            Group {
                if model.addedTools.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle(AppLanguage.localized("我的工具", languageRaw: languageRaw))
            .navigationDestination(item: $openedTool) { tool in
                ToolRegistry.detail(for: tool, in: model)
            }
            .confirmationDialog(
                tr("从我的工具移除？"),
                isPresented: Binding(
                    get: { pendingRemoval != nil },
                    set: { if !$0 { pendingRemoval = nil } }
                ),
                presenting: pendingRemoval
            ) { tool in
                Button(String(format: tr("移除「%@」"), AppLanguage.localized(tool.name, languageRaw: languageRaw)), role: .destructive) {
                    model.remove(tool.id)
                    pendingRemoval = nil
                }
                Button(tr("取消"), role: .cancel) { pendingRemoval = nil }
            } message: { tool in
                Text(tr("只是从「我的工具」里拿掉，随时可以从工具中心再加回来。"))
            }
        }
    }

    private var grid: some View {
        ScrollView {
            // 编辑按钮放在内容区右上角（不是窗口工具栏）：离屏探针能渲染并点击它，工具栏渲染不到
            HStack {
                Text(String(format: tr("共 %d 个工具"), model.addedTools.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(isEditing ? tr("完成") : tr("编辑"), systemImage: isEditing ? "checkmark" : "pencil") {
                    withAnimation { isEditing.toggle() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(isEditing ? tr("退出编辑") : tr("编辑：删除、拖动排序"))
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 230), spacing: 16)],
                spacing: 16
            ) {
                ForEach(model.addedTools) { tool in
                    ToolCard(
                        tool: tool,
                        isEditing: isEditing,
                        power: model.powerBinding(for: tool.id),
                        onOpen: { openedTool = tool },
                        onRemove: { pendingRemoval = tool }
                    )
                    // 拖动排序只在编辑模式生效，平时拖卡片不会误动
                    .reorderable(id: tool.id, enabled: isEditing, preview: ToolIconBadge(icon: tool.icon))
                    .dropDestination(for: String.self) { dragged, _ in
                        guard isEditing, let id = dragged.first else { return false }
                        withAnimation { model.move(id, to: tool.id) }
                        return true
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "hammer")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text(tr("还没有添加工具"))
                .font(.title3.weight(.medium))
            Text(tr("去工具中心把喜欢的工具加进来吧"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button(AppLanguage.localized("去工具中心看看", languageRaw: languageRaw)) {
                model.selectedTab = .toolCenter
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 工具卡片
///
/// 右上角三态：编辑模式 → 删除按钮；工具有总开关 → 开关；否则什么都不放。
struct ToolCard: View {
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }
    let tool: ToolDefinition
    var isEditing = false
    /// nil = 这个工具没有总开关
    var power: Binding<Bool>?
    let onOpen: () -> Void
    let onRemove: () -> Void

    private var isOff: Bool { power.map { !$0.wrappedValue } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                ToolIconBadge(icon: tool.icon)
                Spacer()
                Color.clear.frame(width: 36, height: 22)
            }
            Text(AppLanguage.localized(tool.name, languageRaw: languageRaw))
                .font(.headline)
            Text(AppLanguage.localized(tool.summary, languageRaw: languageRaw))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: 28)
            HStack {
                if tool.implemented && isEditing {
                    Label(AppLanguage.localized("拖动排序", languageRaw: languageRaw), systemImage: "line.3.horizontal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if !tool.implemented {
                    ComingSoonBadge()
                }
                Spacer()
            }
            .frame(height: 16)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .overlay(alignment: .topTrailing) {
            Group {
                if isEditing {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .help(tr("从我的工具移除"))
                } else if let power {
                    Toggle("", isOn: power)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help(power.wrappedValue ? String(format: tr("关闭%@"), AppLanguage.localized(tool.name, languageRaw: languageRaw)) : String(format: tr("开启%@"), AppLanguage.localized(tool.name, languageRaw: languageRaw)))
                }
            }
            .padding(12)
        }
        // 总开关关掉时卡片变淡：一眼能看出这个工具是停着还是开着
        .opacity(isOff ? 0.55 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture {
            if !isEditing, tool.implemented { onOpen() }
        }
    }
}

/// 工具图标徽章
struct ToolIconBadge: View {
    let icon: String
    var size: CGFloat = 40

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(Color.accentColor.gradient)
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: icon)
                    .font(.system(size: size * 0.5, weight: .medium))
                    .foregroundStyle(.white)
            )
    }
}

/// "开发中"角标
struct ComingSoonBadge: View {
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue
    var body: some View {
        Text(AppLanguage.localized("开发中", languageRaw: languageRaw))
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
            .foregroundStyle(.orange)
    }
}

extension View {
    /// 只在需要时允许拖动（拖动载荷是工具 id）。
    /// 不用 `.draggable(_:isEnabled:)`——那个重载不存在，而且平时允许拖动能把工具 id 拖成一段文字。
    @ViewBuilder
    func reorderable(id: String, enabled: Bool, preview: some View) -> some View {
        if enabled {
            draggable(id) { preview }
        } else {
            self
        }
    }
}

#Preview("MyTools 空状态") {
    MyToolsView()
        .environment(AppModel())
}
