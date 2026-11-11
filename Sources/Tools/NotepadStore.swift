import Foundation
import Observation

/// 记事本的一条记录：一行文本 + 更新时间。
struct NotepadNote: Codable, Identifiable, Equatable {
    var id = UUID()
    var text: String
    var updatedAt = Date()
    /// 软删除时间：非 nil 表示已软删除（列表加删除线）。可选类型，旧数据没这个键也能解码
    var deletedAt: Date?
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

    private let settings: ToolSettings

    init(settings: ToolSettings) {
        self.settings = settings
        if let data = settings.data("notes"),
           let decoded = try? JSONDecoder().decode([NotepadNote].self, from: data) {
            notes = decoded
        }
    }

    /// 新增并返回 id（调用方要立刻聚焦这一行）
    @discardableResult
    func add(_ text: String) -> UUID {
        let note = NotepadNote(text: text)
        notes.insert(note, at: 0)
        save()
        return note.id
    }

    /// 改内容并刷新更新时间
    func update(_ id: UUID, text: String) {
        guard let index = notes.firstIndex(where: { $0.id == id }), notes[index].text != text else { return }
        notes[index].text = text
        notes[index].updatedAt = Date()
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

    private func save() {
        guard let data = try? JSONEncoder().encode(notes) else { return }
        settings.set(data, "notes")
    }
}
