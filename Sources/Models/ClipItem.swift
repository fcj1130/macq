import Foundation

/// 剪贴板条目类型（对应历史窗口的类型 tab）
enum ClipKind: String, Codable, CaseIterable, Identifiable {
    case text
    case image
    case video
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "文本"
        case .image: "图片"
        case .video: "视频"
        case .file: "文件"
        }
    }

    var icon: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .video: "film"
        case .file: "doc"
        }
    }
}

/// 一条剪贴板历史
struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var kind: ClipKind
    /// 最近一次复制/复用的时间（复用会刷新，列表按它倒序）
    var usedAt: Date
    /// 内容大小（字节）。文件类型是被引用文件的大小，不计入占用上限。
    var size: Int
    /// 文本字符数，其它类型为 0
    var characters: Int
    /// 列表主行展示
    var preview: String
    /// 搜索用文本（截断，见 ClipboardStore.searchTextLimit）
    var searchText: String
    /// 落盘载荷文件名；文件引用类为 nil
    var payload: String?
    /// 被引用文件路径（文件/视频文件类）
    var paths: [String]
    /// 写回剪贴板用的类型标识（文件引用类为 nil）
    var pasteboardType: String?
    /// 去重指纹
    var fingerprint: String

    /// 落盘格式的显式字段名（不用编译器推断，改名即破坏兼容）
    enum CodingKeys: String, CodingKey {
        case id, kind, usedAt, size, characters, preview, searchText, payload, paths, pasteboardType, fingerprint
    }
}

// 放在扩展里是为了保留成员逐一构造器（monitor 里大量在用）
extension ClipItem {
    /// 载荷落盘完成后补上这两项。落盘在后台线程，回主线程前先做成不可变副本（并发闭包不能捕获 var）
    func updating(payload: String, fingerprint: String) -> ClipItem {
        var copy = self
        copy.payload = payload
        copy.fingerprint = fingerprint
        return copy
    }

    /// 容错解码：缺字段就用默认值。
    /// 这样以后给 ClipItem 加字段（旧 index.json 里没有）不会让整份索引解码失败、历史被清空。
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try c.decodeIfPresent(ClipKind.self, forKey: .kind) ?? .text
        usedAt = try c.decodeIfPresent(Date.self, forKey: .usedAt) ?? Date()
        size = try c.decodeIfPresent(Int.self, forKey: .size) ?? 0
        characters = try c.decodeIfPresent(Int.self, forKey: .characters) ?? 0
        preview = try c.decodeIfPresent(String.self, forKey: .preview) ?? ""
        searchText = try c.decodeIfPresent(String.self, forKey: .searchText) ?? preview
        payload = try c.decodeIfPresent(String.self, forKey: .payload)
        paths = try c.decodeIfPresent([String].self, forKey: .paths) ?? []
        pasteboardType = try c.decodeIfPresent(String.self, forKey: .pasteboardType)
        // 指纹缺失（未来版本新增该字段时）视作不可去重，给一个唯一值
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? UUID().uuidString
    }
}
