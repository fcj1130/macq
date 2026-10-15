import Foundation
import Observation
import OSLog

/// 历史保留期
enum ClipRetention: String, Codable, CaseIterable, Identifiable {
    case week
    case month
    case quarter
    case halfYear
    case year
    case forever

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: "1 周"
        case .month: "1 个月"
        case .quarter: "1 季度"
        case .halfYear: "半年"
        case .year: "1 年"
        case .forever: "无限制"
        }
    }

    /// 保留时长；无限制为 nil。按 30 天/月、365 天/年估算。
    var interval: TimeInterval? {
        switch self {
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        case .quarter: 90 * 86_400
        case .halfYear: 182 * 86_400
        case .year: 365 * 86_400
        case .forever: nil
        }
    }

    func cutoff(now: Date = Date()) -> Date? {
        interval.map { now.addingTimeInterval(-$0) }
    }
}

/// 索引文件的外层结构：带版本号，结构真要改时才有地方做迁移。
private struct IndexFile: Codable {
    var version: Int
    var items: [ClipItem]
}

/// 剪贴板历史存储：`<root>/index.json` + `<root>/<uuid>.<ext>` 载荷文件。
///
/// ponytail: 索引是整体重写（0.5s 防抖），单条元数据很小，几千条量级完全够用；
/// 真到几万条再换 SQLite。
@MainActor
@Observable
final class ClipboardStore {
    /// 正文只索引前 N 个字符，避免索引膨胀（搜索命中范围也就是这个上限）
    static let searchTextLimit = 500
    static let previewLimit = 120
    /// index.json 的结构版本（写盘用；读盘兼容旧版，见 load()）
    static let indexVersion = 1

    private(set) var items: [ClipItem] = []

    let root: URL
    private let indexURL: URL
    private let logger = Logger(subsystem: "com.mymy.macq", category: "clipboard")
    private var saveTask: Task<Void, Never>?

    init(root: URL = ClipboardStore.defaultRoot()) {
        self.root = root
        indexURL = root.appendingPathComponent("index.json")
        load()
    }

    nonisolated static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("macq/Clipboard", isDirectory: true)
    }

    /// 真正占用磁盘的字节数（文件引用不计入）
    var storedBytes: Int {
        items.reduce(0) { $0 + ($1.payload == nil ? 0 : $1.size) }
    }

    func payloadURL(_ item: ClipItem) -> URL? {
        item.payload.map { root.appendingPathComponent($0) }
    }

    func count(kind: ClipKind) -> Int {
        items.count { $0.kind == kind }
    }

    // MARK: - 读写

    /// 记录一条内容，重复内容只刷新时间；随后按上限/保留期清理。
    func insert(_ item: ClipItem, maxBytes: Int, retention: ClipRetention) {
        if let index = items.firstIndex(where: { $0.fingerprint == item.fingerprint }) {
            let existing = items[index]
            // 内容相同：保留已有载荷，丢掉刚写的那份
            if let payload = item.payload, payload != existing.payload {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(payload))
            }
            items[index].usedAt = item.usedAt
        } else {
            items.append(item)
        }
        sortAndSave()
        enforce(maxBytes: maxBytes, retention: retention)
    }

    /// 复用：刷新时间为最新
    func touch(_ item: ClipItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].usedAt = Date()
        sortAndSave()
    }

    func delete(_ ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        items.removeAll { ids.contains($0.id) }
        removePayloads(removed)
        save()
    }

    func clear() {
        let removed = items
        items = []
        removePayloads(removed)
        save()
    }

    /// 按类型 + 关键字过滤；limit 用于分页加载。
    func query(kind: ClipKind? = nil, text: String = "", limit: Int = .max) -> [ClipItem] {
        let keyword = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var result: [ClipItem] = []
        for item in items {
            if let kind, item.kind != kind { continue }
            if !keyword.isEmpty {
                let haystack = item.searchText.isEmpty ? item.preview : item.searchText
                if haystack.range(of: keyword, options: [.caseInsensitive, .diacriticInsensitive]) == nil { continue }
            }
            result.append(item)
            if result.count >= limit { break }
        }
        return result
    }

    // MARK: - 清理

    /// 淘汰超期与超量的条目（从最旧开始）
    func enforce(maxBytes: Int, retention: ClipRetention, now: Date = Date()) {
        var kept: [ClipItem] = []
        var removed: [ClipItem] = []

        for item in items {
            if let cutoff = retention.cutoff(now: now), item.usedAt < cutoff {
                removed.append(item)
            } else {
                kept.append(item)
            }
        }

        // 只有真正落盘的条目参与占用淘汰（文件引用不占空间，不该因为它被删）
        var bytes = kept.reduce(0) { $0 + ($1.payload == nil ? 0 : $1.size) }
        while bytes > maxBytes {
            guard let index = kept.lastIndex(where: { $0.payload != nil }) else { break }
            bytes -= kept[index].size
            removed.append(kept.remove(at: index))
        }

        guard !removed.isEmpty else { return }
        items = kept
        removePayloads(removed)
        save()
        logger.info("清理剪贴板历史 \(removed.count) 条，剩余 \(kept.count) 条")
    }

    private func removePayloads(_ items: [ClipItem]) {
        for item in items {
            guard let payload = item.payload else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(payload))
        }
    }

    // MARK: - 落盘

    private func sortAndSave() {
        items.sort { $0.usedAt > $1.usedAt }
        save()
    }

    /// 防抖写入；退出前用 flush() 落盘
    private func save() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.write()
        }
    }

    func flush() {
        saveTask?.cancel()
        saveTask = nil
        write()
    }

    private func write() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let data = try encoder.encode(IndexFile(version: Self.indexVersion, items: items))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            logger.error("写入剪贴板索引失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        let manager = FileManager.default
        try? manager.createDirectory(at: root, withIntermediateDirectories: true)

        guard let data = try? Data(contentsOf: indexURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // 先按带版本的新格式读；失败则兼容旧版裸数组（ClipItem 本身容错，缺字段不致命）
        let file = try? decoder.decode(IndexFile.self, from: data)
        let decoded = file?.items ?? (try? decoder.decode([ClipItem].self, from: data))
        guard let decoded else {
            logger.error("剪贴板索引损坏，从空历史开始（载荷文件保留）")
            return
        }
        if let version = file?.version, version > Self.indexVersion {
            logger.error("索引版本 \(version) 高于当前支持的 \(Self.indexVersion)，可能有字段读不出来")
        }
        // 丢掉载荷已丢失的条目
        items = decoded.filter { item in
            guard let payload = item.payload else { return true }
            return manager.fileExists(atPath: root.appendingPathComponent(payload).path)
        }
        items.sort { $0.usedAt > $1.usedAt }
        cleanOrphans()
    }

    /// 删掉索引里已经没有的载荷文件
    private func cleanOrphans() {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        let referenced = Set(items.compactMap(\.payload))
        for file in files where file != indexURL.lastPathComponent && !referenced.contains(file) {
            try? manager.removeItem(at: root.appendingPathComponent(file))
        }
    }
}
