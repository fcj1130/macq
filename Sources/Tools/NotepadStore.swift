import Foundation
import Observation

/// 记事本的一条记录：一行文本 + 更新时间。
struct NotepadNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updatedAt = Date()
    /// 软删除时间：非 nil 表示已软删除（列表加删除线）。可选类型，旧数据没这个键也能解码
    var deletedAt: Date?
    /// 提醒时间（可空）
    var remindAt: Date?
    /// 已处理时间：提醒处理掉之后不再出便签、闹钟图标消失
    var handledAt: Date?

    /// 有待处理提醒（设了时间、还没处理、没被软删除）
    var hasPendingReminder: Bool {
        remindAt != nil && handledAt == nil && deletedAt == nil
    }

    /// 到点了还没处理
    var isOverdue: Bool {
        guard let remindAt, hasPendingReminder else { return false }
        return remindAt <= Date()
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// 记事本存储：整体以 JSON 存在开发者工具箱命名空间里（单键，随改随写）。
///
/// ponytail: UserDefaults 一个键装全部记录，几千条文本量级够用；
/// 真到几十 MB 再换文件/SQLite。
@MainActor
@Observable
final class NotepadStore {
    /// 手动排序（拖拽）后的顺序，新记录插到最前
    private(set) var notes: [NotepadNote] = []
    /// 到点未处理的记录 id（便签与红色闹钟都看它；定时刷新，跨过提醒时间也能自己亮起来）
    private(set) var dueIDs: Set<UUID> = []

    /// 每次落盘后回调（便签窗口靠它即时增删）
    @ObservationIgnored var onChange: (() -> Void)?

    private let settings: ToolSettings
    private var timer: Timer?

    init(settings: ToolSettings) {
        self.settings = settings
        if let data = settings.data("notes"),
           let decoded = try? JSONDecoder().decode([NotepadNote].self, from: data) {
            notes = decoded
        }
        refreshDue()
        // shortcut: 固定 15 秒轮询，最多晚 15 秒提醒；要秒级准确再换成按最近提醒时间排单次 timer
        // （一次性 timer 跨休眠不一定准时，轮询更稳）
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDue() }
        }
        RunLoop.main.add(t, forMode: .common)   // 面板拖动 / 菜单跟踪时也要走
        timer = t
    }

    @discardableResult
    func add(_ text: String, remindAt: Date? = nil) -> UUID {
        let note = NotepadNote(text: text, remindAt: remindAt)
        notes.insert(note, at: 0)
        save()
        return note.id
    }

    /// 改内容 / 提醒时间并刷新更新时间。提醒时间变了就重置已处理状态（重新提醒）
    func update(_ id: UUID, text: String, remindAt: Date?) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var note = notes[index]
        let remindChanged = note.remindAt != remindAt
        guard note.text != text || remindChanged else { return }
        note.text = text
        note.remindAt = remindAt
        if remindChanged { note.handledAt = nil }
        note.updatedAt = Date()
        notes[index] = note
        save()
    }

    /// 标记已处理：便签收起、闹钟图标消失，记录本身保留
    func markHandled(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].handledAt == nil else { return }
        notes[index].handledAt = Date()
        save()
    }

    /// permanently = true 真删；否则软删除（只打标记，保留在列表里）
    func remove(_ id: UUID, permanently: Bool) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        if permanently {
            notes.remove(at: index)
        } else {
            notes[index].deletedAt = Date()
        }
        save()
    }

    /// 拖拽排序：把 id 移到 target 的位置（按当前真实顺序移动，搜索过滤下也正确）
    func move(_ id: UUID, to target: UUID) {
        guard id != target,
              let from = notes.firstIndex(where: { $0.id == id }),
              let to = notes.firstIndex(where: { $0.id == target }) else { return }
        let note = notes.remove(at: from)
        notes.insert(note, at: to)
        save()
    }

    /// 搜索过滤（大小写不敏感，包含即命中）
    func filtered(_ query: String) -> [NotepadNote] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }
        return notes.filter { $0.text.localizedCaseInsensitiveContains(trimmed) }
    }

    /// 到点未处理（按提醒时间早的在前）
    var dueNotes: [NotepadNote] {
        notes.filter { dueIDs.contains($0.id) }.sorted { ($0.remindAt ?? .distantPast) < ($1.remindAt ?? .distantPast) }
    }

    /// 按当前时间重算到点集合（定时器调；探针也直接调，不必等定时器）
    func refreshDue() {
        let fresh = Set(notes.filter(\.isOverdue).map(\.id))
        guard fresh != dueIDs else { return }
        dueIDs = fresh
        onChange?()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(notes) {
            settings.set(data, "notes")
        }
        refreshDue()
        onChange?()   // 内容改了便签也要跟着刷新
    }
}
