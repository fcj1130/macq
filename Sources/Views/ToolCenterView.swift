import SwiftUI

/// 工具中心：全量工具列表，可添加到我的工具
struct ToolCenterView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    var body: some View {
        List {
            ForEach(ToolDefinition.catalogByAvailability.filter(\.implemented)) { tool in
                ToolRow(tool: tool, isAdded: model.isAdded(tool.id)) {
                    model.add(tool.id)
                }
                .padding(.vertical, 4)
            }
        }
        .listStyle(.inset)
        .navigationTitle(AppLanguage.localized("工具中心", languageRaw: languageRaw))
    }
}

private struct ToolRow: View {
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue
    let tool: ToolDefinition
    let isAdded: Bool
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ToolIconBadge(icon: tool.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLanguage.localized(tool.name, languageRaw: languageRaw))
                    .font(.headline)
                Text(AppLanguage.localized(tool.summary, languageRaw: languageRaw))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if !tool.implemented {
                ComingSoonBadge()
            }
            if isAdded {
                Label(AppLanguage.localized("已添加", languageRaw: languageRaw), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button(AppLanguage.localized("添加", languageRaw: languageRaw), action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview("ToolCenter") {
    ToolCenterView()
        .environment(AppModel())
}
