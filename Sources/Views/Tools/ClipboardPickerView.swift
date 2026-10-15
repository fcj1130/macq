import AppKit
import AppKit
import QuickLookThumbnailing
import SwiftUI

/// 剪贴板历史窗口内容：搜索 + 类型 tab + 分页列表，点击条目即复用
struct ClipboardPickerView: View {
    let tool: MagicClipboard
    @Bindable var state: PickerState
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }

    @State private var confirmingClear = false
    @FocusState private var searchFocused: Bool

    /// initialQuery 只为探针准备（离屏渲染时无法往搜索框打字）
    init(tool: MagicClipboard, state: PickerState, initialQuery: String = "") {
        self.tool = tool
        self.state = state
        state.query = initialQuery
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            tabs
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 320)
        .clearHistoryConfirmation(isPresented: $confirmingClear, count: tool.store.items.count) { tool.clear() }
    }

    // MARK: - 顶部

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(tr("搜索剪贴板历史"), text: $state.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !state.query.isEmpty {
                Button {
                    state.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var tabs: some View {
        Picker(tr("类型"), selection: $state.kind) {
            Text(String(format: tr("全部 %d"), tool.store.items.count)).tag(ClipKind?.none)
            ForEach(ClipKind.allCases) { kind in
                Text("\(tr(kind.title)) \(tool.store.count(kind: kind))").tag(ClipKind?.some(kind))
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    // MARK: - 列表

    private var visibleItems: [ClipItem] {
        tool.store.query(kind: state.kind, text: state.query, limit: state.limit)
    }

    private var list: some View {
        let items = visibleItems
        return Group {
            if items.isEmpty {
                ContentUnavailableView(
                    state.query.isEmpty ? tr("还没有历史") : tr("没有匹配的记录"),
                    systemImage: state.query.isEmpty ? "clipboard" : "magnifyingglass",
                    description: Text(state.query.isEmpty ? tr("复制点什么试试") : tr("换个关键字试试"))
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(items) { item in
                                ClipRow(item: item, tool: tool, isSelected: item.id == items[safe: state.selected]?.id)
                                    .id(item.id)
                                    .onAppear {
                                        // 滚到底自动加载下一页
                                        if item.id == items.last?.id { state.limit += 200 }
                                    }
                                Divider().padding(.leading, 60)
                            }
                        }
                    }
                    // 选中项始终留在可视区（方向键切到列表外时要跟着滚）
                    .onChange(of: state.selected) { _, new in
                        guard let item = items[safe: new] else { return }
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(item.id, anchor: nil) }
                    }
                    // 每次唤起：滚动回顶部（选中项已被窗口重置为第一条）
                    .onChange(of: state.presentation) { _, _ in
                        searchFocused = false
                        if let first = items.first { proxy.scrollTo(first.id, anchor: .top) }
                    }
                }
                .onChange(of: state.kind) { _, _ in state.selected = 0; state.limit = 200 }
                .onChange(of: state.query) { _, _ in state.selected = 0; state.limit = 200 }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 底部

    private var footer: some View {
        let items = visibleItems
        return HStack(spacing: 10) {
            Text(String(format: tr("%d 条 · 占用 %@"), tool.store.items.count, Self.size(tool.store.storedBytes)))
            // 一整页都被填满就说明大概率还有更多，滚到底会自动加载下一页
            if items.count >= state.limit {
                Text(String(format: tr("· 已显示 %d 条"), items.count))
            }
            Spacer()
            Text(tr("↑↓ 选择 · ⏎ 粘贴 · esc 关闭"))
            Button(tr("清空历史")) { confirmingClear = true }
                .disabled(tool.store.items.isEmpty)
            Button(tr("关闭")) { tool.hidePicker() }
                .keyboardShortcut(.cancelAction)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// 单条历史
private struct ClipRow: View {
    let item: ClipItem
    let tool: MagicClipboard
    let isSelected: Bool

    @State private var hovering = false
    @State private var thumbnail: NSImage?

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    /// 一分钟内「刚刚」（避免「0 秒前」这种噪音）；一小时内相对时间；更早显示具体日期时间
    private static func age(_ date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return AppLanguage.localized("刚刚") }
        if seconds < 3600 { return relative.localizedString(for: date, relativeTo: Date()) }
        return absolute.string(from: date)
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.28) }
        return hovering ? Color.accentColor.opacity(0.13) : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: item.kind.icon).foregroundStyle(.secondary)
                }
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.isEmpty ? AppLanguage.localized(item.kind.title) : item.preview)
                    .lineLimit(2)
                    .font(.system(size: 13))
                HStack(spacing: 8) {
                    Text(AppLanguage.localized(item.kind.title))
                    Text(Self.age(item.usedAt))
                    Text(ClipboardPickerView.size(item.size))
                    if item.characters > 0 { Text(String(format: AppLanguage.localized("%d 字"), item.characters)) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(background)
        .onTapGesture { tool.reuse(item) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button(AppLanguage.localized("复用")) { tool.reuse(item) }
            Button(AppLanguage.localized("删除"), role: .destructive) { tool.delete(item) }
        }
        .task(id: item.id) {
            thumbnail = await ThumbnailLoader.shared.image(for: item, store: tool.store)
        }
    }
}

/// 缩略图（图片/视频/文件走 QuickLook，带内存缓存）
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()

    private let cache = NSCache<NSString, NSImage>()

    func image(for item: ClipItem, store: ClipboardStore) async -> NSImage? {
        guard item.kind != .text else { return nil }
        let key = item.id.uuidString as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let url = sourceURL(for: item, store: store) else { return nil }
        guard let image = await thumbnail(of: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private func sourceURL(for item: ClipItem, store: ClipboardStore) -> URL? {
        if let url = store.payloadURL(item) { return url }
        if let path = item.paths.first { return URL(fileURLWithPath: path) }
        return nil
    }

    private func thumbnail(of url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 64, height: 64),
            scale: 2,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return representation.nsImage
        }
        // 兜底：系统文件图标
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
